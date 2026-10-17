-- =====================================================================
-- Étape 2 bis : adresses BAN, pente du MNT et ventes DVF agrégées par mutation
-- Prérequis : tables gentilly.ban_brut, gentilly.mnt et gentilly.dvf (voir scripts/importer_donnees_qgis.py
-- et 02_dvf_typage_index.sql)
-- =====================================================================

-- Normalisation des libellés (minuscules, sans accents ni ponctuation)
CREATE OR REPLACE FUNCTION gentilly.normaliser(t text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT trim(regexp_replace(regexp_replace(lower(public.unaccent('public.unaccent'::regdictionary, coalesce(t,''))),
              '[^a-z0-9 ]', ' ', 'g'), '\s+', ' ', 'g'))
$$;

-- ---------- Adresses BAN ----------
DROP TABLE IF EXISTS gentilly.adresses;
CREATE TABLE gentilly.adresses AS
SELECT id AS id_ban, NULLIF(numero,'')::int AS numero, NULLIF(rep,'') AS rep, nom_voie, code_postal,
       concat_ws(' ', numero || coalesce(NULLIF(rep,''),''), nom_voie) || ', ' || code_postal || ' Gentilly' AS libelle,
       gentilly.normaliser(nom_voie) AS voie_norm,
       NULLIF(cad_parcelles,'') AS cad_parcelles,
       ST_SetSRID(ST_MakePoint(x::float8, y::float8), 2154)::geometry(Point,2154) AS geom
FROM gentilly.ban_brut;
ALTER TABLE gentilly.adresses ADD PRIMARY KEY (id_ban);
CREATE INDEX idx_adresses_geom ON gentilly.adresses USING gist (geom);
CREATE INDEX idx_adresses_voie_trgm ON gentilly.adresses USING gin (voie_norm gin_trgm_ops);
DROP TABLE gentilly.ban_brut;

-- Rattachement adresse -> parcelle : référence cadastrale de la BAN, sinon parcelle la plus proche
ALTER TABLE gentilly.adresses ADD COLUMN id_parcelle text;
UPDATE gentilly.adresses a SET id_parcelle = split_part(a.cad_parcelles, '|', 1) WHERE a.cad_parcelles IS NOT NULL;
UPDATE gentilly.adresses a SET id_parcelle = (SELECT p.id FROM gentilly.parcelles p ORDER BY p.geom <-> a.geom LIMIT 1)
 WHERE a.id_parcelle IS NULL OR NOT EXISTS (SELECT 1 FROM gentilly.parcelles p WHERE p.id = a.id_parcelle);
CREATE INDEX idx_adresses_parcelle ON gentilly.adresses (id_parcelle);
ANALYZE gentilly.adresses;

-- ---------- Pente : calculée une seule fois sur le MNT complet (pas d'effet de bord entre tuiles) ----------
DROP TABLE IF EXISTS gentilly.mnt_pente;
CREATE TABLE gentilly.mnt_pente AS
SELECT row_number() OVER () AS rid, t.rast
FROM (SELECT ST_Tile(ST_Slope(ST_Union(rast), 1, '32BF', 'PERCENT'), 256, 256) AS rast FROM gentilly.mnt) t;
ALTER TABLE gentilly.mnt_pente ADD PRIMARY KEY (rid);
CREATE INDEX idx_mnt_pente_rast ON gentilly.mnt_pente USING gist (ST_ConvexHull(rast));
SET search_path = gentilly, public;
SELECT AddRasterConstraints('mnt_pente'::name, 'rast'::name);
RESET search_path;

-- ---------- Une ligne par mutation DVF ----------
-- La valeur foncière est répétée sur chaque ligne d'une vente : on prend MAX, jamais SUM.
DROP TABLE IF EXISTS gentilly.dvf_mutations;
CREATE TABLE gentilly.dvf_mutations AS
SELECT id_mutation,
       min(date_mutation) AS date_mutation,
       min(nature_mutation) AS nature_mutation,
       max(valeur_fonciere) AS valeur_fonciere,
       array_agg(DISTINCT id_parcelle) FILTER (WHERE id_parcelle IS NOT NULL) AS parcelles,
       string_agg(DISTINCT type_local, ', ') AS types_locaux,
       sum(surface_reelle_bati) FILTER (WHERE type_local IN ('Appartement','Maison')) AS surface_habitable,
       count(*) FILTER (WHERE type_local IN ('Appartement','Maison')) AS nb_logements,
       count(*) FILTER (WHERE type_local IN ('Local industriel. commercial ou assimilé')) AS nb_locaux_activite
FROM gentilly.dvf GROUP BY id_mutation;
ALTER TABLE gentilly.dvf_mutations ADD PRIMARY KEY (id_mutation);
ALTER TABLE gentilly.dvf_mutations ADD COLUMN prix_m2 numeric;
-- Prix au m² : ventes de logements sans local d'activité, surface habitable > 9 m²
UPDATE gentilly.dvf_mutations SET prix_m2 = round(valeur_fonciere / surface_habitable)
 WHERE nature_mutation IN ('Vente', 'Vente en l''état futur d''achèvement') AND nb_logements > 0
   AND nb_locaux_activite = 0 AND surface_habitable > 9 AND valeur_fonciere > 0;
CREATE INDEX idx_dvf_mut_parcelles ON gentilly.dvf_mutations USING gin (parcelles);
ANALYZE gentilly.mnt_pente; ANALYZE gentilly.dvf_mutations;
