-- =====================================================================
-- Couches d'affichage (WGS84) et rôle en lecture seule pour pg_featureserv
-- À exécuter en dernier, après 03_fonctions.sql.
-- Avec psql : psql -d gentilly -v mdp="'un_mot_de_passe'" -f 08_couches_api.sql
-- =====================================================================

-- Indicateurs précalculés pour colorer la carte (une ligne par parcelle)
DROP TABLE IF EXISTS gentilly.carte_parcelles;
CREATE TABLE gentilly.carte_parcelles AS
SELECT i.id_parcelle, i.section, i.numero, i.surface_m2, i.nb_batiments, i.taux_emprise_pct,
       i.altitude_moy_m, i.pente_mediane_pct, i.nb_ventes_5ans, i.prix_m2_median_parcelle,
       i.zone_plu, i.zone_plu_libelle, i.risque_carrieres, i.alea_argiles,
       i.gare_proche_min, i.gisement_m2, i.taux_utilisation_pct, i.classe_gisement,
       i.geom::geometry(MultiPolygon,4326) AS geom
FROM gentilly.parcelles p, gentilly.parcelle_info(p.id) i;
ALTER TABLE gentilly.carte_parcelles ADD PRIMARY KEY (id_parcelle);
CREATE INDEX idx_carte_parcelles_geom ON gentilly.carte_parcelles USING gist (geom);

DROP TABLE IF EXISTS gentilly.carte_batiments;
CREATE TABLE gentilly.carte_batiments AS
SELECT row_number() OVER ()::int AS gid, ST_Multi(ST_Transform(geom,4326))::geometry(MultiPolygon,4326) AS geom
FROM gentilly.batiments;
ALTER TABLE gentilly.carte_batiments ADD PRIMARY KEY (gid);

DROP TABLE IF EXISTS gentilly.carte_plu;
CREATE TABLE gentilly.carte_plu AS
SELECT gid, code, nom, typezone, ST_Transform(geom,4326)::geometry(MultiPolygon,4326) AS geom FROM gentilly.plu_zones;
ALTER TABLE gentilly.carte_plu ADD PRIMARY KEY (gid);

DROP TABLE IF EXISTS gentilly.carte_gares;
CREATE TABLE gentilly.carte_gares AS
SELECT gid, nom, mode, ligne, ST_Transform(geom,4326)::geometry(Point,4326) AS geom FROM gentilly.gares;
ALTER TABLE gentilly.carte_gares ADD PRIMARY KEY (gid);

DROP TABLE IF EXISTS gentilly.carte_isochrones;
CREATE TABLE gentilly.carte_isochrones AS
SELECT minutes, ST_Transform(ST_SimplifyPreserveTopology(geom, 3), 4326)::geometry(MultiPolygon,4326) AS geom
FROM gentilly.isochrones;
ALTER TABLE gentilly.carte_isochrones ADD PRIMARY KEY (minutes);
ANALYZE gentilly.carte_parcelles;

-- Rôle dédié à l'API, en lecture seule
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'gentilly_api') THEN CREATE ROLE gentilly_api LOGIN; END IF;
END $$;
ALTER ROLE gentilly_api WITH PASSWORD :mdp;
GRANT CONNECT ON DATABASE gentilly TO gentilly_api;
GRANT USAGE ON SCHEMA gentilly, public TO gentilly_api;
GRANT SELECT ON ALL TABLES IN SCHEMA gentilly TO gentilly_api;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA gentilly TO gentilly_api;
ALTER DEFAULT PRIVILEGES IN SCHEMA gentilly GRANT SELECT ON TABLES TO gentilly_api;
ALTER DEFAULT PRIVILEGES IN SCHEMA gentilly GRANT EXECUTE ON FUNCTIONS TO gentilly_api;
