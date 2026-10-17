"""
Importe les données de data/ dans la base PostGIS « gentilly » (schéma gentilly).
À lancer dans la console Python de QGIS (Extensions > Console Python > Ouvrir un script),
après avoir créé une connexion PostGIS nommée « gentilly » dans l'Explorateur de QGIS
et exécuté sql/01_creation_base.sql.

Ce script prépare les tables brutes ; les traitements sont ensuite faits en SQL
(voir l'ordre d'exécution dans le README).
"""
import binascii, json, os
from collections import Counter

import processing
from osgeo import gdal, osr
from qgis.core import QgsCoordinateReferenceSystem, QgsProviderRegistry, QgsVectorLayer

CONNEXION = "gentilly"            # nom de la connexion PostGIS enregistrée dans QGIS
DOSSIER_PROJET = r""              # à renseigner si le script est lancé depuis la console, ex. r"C:\...\service-parcellaire-postgis-gentilly"
if not DOSSIER_PROJET:
    DOSSIER_PROJET = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
DATA = os.path.abspath(os.path.join(DOSSIER_PROJET, "data")).replace("\\", "/")
conn = QgsProviderRegistry.instance().providerMetadata("postgres").findConnection(CONNEXION)
L93 = QgsCoordinateReferenceSystem("EPSG:2154")


def importer(couche, table, reprojeter=True, corriger=True, geom="geom"):
    """Reprojette en Lambert 93, corrige les géométries et charge la couche dans gentilly.<table>."""
    if reprojeter:
        couche = processing.run("native:reprojectlayer", {"INPUT": couche, "TARGET_CRS": L93, "OUTPUT": "memory:"})["OUTPUT"]
    if corriger and couche.geometryType() == 2:
        couche = processing.run("native:fixgeometries", {"INPUT": couche, "OUTPUT": "memory:"})["OUTPUT"]
    processing.run("native:importintopostgis", {
        "INPUT": couche, "DATABASE": CONNEXION, "SCHEMA": "gentilly", "TABLENAME": table, "PRIMARY_KEY": "",
        "GEOMETRY_COLUMN": geom, "ENCODING": "UTF-8", "OVERWRITE": True, "CREATEINDEX": True,
        "LOWERCASE_NAMES": True, "DROP_STRING_LENGTH": True, "FORCE_SINGLEPART": False})
    print(f"{table:20s} {couche.featureCount():>6} entités")


def lire(rel, nom="couche"):
    c = QgsVectorLayer(f"{DATA}/{rel}", nom, "ogr")
    assert c.isValid(), rel
    return c


# ---------- V1 : cadastre, DVF, BAN, MNT ----------
for couche in ("parcelles", "batiments"):           # GeoJSON compressés lus directement via /vsigzip/
    c = QgsVectorLayer(f"/vsigzip/{DATA}/cadastre/cadastre-94037-{couche}.json.gz", couche, "ogr")
    assert c.isValid(), couche
    importer(c, couche)

dvf = processing.run("native:mergevectorlayers", {
    "LAYERS": [lire(f"dvf/dvf_94037_{a}.csv", f"dvf{a}") for a in range(2021, 2026)], "OUTPUT": "memory:"})["OUTPUT"]
importer(dvf, "dvf_brut", reprojeter=False)          # typage en SQL (02_dvf_typage_index.sql)
importer(lire("ban/ban_94037.csv"), "ban_brut", reprojeter=False)

# MNT LiDAR HD : tuiles de 256 x 256 px insérées avec ST_FromGDALRaster
mnt = gdal.Open(f"{DATA}/lidar/mnt_lidarhd_gentilly_1m.tif")
srs = osr.SpatialReference(); srs.ImportFromEPSG(2154)
conn.executeSql("DROP TABLE IF EXISTS gentilly.mnt; CREATE TABLE gentilly.mnt (rid serial PRIMARY KEY, rast raster);")
T, n = 256, 0
for yo in range(0, mnt.RasterYSize, T):
    for xo in range(0, mnt.RasterXSize, T):
        tmp = f"/vsimem/tuile_{xo}_{yo}.tif"
        gdal.Translate(tmp, mnt, srcWin=[xo, yo, min(T, mnt.RasterXSize - xo), min(T, mnt.RasterYSize - yo)],
                       outputSRS=srs, noData=-9999)
        f = gdal.VSIFOpenL(tmp, "rb"); gdal.VSIFSeekL(f, 0, 2); taille = gdal.VSIFTellL(f); gdal.VSIFSeekL(f, 0, 0)
        octets = gdal.VSIFReadL(1, taille, f); gdal.VSIFCloseL(f); gdal.Unlink(tmp)
        conn.executeSql("INSERT INTO gentilly.mnt (rast) VALUES "
                        f"(ST_FromGDALRaster(decode('{binascii.hexlify(octets).decode()}', 'hex'), 2154))")
        n += 1
print(f"{'mnt':20s} {n:>6} tuiles")

# ---------- V2 : PLUi, servitudes, argiles, gares ----------
importer(lire("plu/zone_urba_gpu.geojson"), "plu_zones_brut")
importer(lire("plu/assiette_sup_s_gpu.geojson"), "sup_brut")
importer(lire("risques/alea_argiles_brgm.geojson"), "argiles_brut")
gares = processing.run("native:deletecolumn", {"INPUT": lire("transports/gares_idfm_3km.geojson"),
                                               "COLUMN": ["geo_point_2d", "picto"], "OUTPUT": "memory:"})["OUTPUT"]
importer(gares, "gares_brut")

# ---------- V3 : bâtiments BD TOPO (hauteurs) ----------
b = processing.run("native:retainfields", {"INPUT": lire("bdtopo_batiments.geojson"), "OUTPUT": "memory:",
                   "FIELDS": ["cleabs", "nature", "usage_1", "construction_legere", "nombre_de_logements",
                              "nombre_d_etages", "hauteur"]})["OUTPUT"]
b = processing.run("native:assignprojection", {"INPUT": b, "CRS": L93, "OUTPUT": "memory:"})["OUTPUT"]
b = processing.run("native:dropmzvalues", {"INPUT": b, "DROP_M_VALUES": True, "DROP_Z_VALUES": True, "OUTPUT": "memory:"})["OUTPUT"]
importer(b, "bdtopo_batiments", reprojeter=False)

# ---------- V3 : réseau piéton OSM -> tronçons découpés aux nœuds partagés ----------
osm = json.load(open(f"{DATA}/transports/osm_reseau_pieton.json", encoding="utf-8"))
noeuds = {e["id"]: (e["lon"], e["lat"]) for e in osm["elements"] if e["type"] == "node"}
voies = [e for e in osm["elements"] if e["type"] == "way"]
usage = Counter()
for v in voies:
    for i, nd in enumerate(v["nodes"]):
        usage[nd] += 2 if i in (0, len(v["nodes"]) - 1) else 1
troncons = []
for v in voies:
    nds = [x for x in v["nodes"] if x in noeuds]
    if len(nds) < 2:
        continue
    hw, debut = v.get("tags", {}).get("highway", ""), 0
    for i in range(1, len(nds)):
        if i == len(nds) - 1 or usage[nds[i]] > 1:
            seg = nds[debut:i + 1]
            if (len(seg) >= 2 and seg[0] != seg[-1]) or len(seg) > 2:
                troncons.append((v["id"], hw, seg[0], seg[-1],
                                 "LINESTRING(" + ",".join(f"{noeuds[x][0]} {noeuds[x][1]}" for x in seg) + ")"))
            debut = i
conn.executeSql("""DROP TABLE IF EXISTS gentilly.reseau_pieton;
CREATE TABLE gentilly.reseau_pieton (id serial PRIMARY KEY, osm_id bigint, highway text, source bigint, target bigint,
  cost double precision, reverse_cost double precision, geom geometry(LineString,2154));""")
for k in range(0, len(troncons), 1500):
    valeurs = ",".join(f"({o},'{h}',{a},{z},ST_Transform(ST_GeomFromText('{g}',4326),2154))"
                       for o, h, a, z, g in troncons[k:k + 1500])
    conn.executeSql(f"INSERT INTO gentilly.reseau_pieton (osm_id, highway, source, target, geom) VALUES {valeurs}")
print(f"{'reseau_pieton':20s} {len(troncons):>6} tronçons")
print("Import terminé. Suite : fichiers SQL dans l'ordre du README.")
