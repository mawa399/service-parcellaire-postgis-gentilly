-- =====================================================================
-- V3 : temps de marche réels jusqu'aux gares (pgRouting)
-- Prérequis : gentilly.reseau_pieton (tronçons OSM avec source, target, geom), chargé par
-- scripts/importer_donnees_qgis.py, et gentilly.gares (05_v2_donnees.sql).
-- Vitesse de marche : 4,5 km/h = 75 m/min. Escaliers : coût majoré de 50 %.
-- =====================================================================
CREATE EXTENSION IF NOT EXISTS pgrouting SCHEMA public;

UPDATE gentilly.reseau_pieton
   SET cost = ST_Length(geom) * CASE WHEN highway = 'steps' THEN 1.5 ELSE 1 END,
       reverse_cost = ST_Length(geom) * CASE WHEN highway = 'steps' THEN 1.5 ELSE 1 END;
CREATE INDEX IF NOT EXISTS idx_reseau_geom ON gentilly.reseau_pieton USING gist (geom);
CREATE INDEX IF NOT EXISTS idx_reseau_src ON gentilly.reseau_pieton (source);
CREATE INDEX IF NOT EXISTS idx_reseau_tgt ON gentilly.reseau_pieton (target);
ANALYZE gentilly.reseau_pieton;

-- Nœuds du réseau et composante principale
DROP TABLE IF EXISTS gentilly.reseau_noeuds;
CREATE TABLE gentilly.reseau_noeuds AS
SELECT id, (array_agg(geom))[1]::geometry(Point,2154) AS geom FROM (
  SELECT source AS id, ST_StartPoint(geom) geom FROM gentilly.reseau_pieton
  UNION ALL SELECT target, ST_EndPoint(geom) FROM gentilly.reseau_pieton) x GROUP BY id;
ALTER TABLE gentilly.reseau_noeuds ADD PRIMARY KEY (id);
ALTER TABLE gentilly.reseau_noeuds ADD COLUMN composante bigint;
UPDATE gentilly.reseau_noeuds n SET composante = c.component
FROM pgr_connectedComponents('SELECT id, source, target, cost, reverse_cost FROM gentilly.reseau_pieton') c
WHERE c.node = n.id;

DROP TABLE IF EXISTS gentilly.noeuds_principaux;
CREATE TABLE gentilly.noeuds_principaux AS
SELECT n.* FROM gentilly.reseau_noeuds n
WHERE composante = (SELECT composante FROM gentilly.reseau_noeuds GROUP BY 1 ORDER BY count(*) DESC LIMIT 1);
ALTER TABLE gentilly.noeuds_principaux ADD PRIMARY KEY (id);
CREATE INDEX ON gentilly.noeuds_principaux USING gist (geom);

-- Accroche des gares au réseau ; arrêts hors emprise (> 150 m d'un nœud) écartés
ALTER TABLE gentilly.gares ADD COLUMN IF NOT EXISTS noeud bigint;
UPDATE gentilly.gares g SET noeud = (SELECT n.id FROM gentilly.noeuds_principaux n ORDER BY n.geom <-> g.geom LIMIT 1);
UPDATE gentilly.gares g SET noeud = NULL
 WHERE ST_Distance(g.geom, (SELECT n.geom FROM gentilly.noeuds_principaux n WHERE n.id = g.noeud)) > 150;

-- Distance de chaque nœud à la gare la plus proche, par mode
-- pgr_drivingDistance multi-sources, equicost = true : la gare la plus proche « gagne » le nœud
DROP TABLE IF EXISTS gentilly.acces_noeuds;
CREATE TABLE gentilly.acces_noeuds (noeud bigint, mode text, gare_gid int, dist_m double precision);

INSERT INTO gentilly.acces_noeuds
SELECT d.node, m.mode,
       (SELECT g.gid FROM gentilly.gares g WHERE g.noeud = d.start_vid AND (m.mode = 'TOUS' OR g.mode = m.mode) ORDER BY g.gid LIMIT 1),
       d.agg_cost
FROM (VALUES ('RER'), ('METRO'), ('TRAMWAY'), ('TOUS')) m(mode)
CROSS JOIN LATERAL pgr_drivingDistance(
  'SELECT id, source, target, cost, reverse_cost FROM gentilly.reseau_pieton',
  (SELECT array_agg(DISTINCT noeud) FROM gentilly.gares WHERE noeud IS NOT NULL AND (m.mode = 'TOUS' OR mode = m.mode)),
  3000, false, true) d;
CREATE INDEX ON gentilly.acces_noeuds (noeud, mode);
ANALYZE gentilly.acces_noeuds;

-- Temps de marche par parcelle : point d'accès = adresse BAN, sinon un point dans la parcelle
DROP TABLE IF EXISTS gentilly.acces_parcelles;
CREATE TABLE gentilly.acces_parcelles AS
WITH pt AS (
  SELECT p.id, coalesce((SELECT a.geom FROM gentilly.adresses a WHERE a.id_parcelle = p.id ORDER BY a.numero LIMIT 1),
                        ST_PointOnSurface(p.geom)) AS g
  FROM gentilly.parcelles p
), snap AS (
  SELECT pt.id, n.id AS noeud, ST_Distance(n.geom, pt.g) AS accroche
  FROM pt CROSS JOIN LATERAL (SELECT id, geom FROM gentilly.noeuds_principaux ORDER BY geom <-> pt.g LIMIT 1) n
)
SELECT s.id AS id_parcelle, a.mode, g.nom AS gare, g.ligne,
       round(s.accroche + a.dist_m)::int AS dist_marche_m,
       ceil((s.accroche + a.dist_m) / 75.0)::int AS minutes
FROM snap s JOIN gentilly.acces_noeuds a ON a.noeud = s.noeud
LEFT JOIN gentilly.gares g ON g.gid = a.gare_gid;
CREATE INDEX ON gentilly.acces_parcelles (id_parcelle, mode);
ANALYZE gentilly.acces_parcelles;

-- Isochrones 5, 10, 15 min autour des gares (anneaux)
DROP TABLE IF EXISTS gentilly.isochrones;
CREATE TABLE gentilly.isochrones AS
WITH c AS (SELECT noeud, dist_m FROM gentilly.acces_noeuds WHERE mode = 'TOUS'),
e AS (SELECT r.geom, greatest(cs.dist_m, ct.dist_m) AS d
      FROM gentilly.reseau_pieton r JOIN c cs ON cs.noeud = r.source JOIN c ct ON ct.noeud = r.target),
lv AS (SELECT m, ST_Buffer(ST_Union(ST_Buffer(geom, 35, 'quad_segs=2')), 0) AS g
       FROM e, (VALUES (5),(10),(15)) v(m) WHERE d <= m * 75 GROUP BY m)
SELECT m AS minutes,
       ST_Multi(ST_CollectionExtract(ST_MakeValid(CASE m WHEN 5 THEN g
            ELSE ST_Difference(g, (SELECT g FROM lv l2 WHERE l2.m = lv.m - 5)) END), 3))::geometry(MultiPolygon,2154) AS geom
FROM lv;
