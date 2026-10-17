-- =====================================================================
-- V3 : potentiel constructible théorique (gisement foncier)
-- Règles extraites du règlement écrit du PLUi Grand-Orly Seine Bièvre (16/12/2025)
--   §3.1.5 Emprise au sol · §3.1.7 Hauteur. Le code de zone porte 6 indices
--   (alignement, limites séparatives, même unité foncière, EMPRISE, pleine terre, HAUTEUR) ;
--   la lettre H est celle de Gentilly. Ex. « UCHH1H1HHH1 » = UC, emprise H, hauteur H1.
-- Hauteurs converties en niveaux à raison de 3 m par niveau (égout du toit quand il est précisé).
-- =====================================================================
DROP TABLE IF EXISTS gentilly.regles_plu;
CREATE TABLE gentilly.regles_plu (
  libelle_gpu text PRIMARY KEY, zone text, indice_emprise text, emprise_max_pct numeric,
  indice_hauteur text, hauteur_max_m numeric, niveaux_max int, regle_emprise text, regle_hauteur text);
INSERT INTO gentilly.regles_plu VALUES
 ('UCHHHHHH',     'UC','H', 60,'H', 18,  6,'60 % (70 % en cas d''amélioration du bâti existant)','18 m au point le plus haut (19,50 m avec RDC actif)'),
 ('UCH1H1H1HHH',  'UC','H', 60,'H', 18,  6,'60 % (70 % en cas d''amélioration du bâti existant)','18 m au point le plus haut (19,50 m avec RDC actif)'),
 ('UCHH1H1HHH1',  'UC','H', 60,'H1',21,  7,'60 % (70 % en cas d''amélioration du bâti existant)','21 m au point le plus haut (22,50 m avec RDC actif)'),
 ('UCHHHHHH1',    'UC','H', 60,'H1',21,  7,'60 % (70 % en cas d''amélioration du bâti existant)','21 m au point le plus haut (22,50 m avec RDC actif)'),
 ('UAHHHHHH',     'UA','H', 60,'H', 21,  7,'60 %','21 m au point le plus haut (22,50 m avec RDC actif)'),
 ('UMHHHHHH',     'UM','H', 55,'H', 12,  3,'55 % (65 % en cas d''amélioration du bâti existant)','9,50 m à l''égout, 12 m au faîtage'),
 ('URHHHHHH',     'UR','H', 60,'H', 21,  7,'60 % (70 % en cas d''amélioration du bâti existant)','21 m au point le plus haut'),
 ('UHmHHHHHH',    'UHm','H',50,'H', 9.5, 2,'50 % (80 % si unité foncière < 150 m²)','7,5 m à l''égout, 9,5 m au faîtage'),
 ('UIHHHHHH',     'UI','H', 60,'H', 21,  7,'60 %','21 m au point le plus haut'),
 ('UEHHHHHH',     'UE','H', NULL,'H',21, 7,'Non réglementée','21 m au faîtage'),
 ('UEsHHHHHH',    'UEs','H',NULL,'H',21, 7,'Non réglementée','21 m au faîtage'),
 ('UEHH1HH1H1H',  'UE','H1',60,'H', 21,  7,'60 %','21 m au faîtage'),
 ('UEhHH1HH1H1H', 'UEh','H1',60,'H',21,  7,'60 %','21 m au faîtage'),
 ('NHHHHH1H',     'N','H',  NULL,'H',3,  1,'Non réglementée','3 m au faîtage'),
 ('NpH1H1H1H1HH', 'Np','H1',30,'H', 3,   1,'30 %','3 m au faîtage'),
 ('NpH1H1H1H2HH', 'Np','H2',10,'H', 3,   1,'10 %','3 m au faîtage');

-- Bâti existant (BD TOPO) : niveaux = max(nombre d'étages, hauteur / 3 m), au moins 1
DROP TABLE IF EXISTS gentilly.potentiel;
CREATE TABLE gentilly.potentiel AS
WITH zone_p AS (   -- zone majoritaire de chaque parcelle
  SELECT DISTINCT ON (p.id) p.id, z.libelle_gpu
  FROM gentilly.parcelles p JOIN gentilly.plu_zones z ON ST_Intersects(z.geom, p.geom)
  ORDER BY p.id, ST_Area(ST_Intersection(z.geom, p.geom)) DESC
),
bati AS (
  SELECT p.id,
         coalesce(ST_Area(ST_Union(ST_Intersection(b.geom, p.geom))), 0) AS emprise,
         coalesce(sum(ST_Area(ST_Intersection(b.geom, p.geom))
                  * greatest(1, coalesce(b.nombre_d_etages, 0), coalesce(floor(b.hauteur / 3.0), 0))), 0) AS sdp,  -- prudence : le plus grand des deux
         max(b.hauteur) AS h_max
  FROM gentilly.parcelles p
  LEFT JOIN gentilly.bdtopo_batiments b ON ST_Intersects(b.geom, p.geom) AND coalesce(b.construction_legere, false) = false
  GROUP BY p.id
)
SELECT p.id AS id_parcelle, r.zone, r.libelle_gpu, ST_Area(p.geom) AS surface,
       r.emprise_max_pct, r.hauteur_max_m, r.niveaux_max, r.regle_emprise, r.regle_hauteur,
       bati.emprise AS emprise_existante, bati.sdp AS sdp_existante, bati.h_max AS hauteur_existante_max,
       ST_Area(p.geom) * r.emprise_max_pct / 100.0                AS emprise_autorisee,
       ST_Area(p.geom) * r.emprise_max_pct / 100.0 * r.niveaux_max AS sdp_theorique
FROM gentilly.parcelles p
JOIN zone_p ON zone_p.id = p.id
JOIN gentilly.regles_plu r ON r.libelle_gpu = zone_p.libelle_gpu
JOIN bati ON bati.id = p.id;

ALTER TABLE gentilly.potentiel ADD PRIMARY KEY (id_parcelle);
ALTER TABLE gentilly.potentiel
  ADD COLUMN emprise_restante numeric, ADD COLUMN gisement_sdp numeric, ADD COLUMN taux_utilisation numeric, ADD COLUMN classe_gisement text;
UPDATE gentilly.potentiel SET
  emprise_restante = greatest(0, emprise_autorisee - emprise_existante),
  gisement_sdp     = greatest(0, sdp_theorique - sdp_existante),
  taux_utilisation = sdp_existante / NULLIF(sdp_theorique, 0);
-- Classement : uniquement zones urbaines constructibles, parcelles >= 150 m²
UPDATE gentilly.potentiel SET classe_gisement = CASE
    WHEN zone NOT IN ('UC','UA','UM','UR','UHm','UI') OR emprise_max_pct IS NULL THEN 'Non concerné'
    WHEN surface < 150                                                    THEN 'Trop petite'
    WHEN surface > 5000                                                   THEN 'Grande emprise'   -- étude au cas par cas
    WHEN taux_utilisation < 0.25 AND gisement_sdp >= 300                  THEN 'Très élevé'
    WHEN taux_utilisation < 0.50 AND gisement_sdp >= 150                  THEN 'Élevé'
    WHEN taux_utilisation < 0.90                                          THEN 'Modéré'
    ELSE 'Saturé' END;
ANALYZE gentilly.potentiel;
