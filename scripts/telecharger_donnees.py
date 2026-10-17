"""
Télécharge toutes les données ouvertes du projet dans le dossier data/.
Python 3.9+ sans dépendance (bibliothèque standard uniquement).

Usage :  python scripts/telecharger_donnees.py            (tout sauf le règlement PDF)
         python scripts/telecharger_donnees.py --reglement (ajoute le règlement écrit du PLUi, 311 Mo)
"""
import csv, gzip, io, json, os, sys, time, urllib.parse, urllib.request

RACINE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data")
INSEE, DEP = "94037", "94"
# Emprise de Gentilly en Lambert 93 (élargie de 20 m) et en WGS84 (élargie de 1,3 km pour le réseau piéton)
BBOX_L93 = (650711, 6856335, 652742, 6857823)
BBOX_OSM = (48.79360, 2.31115, 48.83034, 2.37412)          # sud, ouest, nord, est
ENVELOPPE_WGS84 = {"type": "Polygon", "coordinates": [[[2.3285, 48.8049], [2.3283, 48.8189], [2.3568, 48.819],
                                                        [2.357, 48.8051], [2.3285, 48.8049]]]}   # parcelles + 50 m
UA = {"User-Agent": "service-parcellaire-postgis-gentilly"}


def get(url, data=None, timeout=120):
    req = urllib.request.Request(url, data=data, headers=UA)
    return urllib.request.urlopen(req, timeout=timeout).read()


def ecrire(rel, contenu):
    chemin = os.path.join(RACINE, rel)
    os.makedirs(os.path.dirname(chemin), exist_ok=True)
    with open(chemin, "wb") as f:
        f.write(contenu)
    print(f"  {rel:55s} {len(contenu)/1e6:7.2f} Mo")


def cadastre():
    for couche in ("parcelles", "batiments"):
        url = f"https://cadastre.data.gouv.fr/data/etalab-cadastre/latest/geojson/communes/{DEP}/{INSEE}/cadastre-{INSEE}-{couche}.json.gz"
        ecrire(f"cadastre/cadastre-{INSEE}-{couche}.json.gz", get(url))


def dvf():
    for annee in range(2021, 2026):
        url = f"https://files.data.gouv.fr/geo-dvf/latest/csv/{annee}/communes/{DEP}/{INSEE}.csv"
        ecrire(f"dvf/dvf_{INSEE}_{annee}.csv", get(url))


def ban():
    brut = gzip.decompress(get(f"https://adresse.data.gouv.fr/data/ban/adresses/latest/csv/adresses-{DEP}.csv.gz"))
    lignes = list(csv.reader(io.StringIO(brut.decode("utf-8")), delimiter=";"))
    i = lignes[0].index("code_insee")
    sortie = io.StringIO()
    csv.writer(sortie, delimiter=";").writerows([lignes[0]] + [l for l in lignes[1:] if l[i] == INSEE])
    ecrire(f"ban/ban_{INSEE}.csv", sortie.getvalue().encode("utf-8"))


def lidar():
    xmin, ymin, xmax, ymax = 650700, 6856330, 652750, 6857830          # MNT LiDAR HD à 1 m
    url = ("https://data.geopf.fr/wms-r?SERVICE=WMS&VERSION=1.3.0&REQUEST=GetMap"
           "&LAYERS=IGNF_LIDAR-HD_MNT_ELEVATION.ELEVATIONGRIDCOVERAGE.LAMB93&STYLES="
           f"&CRS=EPSG:2154&BBOX={xmin},{ymin},{xmax},{ymax}&WIDTH={xmax-xmin}&HEIGHT={ymax-ymin}&FORMAT=image/geotiff")
    ecrire("lidar/mnt_lidarhd_gentilly_1m.tif", get(url, timeout=180))


def urbanisme_risques():
    q = urllib.parse.quote(json.dumps(ENVELOPPE_WGS84))
    ecrire("plu/zone_urba_gpu.geojson", get(f"https://apicarto.ign.fr/api/gpu/zone-urba?geom={q}"))
    ecrire("plu/assiette_sup_s_gpu.geojson", get(f"https://apicarto.ign.fr/api/gpu/assiette-sup-s?geom={q}"))
    bb = ",".join(map(str, BBOX_L93))
    ecrire("risques/alea_argiles_brgm.geojson", get(
        "https://mapsref.brgm.fr/wxs/georisques/risques?service=WFS&version=2.0.0&request=GetFeature"
        f"&typeNames=ms:ALEARG_REALISE&srsName=EPSG:2154&bbox={bb},urn:ogc:def:crs:EPSG::2154&outputFormat=geojson"))


def transports():
    w = urllib.parse.quote("within_distance(geo_point_2d, geom'POINT(2.3445 48.8135)', 3km)")
    ecrire("transports/gares_idfm_3km.geojson", get(
        "https://data.iledefrance-mobilites.fr/api/explore/v2.1/catalog/datasets/emplacement-des-gares-idf/exports/geojson"
        f"?where={w}"))
    s, o, n, e = BBOX_OSM
    requete = f"""[out:json][timeout:120];
way["highway"~"^(footway|pedestrian|path|steps|living_street|residential|service|unclassified|tertiary|tertiary_link|secondary|secondary_link|primary|primary_link|track|cycleway|corridor)$"]["access"!~"^(private|no)$"]["foot"!~"^(no)$"]({s},{o},{n},{e});
(._;>;);
out body qt;"""
    ecrire("transports/osm_reseau_pieton.json",
           get("https://overpass-api.de/api/interpreter", data=urllib.parse.urlencode({"data": requete}).encode(), timeout=180))


def bdtopo():
    base = ("https://data.geopf.fr/wfs/ows?SERVICE=WFS&VERSION=2.0.0&REQUEST=GetFeature&TYPENAMES=BDTOPO_V3:batiment"
            "&SRSNAME=EPSG:2154&OUTPUTFORMAT=application/json")
    bb = ",".join(map(str, BBOX_L93))
    entites, depart = [], 0
    while True:
        page = json.loads(get(f"{base}&BBOX={bb},urn:ogc:def:crs:EPSG::2154&COUNT=1000&STARTINDEX={depart}"))
        entites += page["features"]
        if len(page["features"]) < 1000:
            break
        depart += 1000
    fc = {"type": "FeatureCollection", "crs": {"type": "name", "properties": {"name": "urn:ogc:def:crs:EPSG::2154"}},
          "features": entites}
    ecrire("bdtopo_batiments.geojson", json.dumps(fc).encode("utf-8"))


def reglement():
    doc = "2e018aad7e25effb980f4d34d2d7829c"
    nom = "200058014_reglement_20251216.pdf"
    url = f"https://www.geoportail-urbanisme.gouv.fr/api/document/{doc}/files/{nom}"
    chemin = os.path.join(RACINE, "plu", nom)
    os.makedirs(os.path.dirname(chemin), exist_ok=True)
    for essai in range(30):                                      # téléchargement avec reprise
        deja = os.path.getsize(chemin) if os.path.exists(chemin) else 0
        try:
            r = urllib.request.urlopen(urllib.request.Request(url, headers={**UA, "Range": f"bytes={deja}-"}), timeout=120)
            with open(chemin, "ab" if r.status == 206 else "wb") as f:
                while (b := r.read(1 << 20)):
                    f.write(b)
            break
        except urllib.error.HTTPError as err:
            if err.code == 416:
                break
            time.sleep(3)
        except OSError:
            time.sleep(3)
    print(f"  plu/{nom:51s} {os.path.getsize(chemin)/1e6:7.2f} Mo")


if __name__ == "__main__":
    etapes = [cadastre, dvf, ban, lidar, urbanisme_risques, transports, bdtopo]
    if "--reglement" in sys.argv:
        etapes.append(reglement)
    for etape in etapes:
        print(etape.__name__)
        etape()
    print("Terminé :", os.path.abspath(RACINE))
