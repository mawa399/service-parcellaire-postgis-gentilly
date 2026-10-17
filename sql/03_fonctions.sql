-- =====================================================================
-- Étapes 3, V2 et V3 : moteur parcellaire « un moteur, trois portes »
--   gentilly.parcelle_info(id)            -> le moteur (tous les calculs)
--   gentilly.parcelle_par_id(id)          -> porte 1
--   gentilly.parcelle_par_coords(lon,lat) -> porte 2
--   gentilly.parcelle_par_adresse(texte)  -> porte 3 (géocodage BAN en base)
-- Les portes ne font que trouver un identifiant de parcelle puis appellent
-- le moteur : la réponse est identique par construction.
-- =====================================================================

-- ---------- Le moteur ----------
DROP FUNCTION IF EXISTS gentilly.parcelle_info(text) CASCADE;
CREATE FUNCTION gentilly.parcelle_info(p_id text)
RETURNS TABLE (
  id_parcelle              text,
  section                  text,
  numero                   text,
  adresses                 text,
  surface_m2               integer,
  nb_batiments             integer,
  emprise_batie_m2         integer,
  taux_emprise_pct         numeric,
  altitude_moy_m           numeric,
  pente_moy_pct            numeric,
  nb_ventes_5ans           integer,
  derniere_vente           date,
  derniere_valeur          numeric,
  prix_m2_median_parcelle  integer,
  prix_m2_median_gentilly  integer,
  ecart_prix_pct           numeric,
  pente_mediane_pct        numeric,
  zone_plu                 text,
  zone_plu_libelle         text,
  plu_document_url         text,
  zones_plu_detail         text,
  abords_monuments         text,
  risque_carrieres         boolean,
  alea_argiles             text,
  gare_proche              text,
  gare_proche_min          integer,
  gare_proche_marche_m     integer,
  min_rer                  integer,
  min_metro                integer,
  min_tram                 integer,
  regle_emprise            text,
  regle_hauteur            text,
  emprise_max_pct          numeric,
  hauteur_max_m            numeric,
  sdp_existante_m2         integer,
  sdp_theorique_m2         integer,
  gisement_m2              integer,
  taux_utilisation_pct     integer,
  classe_gisement          text,
  ventes                   jsonb,
  geom                     geometry(MultiPolygon, 4326)
)
LANGUAGE sql STABLE AS $$
WITH p AS (
  SELECT pa.id, pa.section, pa.numero, pa.geom FROM gentilly.parcelles pa WHERE pa.id = p_id
),
adr AS (
  SELECT string_agg(a.libelle, ' ; ' ORDER BY a.numero) AS adresses
  FROM gentilly.adresses a WHERE a.id_parcelle = p_id
),
bati AS (   -- un bâtiment est compté une fois (point sur surface) ; l'emprise est découpée à la parcelle
  SELECT count(*) FILTER (WHERE ST_Contains(p.geom, ST_PointOnSurface(b.geom)))::int AS nb,
         coalesce(ST_Area(ST_Union(ST_Intersection(b.geom, p.geom))), 0) AS emprise  -- union : pas de double compte si des bâtiments se chevauchent
  FROM p LEFT JOIN gentilly.batiments b ON ST_Intersects(b.geom, p.geom)
),
relief AS (
  SELECT (SELECT (ST_SummaryStatsAgg(ST_Clip(m.rast, p.geom, true), 1, true)).mean
            FROM gentilly.mnt m WHERE ST_Intersects(m.rast, p.geom)) AS alt,
         (SELECT (ST_SummaryStatsAgg(ST_Clip(s.rast, p.geom, true), 1, true)).mean
            FROM gentilly.mnt_pente s WHERE ST_Intersects(s.rast, p.geom)) AS pente
  FROM p
),
pente_med AS (   -- médiane : robuste aux murs et talus captés par le MNT à 1 m
  SELECT ST_Quantile(ST_Union(ST_Clip(s.rast, p.geom, true)), 1, true, 0.5) AS med
  FROM p JOIN gentilly.mnt_pente s ON ST_Intersects(s.rast, p.geom)
),
plu AS (         -- zone majoritaire en surface
  SELECT z.code, z.nom, z.url_document
  FROM p JOIN gentilly.plu_zones z ON ST_Intersects(z.geom, p.geom)
  ORDER BY ST_Area(ST_Intersection(z.geom, p.geom)) DESC LIMIT 1
),
plu_detail AS (  -- répartition de la parcelle entre les zones, ex. « UI 68 % · UC 30 % »
  SELECT string_agg(code || ' ' || pct || ' %', ' · ' ORDER BY pct DESC) AS detail
  FROM (SELECT z.code, round(100 * sum(ST_Area(ST_Intersection(z.geom, p.geom))) / ST_Area(p.geom))::int AS pct
        FROM p JOIN gentilly.plu_zones z ON ST_Intersects(z.geom, p.geom)
        GROUP BY z.code, p.geom) x
  WHERE pct >= 1
),
servi AS (
  SELECT string_agg(DISTINCT s.nom, ' ; ' ORDER BY s.nom) FILTER (WHERE s.categorie LIKE 'Abords%') AS abords,
         bool_or(s.categorie LIKE 'PPR mouvements%') AS carrieres
  FROM p JOIN gentilly.servitudes s
    ON ST_Intersects(s.geom, p.geom) AND ST_Area(ST_Intersection(s.geom, p.geom)) > 1
),
argile AS (
  SELECT a.alea FROM p JOIN gentilly.argiles a ON ST_Intersects(a.geom, p.geom)
  ORDER BY ST_Area(ST_Intersection(a.geom, p.geom)) DESC LIMIT 1
),
marche AS (      -- temps de marche réels sur le réseau piéton OSM (pgRouting, 4,5 km/h)
  SELECT max(gare || ' (' || ligne || ')') FILTER (WHERE mode = 'TOUS') AS gare,
         max(minutes)        FILTER (WHERE mode = 'TOUS')    AS min_tous,
         max(dist_marche_m)  FILTER (WHERE mode = 'TOUS')    AS m_tous,
         max(minutes)        FILTER (WHERE mode = 'RER')     AS min_rer,
         max(minutes)        FILTER (WHERE mode = 'METRO')   AS min_metro,
         max(minutes)        FILTER (WHERE mode = 'TRAMWAY') AS min_tram
  FROM gentilly.acces_parcelles WHERE id_parcelle = p_id
),
pot AS (SELECT * FROM gentilly.potentiel WHERE id_parcelle = p_id),
borne AS (SELECT max(date_mutation) - interval '5 years' AS d FROM gentilly.dvf_mutations),
v AS (
  SELECT m.* FROM gentilly.dvf_mutations m, borne
  WHERE m.parcelles @> ARRAY[p_id] AND m.date_mutation > borne.d
),
ventes AS (
  SELECT count(*)::int AS nb,
         max(date_mutation) AS derniere,
         (array_agg(valeur_fonciere ORDER BY date_mutation DESC))[1] AS derniere_valeur,
         percentile_cont(0.5) WITHIN GROUP (ORDER BY prix_m2) AS med,
         jsonb_agg(jsonb_build_object(
            'date', date_mutation, 'nature', nature_mutation, 'valeur', valeur_fonciere,
            'types', types_locaux, 'surface_habitable', surface_habitable, 'prix_m2', prix_m2)
           ORDER BY date_mutation DESC) AS liste
  FROM v
),
commune AS (
  SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY m.prix_m2) AS med
  FROM gentilly.dvf_mutations m, borne WHERE m.date_mutation > borne.d
)
SELECT p.id, p.section, p.numero, adr.adresses,
       round(ST_Area(p.geom))::int,
       bati.nb,
       round(bati.emprise)::int,
       round((100 * bati.emprise / NULLIF(ST_Area(p.geom), 0))::numeric, 1),
       round(relief.alt::numeric, 1),
       round(relief.pente::numeric, 1),
       ventes.nb, ventes.derniere, ventes.derniere_valeur,
       round(ventes.med)::int,
       round(commune.med)::int,
       round((100 * (ventes.med - commune.med) / NULLIF(commune.med, 0))::numeric, 1),
       round(pente_med.med::numeric, 1),
       plu.code, plu.nom, plu.url_document, plu_detail.detail,
       servi.abords, coalesce(servi.carrieres, false), argile.alea,
       marche.gare, marche.min_tous, marche.m_tous, marche.min_rer, marche.min_metro, marche.min_tram,
       pot.regle_emprise, pot.regle_hauteur, pot.emprise_max_pct, pot.hauteur_max_m,
       round(pot.sdp_existante)::int, round(pot.sdp_theorique)::int, round(pot.gisement_sdp)::int,
       round(100 * pot.taux_utilisation)::int, pot.classe_gisement,
       coalesce(ventes.liste, '[]'::jsonb),
       ST_Multi(ST_Transform(p.geom, 4326))::geometry(MultiPolygon, 4326)
FROM p CROSS JOIN adr CROSS JOIN bati CROSS JOIN relief CROSS JOIN ventes CROSS JOIN commune
     CROSS JOIN pente_med CROSS JOIN plu_detail CROSS JOIN servi CROSS JOIN marche
     LEFT JOIN plu ON true LEFT JOIN argile ON true LEFT JOIN pot ON true;
$$;

-- ---------- Géocodeur BAN (en base, sans appel externe) ----------
DROP FUNCTION IF EXISTS gentilly.geocoder(text, integer);
CREATE FUNCTION gentilly.geocoder(p_adresse text, p_limite integer DEFAULT 5)
RETURNS TABLE (id_ban text, libelle text, score numeric, id_parcelle text, geom geometry(Point, 4326))
LANGUAGE sql STABLE AS $$
WITH saisie AS (
  SELECT
    NULLIF(substring(gentilly.normaliser(p_adresse) FROM '^(\d+)'), '')::int AS num,
    trim(regexp_replace(
      regexp_replace(gentilly.normaliser(p_adresse), '^\d+\s*(bis|ter|quater|b|t)?\s+', ''),
      '\s*(94250|gentilly)\s*', ' ', 'g')) AS voie
),
voies AS (   -- la voie la plus ressemblante (trigrammes)
  SELECT DISTINCT a.voie_norm, word_similarity(s.voie, a.voie_norm) AS sim
  FROM gentilly.adresses a, saisie s
  WHERE s.voie <> '' AND word_similarity(s.voie, a.voie_norm) >= 0.5
)
SELECT a.id_ban, a.libelle,
       round((v.sim - 0.001 * abs(coalesce(a.numero, 0) - coalesce(s.num, a.numero, 0)))::numeric, 3) AS score,
       a.id_parcelle,
       ST_Transform(a.geom, 4326)::geometry(Point, 4326)
FROM gentilly.adresses a
JOIN voies v ON v.voie_norm = a.voie_norm
CROSS JOIN saisie s
ORDER BY v.sim DESC, (a.voie_norm = s.voie) DESC, abs(coalesce(a.numero, 0) - coalesce(s.num, a.numero, 0)), a.rep NULLS FIRST
LIMIT p_limite;
$$;

-- ---------- Les trois portes ----------
-- RETURNS TABLE répété volontairement : pg_featureserv n'expose pas les fonctions SETOF type composite.

-- Porte 1 : identifiant cadastral (ex. 940370000B0206)
DROP FUNCTION IF EXISTS gentilly.parcelle_par_id(text);
CREATE FUNCTION gentilly.parcelle_par_id(p_id text)
RETURNS TABLE (
  id_parcelle text, section text, numero text, adresses text,
  surface_m2 integer, nb_batiments integer, emprise_batie_m2 integer, taux_emprise_pct numeric,
  altitude_moy_m numeric, pente_moy_pct numeric,
  nb_ventes_5ans integer, derniere_vente date, derniere_valeur numeric,
  prix_m2_median_parcelle integer, prix_m2_median_gentilly integer, ecart_prix_pct numeric,
  pente_mediane_pct numeric, zone_plu text, zone_plu_libelle text, plu_document_url text, zones_plu_detail text,
  abords_monuments text, risque_carrieres boolean, alea_argiles text,
  gare_proche text, gare_proche_min integer, gare_proche_marche_m integer, min_rer integer, min_metro integer, min_tram integer,
  regle_emprise text, regle_hauteur text, emprise_max_pct numeric, hauteur_max_m numeric,
  sdp_existante_m2 integer, sdp_theorique_m2 integer, gisement_m2 integer, taux_utilisation_pct integer, classe_gisement text,
  ventes jsonb, geom geometry(MultiPolygon, 4326)
)
LANGUAGE sql STABLE AS $$
  SELECT * FROM gentilly.parcelle_info(upper(trim(p_id)));
$$;

-- Porte 2 : coordonnées WGS84 ; repli à 15 m si le point tombe sur la voirie
DROP FUNCTION IF EXISTS gentilly.parcelle_par_coords(double precision, double precision);
CREATE FUNCTION gentilly.parcelle_par_coords(p_lon double precision, p_lat double precision)
RETURNS TABLE (
  id_parcelle text, section text, numero text, adresses text,
  surface_m2 integer, nb_batiments integer, emprise_batie_m2 integer, taux_emprise_pct numeric,
  altitude_moy_m numeric, pente_moy_pct numeric,
  nb_ventes_5ans integer, derniere_vente date, derniere_valeur numeric,
  prix_m2_median_parcelle integer, prix_m2_median_gentilly integer, ecart_prix_pct numeric,
  pente_mediane_pct numeric, zone_plu text, zone_plu_libelle text, plu_document_url text, zones_plu_detail text,
  abords_monuments text, risque_carrieres boolean, alea_argiles text,
  gare_proche text, gare_proche_min integer, gare_proche_marche_m integer, min_rer integer, min_metro integer, min_tram integer,
  regle_emprise text, regle_hauteur text, emprise_max_pct numeric, hauteur_max_m numeric,
  sdp_existante_m2 integer, sdp_theorique_m2 integer, gisement_m2 integer, taux_utilisation_pct integer, classe_gisement text,
  ventes jsonb, geom geometry(MultiPolygon, 4326)
)
LANGUAGE sql STABLE AS $$
  WITH pt AS (SELECT ST_Transform(ST_SetSRID(ST_MakePoint(p_lon, p_lat), 4326), 2154) AS g),
  cible AS (
    SELECT pa.id FROM gentilly.parcelles pa, pt
    WHERE ST_DWithin(pa.geom, pt.g, 15)
    ORDER BY ST_Intersects(pa.geom, pt.g) DESC, pa.geom <-> pt.g
    LIMIT 1
  )
  SELECT i.* FROM cible, gentilly.parcelle_info(cible.id) i;
$$;

-- Porte 3 : adresse postale, géocodée sur la BAN chargée en base
DROP FUNCTION IF EXISTS gentilly.parcelle_par_adresse(text);
CREATE FUNCTION gentilly.parcelle_par_adresse(p_adresse text)
RETURNS TABLE (
  id_parcelle text, section text, numero text, adresses text,
  surface_m2 integer, nb_batiments integer, emprise_batie_m2 integer, taux_emprise_pct numeric,
  altitude_moy_m numeric, pente_moy_pct numeric,
  nb_ventes_5ans integer, derniere_vente date, derniere_valeur numeric,
  prix_m2_median_parcelle integer, prix_m2_median_gentilly integer, ecart_prix_pct numeric,
  pente_mediane_pct numeric, zone_plu text, zone_plu_libelle text, plu_document_url text, zones_plu_detail text,
  abords_monuments text, risque_carrieres boolean, alea_argiles text,
  gare_proche text, gare_proche_min integer, gare_proche_marche_m integer, min_rer integer, min_metro integer, min_tram integer,
  regle_emprise text, regle_hauteur text, emprise_max_pct numeric, hauteur_max_m numeric,
  sdp_existante_m2 integer, sdp_theorique_m2 integer, gisement_m2 integer, taux_utilisation_pct integer, classe_gisement text,
  ventes jsonb, geom geometry(MultiPolygon, 4326)
)
LANGUAGE sql STABLE AS $$
  SELECT i.* FROM (SELECT g.id_parcelle FROM gentilly.geocoder(p_adresse, 1) g) c,
         gentilly.parcelle_info(c.id_parcelle) i;
$$;
