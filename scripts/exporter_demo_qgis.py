"""
Exporte les résultats de la base PostGIS vers docs/data/ pour la démo statique (GitHub Pages).
À lancer dans la console Python de QGIS, après sql/08_couches_api.sql.
La page docs/index.html (copie de web/index.html) lit ces fichiers quand elle est servie
depuis github.io ou ouverte avec ?demo, et reproduit les trois portes dans le navigateur.
"""
import os
from qgis.core import QgsProviderRegistry

CONNEXION = "gentilly"
DOSSIER_PROJET = r""   # à renseigner si le script est lancé depuis la console
if not DOSSIER_PROJET:
    DOSSIER_PROJET = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SORTIE = os.path.join(DOSSIER_PROJET, "docs", "data")
os.makedirs(SORTIE, exist_ok=True)
conn = QgsProviderRegistry.instance().providerMetadata("postgres").findConnection(CONNEXION)


def ecrire(nom, sql):
    texte = conn.executeSql(sql)[0][0]
    with open(os.path.join(SORTIE, nom), "w", encoding="utf-8") as f:
        f.write(texte)
    print(f"{nom:28s} {len(texte)/1e6:5.2f} Mo")


def collection(nom, select):
    ecrire(nom, "SELECT json_build_object('type','FeatureCollection','features', coalesce(json_agg(f),'[]'))::text "
                f"FROM ({select}) f")


COLS = ["id_parcelle", "section", "numero", "surface_m2", "nb_batiments", "taux_emprise_pct", "altitude_moy_m",
        "pente_mediane_pct", "nb_ventes_5ans", "prix_m2_median_parcelle", "zone_plu", "zone_plu_libelle",
        "risque_carrieres", "alea_argiles", "gare_proche_min", "gisement_m2", "taux_utilisation_pct", "classe_gisement"]
props = ", ".join(f"'{c}', {c}" for c in COLS)
collection("carte_parcelles.geojson", "SELECT 'Feature' AS type, ST_AsGeoJSON(geom, 6)::json AS geometry, "
           f"json_build_object({props}) AS properties FROM gentilly.carte_parcelles")
collection("carte_batiments.geojson", "SELECT 'Feature' AS type, ST_AsGeoJSON(geom, 6)::json AS geometry, "
           "'{}'::json AS properties FROM gentilly.carte_batiments")
collection("carte_plu.geojson", "SELECT 'Feature' AS type, ST_AsGeoJSON(geom, 6)::json AS geometry, "
           "json_build_object('code', code, 'nom', nom) AS properties FROM gentilly.carte_plu")
collection("carte_gares.geojson", "SELECT 'Feature' AS type, ST_AsGeoJSON(geom, 6)::json AS geometry, "
           "json_build_object('nom', nom, 'mode', mode, 'ligne', ligne) AS properties FROM gentilly.carte_gares")
collection("carte_isochrones.geojson", "SELECT 'Feature' AS type, ST_AsGeoJSON(geom, 6)::json AS geometry, "
           "json_build_object('minutes', minutes) AS properties FROM gentilly.carte_isochrones")
# Fiches complètes, calculées par le moteur pour chaque parcelle (la géométrie est dans carte_parcelles)
ecrire("fiches.json", "SELECT json_object_agg(i.id_parcelle, to_jsonb(i) - 'geom')::text "
                      "FROM gentilly.parcelles p, gentilly.parcelle_info(p.id) i")
# Adresses pour le géocodeur du navigateur : libellé, voie normalisée, numéro, indice, parcelle, lon, lat
ecrire("adresses.json", "SELECT json_agg(json_build_array(libelle, voie_norm, numero, coalesce(rep,''), id_parcelle, "
                        "round(ST_X(ST_Transform(geom,4326))::numeric,6), round(ST_Y(ST_Transform(geom,4326))::numeric,6)) "
                        "ORDER BY voie_norm, numero)::text FROM gentilly.adresses")
