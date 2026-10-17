-- Étape 1 : création de la base et des extensions
-- (CREATE DATABASE à lancer depuis une autre base, ex. postgres)
CREATE DATABASE gentilly;
-- puis, connecté à la base gentilly :
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_raster;
CREATE EXTENSION IF NOT EXISTS unaccent;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS pgrouting SCHEMA public;
CREATE SCHEMA IF NOT EXISTS gentilly;
