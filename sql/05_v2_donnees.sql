-- =====================================================================
-- V2 : urbanisme, servitudes, risques, transports
-- Tables *_brut importées depuis data/plu, data/risques, data/transports
-- =====================================================================

-- PLUi Grand-Orly Seine Bièvre (partition GPU DU_200058014, règlement du 16/12/2025)
DROP TABLE IF EXISTS gentilly.plu_zones;
CREATE TABLE gentilly.plu_zones AS
SELECT row_number() OVER ()::int AS gid,
       regexp_replace(libelle, '([HBK][0-9]*)+$', '') AS code,      -- « UCHH1H1HHH1 » -> « UC », « UHmBBBBBB » -> « UHm »
       coalesce(NULLIF(split_part(libelong, ' : ', 2), ''), libelong) AS nom,
       libelle AS libelle_gpu, typezone, NULLIF(destdomi,'') AS destdomi,
       nomfic AS reglement, gpu_doc_id,
       'https://www.geoportail-urbanisme.gouv.fr/document/by-id/' || gpu_doc_id AS url_document,
       ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3))::geometry(MultiPolygon, 2154) AS geom
FROM gentilly.plu_zones_brut z
WHERE partition = 'DU_200058014'
  AND EXISTS (SELECT 1 FROM gentilly.parcelles p WHERE ST_Intersects(p.geom, z.geom)
              AND ST_Area(ST_Intersection(p.geom, z.geom)) > 1);   -- zones touchant Gentilly
ALTER TABLE gentilly.plu_zones ADD PRIMARY KEY (gid);
CREATE INDEX idx_plu_zones_geom ON gentilly.plu_zones USING gist (geom);

-- Servitudes d'utilité publique : PM1 (plans de prévention des risques) et AC1 (monuments historiques)
DROP TABLE IF EXISTS gentilly.servitudes;
CREATE TABLE gentilly.servitudes AS
SELECT row_number() OVER ()::int AS gid, suptype,
       CASE
         WHEN nomass ILIKE '%argiles%'      THEN 'PPR retrait-gonflement des argiles'
         WHEN nomass ILIKE '%aet%' OR nomass ILIKE '%carrieres%' OR nomass ILIKE '%Montrouge%'
                                            THEN 'PPR mouvements de terrain (anciennes carrières)'
         WHEN typeass = 'Monument historique' THEN 'Monument historique'
         WHEN typeass ILIKE '%abords%'        THEN 'Abords de monument historique'
         ELSE typeass END AS categorie,
       -- nom lisible du monument : « AC1_Eglise-Saint-Saturnin-ITDK9S_abor » -> « Eglise Saint Saturnin »
       CASE WHEN suptype = 'ac1'
            THEN trim(replace(regexp_replace(nomass, '^AC1_(.*?)(-[A-Z0-9]{6})?_(mh|abor)$', '\1'), '-', ' '))
            ELSE nomass END AS nom,
       nomass, typeass,
       ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3))::geometry(MultiPolygon, 2154) AS geom
FROM gentilly.sup_brut
WHERE suptype IN ('pm1', 'ac1');
ALTER TABLE gentilly.servitudes ADD PRIMARY KEY (gid);
CREATE INDEX idx_servitudes_geom ON gentilly.servitudes USING gist (geom);

-- Aléa retrait-gonflement des argiles (BRGM, carte 2019) : id = niveau 1 faible, 2 moyen, 3 fort
DROP TABLE IF EXISTS gentilly.argiles;
CREATE TABLE gentilly.argiles AS
SELECT row_number() OVER ()::int AS gid, id::int AS niveau,
       CASE id::int WHEN 1 THEN 'Faible' WHEN 2 THEN 'Moyen' WHEN 3 THEN 'Fort' END AS alea,
       ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3))::geometry(MultiPolygon, 2154) AS geom
FROM gentilly.argiles_brut;
ALTER TABLE gentilly.argiles ADD PRIMARY KEY (gid);
CREATE INDEX idx_argiles_geom ON gentilly.argiles USING gist (geom);

-- Gares et stations IDFM dans un rayon de 3 km (une ligne par arrêt et par ligne)
DROP TABLE IF EXISTS gentilly.gares;
CREATE TABLE gentilly.gares AS
SELECT row_number() OVER ()::int AS gid, nom_gares AS nom, mode, res_com AS ligne, exploitant,
       geom::geometry(Point, 2154) AS geom
FROM gentilly.gares_brut;
ALTER TABLE gentilly.gares ADD PRIMARY KEY (gid);
CREATE INDEX idx_gares_geom ON gentilly.gares USING gist (geom);

DROP TABLE gentilly.plu_zones_brut, gentilly.sup_brut, gentilly.argiles_brut, gentilly.gares_brut;
ANALYZE gentilly.plu_zones; ANALYZE gentilly.servitudes; ANALYZE gentilly.argiles; ANALYZE gentilly.gares;
