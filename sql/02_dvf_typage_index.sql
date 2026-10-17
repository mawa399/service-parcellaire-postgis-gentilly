-- Étape 2 : typage de la table DVF (importée brute depuis les CSV geo-dvf 2021-2025)
DROP TABLE IF EXISTS gentilly.dvf;
CREATE TABLE gentilly.dvf AS
SELECT row_number() OVER () AS gid,
  id_mutation, date_mutation::date AS date_mutation, nature_mutation,
  NULLIF(valeur_fonciere,'')::numeric AS valeur_fonciere,
  NULLIF(adresse_numero,'') AS adresse_numero, NULLIF(adresse_suffixe,'') AS adresse_suffixe,
  adresse_nom_voie, code_postal, code_commune, id_parcelle,
  NULLIF(nombre_lots,'')::int AS nombre_lots, NULLIF(type_local,'') AS type_local,
  NULLIF(surface_reelle_bati,'')::numeric AS surface_reelle_bati,
  NULLIF(nombre_pieces_principales,'')::int AS nombre_pieces_principales,
  NULLIF(surface_terrain,'')::numeric AS surface_terrain,
  CASE WHEN NULLIF(longitude,'') IS NOT NULL
       THEN ST_Transform(ST_SetSRID(ST_MakePoint(longitude::float8, latitude::float8),4326),2154)::geometry(Point,2154) END AS geom
FROM gentilly.dvf_brut;
ALTER TABLE gentilly.dvf ADD PRIMARY KEY (gid);
CREATE INDEX idx_dvf_id_parcelle ON gentilly.dvf (id_parcelle);
CREATE INDEX idx_dvf_date ON gentilly.dvf (date_mutation);
CREATE INDEX idx_dvf_geom ON gentilly.dvf USING gist (geom);
DROP TABLE gentilly.dvf_brut;
CREATE UNIQUE INDEX IF NOT EXISTS idx_parcelles_id ON gentilly.parcelles (id);

-- MNT LiDAR HD (tuiles 256x256 chargées depuis data/lidar)
CREATE INDEX IF NOT EXISTS idx_mnt_rast ON gentilly.mnt USING gist (ST_ConvexHull(rast));
SET search_path = gentilly, public;
SELECT AddRasterConstraints('mnt'::name, 'rast'::name);
RESET search_path;
ANALYZE gentilly.parcelles; ANALYZE gentilly.batiments; ANALYZE gentilly.dvf; ANALYZE gentilly.mnt;
