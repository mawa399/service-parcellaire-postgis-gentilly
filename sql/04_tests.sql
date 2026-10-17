-- Étape 3 : tests de validation du moteur
-- 1. Les trois portes renvoient la même réponse (même empreinte md5)
SELECT 'id' AS porte, id_parcelle, md5(ventes::text || ST_AsText(geom)) FROM gentilly.parcelle_par_id('940370000H0129')
UNION ALL SELECT 'coords', id_parcelle, md5(ventes::text || ST_AsText(geom)) FROM gentilly.parcelle_par_coords(2.348437, 48.815313)
UNION ALL SELECT 'adresse', id_parcelle, md5(ventes::text || ST_AsText(geom)) FROM gentilly.parcelle_par_adresse('14 pl. Henri-Barbusse');
-- 2. Cas qui doivent renvoyer 0 ligne
SELECT count(*) FROM gentilly.parcelle_par_adresse('3 rue chateaubriant');   -- voie inexistante à Gentilly
SELECT count(*) FROM gentilly.parcelle_par_coords(2.2945, 48.8584);          -- hors commune
SELECT count(*) FROM gentilly.parcelle_par_id('XXX');                         -- identifiant inconnu
-- 3. Géocodeur tolérant aux abréviations
SELECT * FROM gentilly.geocoder('12 av raspail', 3);
-- 4. Parcelle avec historique DVF
SELECT id_parcelle, nb_ventes_5ans, prix_m2_median_parcelle, prix_m2_median_gentilly, ecart_prix_pct
FROM gentilly.parcelle_par_id('940370000K0189');

-- ===== V2 =====
-- 5. Indicateurs urbanisme / risques / transports sur la mairie (parcelle à cheval sur 3 zones)
SELECT zone_plu, zones_plu_detail, abords_monuments, risque_carrieres, alea_argiles,
       gare_proche, gare_proche_dist_m, dist_rer_m, dist_metro_m, dist_tram_m, pente_moy_pct, pente_mediane_pct
FROM gentilly.parcelle_par_id('940370000H0129');
-- 6. Toutes les parcelles ont une zone PLUi et une gare de référence
SELECT count(*) FILTER (WHERE zone_plu IS NULL) AS sans_zone, count(*) FILTER (WHERE gare_proche_dist_m IS NULL) AS sans_gare
FROM gentilly.carte_parcelles;
-- 7. Synthèse communale
SELECT zone_plu, count(*) FROM gentilly.carte_parcelles GROUP BY 1 ORDER BY 2 DESC;
SELECT count(*) FILTER (WHERE risque_carrieres) AS parcelles_ppr_carrieres, count(*) FILTER (WHERE alea_argiles = 'Fort') AS argiles_fort
FROM gentilly.carte_parcelles;

-- ===== V3 =====
-- 8. Les trois portes renvoient toujours une fiche identique (toutes colonnes)
SELECT count(DISTINCT h) AS empreintes_distinctes FROM (
  SELECT md5(t::text) h FROM gentilly.parcelle_par_id('940370000H0129') t
  UNION ALL SELECT md5(t::text) FROM gentilly.parcelle_par_coords(2.348437, 48.815313) t
  UNION ALL SELECT md5(t::text) FROM gentilly.parcelle_par_adresse('14 pl. Henri-Barbusse') t) x;   -- attendu : 1
-- 9. La distance à pied n'est jamais plus courte que le vol d'oiseau (tolérance d'accroche 30 m)
WITH pt AS (SELECT p.id, coalesce((SELECT a.geom FROM gentilly.adresses a WHERE a.id_parcelle = p.id ORDER BY a.numero LIMIT 1), ST_PointOnSurface(p.geom)) g FROM gentilly.parcelles p)
SELECT count(*) FILTER (WHERE a.dist_marche_m < v.d - 30) AS anomalies, round(avg(a.dist_marche_m / NULLIF(v.d, 0))::numeric, 2) AS detour_moyen
FROM pt JOIN gentilly.acces_parcelles a ON a.id_parcelle = pt.id AND a.mode = 'TOUS'
CROSS JOIN LATERAL (SELECT ST_Distance(g.geom, pt.g) d FROM gentilly.gares g WHERE g.noeud IS NOT NULL ORDER BY g.geom <-> pt.g LIMIT 1) v;  -- attendu : 0
-- 10. Arithmétique du potentiel : plancher théorique = surface × emprise max × niveaux
SELECT count(*) FILTER (WHERE abs(sdp_theorique - surface * emprise_max_pct / 100 * niveaux_max) > 0.01) AS ecarts,
       count(*) FILTER (WHERE gisement_sdp < 0) AS negatifs FROM gentilly.potentiel;                 -- attendu : 0, 0
-- 11. Répartition des classes de gisement
SELECT classe_gisement, count(*), round(sum(gisement_sdp)) FROM gentilly.potentiel GROUP BY 1 ORDER BY 2 DESC;
