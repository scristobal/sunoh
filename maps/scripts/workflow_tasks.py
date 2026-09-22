"""Processing and acquisition tasks called by Snakemake; no nested build engine."""

from functools import lru_cache
import hashlib
import inspect
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
from types import SimpleNamespace

import terrain_processing as terrain
import terrain_tiling

ROOT = Path(__file__).resolve().parent.parent
BUCKET = "copernicus-dem-30m"
NATURAL_EARTH = {
    "ocean": ("ne_10m_ocean", "10m_physical"),
    "borders": ("ne_50m_admin_0_boundary_lines_land", "50m_cultural"),
    "countries": ("ne_50m_admin_0_countries", "50m_cultural"),
    "admin1-borders": ("ne_10m_admin_1_states_provinces_lines", "10m_cultural"),
    "admin1-labels": ("ne_10m_admin_1_states_provinces", "10m_cultural"),
}
COASTLINE_URL = "https://osmdata.openstreetmap.de/download/water-polygons-split-4326.zip"


def recipe(*functions):
    return hashlib.sha256("\n".join(inspect.getsource(function) for function in functions).encode()).hexdigest()


def run(*args, **kwargs):
    subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def download(url, output, snapshot=False, retries=3):
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    part = output.with_name(output.name + ".part")
    if snapshot:
        receipt = output.with_name(output.name + ".url")
        if not receipt.exists() or not receipt.stat().st_size:
            resolved = subprocess.check_output([
                "curl", "-fsIL", "-o", "/dev/null", "-w", "%{url_effective}\n", url
            ], text=True)
            temporary = receipt.with_name(receipt.name + ".part")
            temporary.write_text(resolved)
            temporary.replace(receipt)
        url = receipt.read_text().strip()
        run("curl", "-fL", "--retry", 5, "--retry-delay", 10, "-C", "-", url, "-o", part)
    else:
        run("curl", "-fL", "--retry", retries, url, "-o", part)
    part.replace(output)


def inventory(output):
    result = subprocess.check_output([
        "aws", "s3api", "list-objects-v2", "--bucket", BUCKET,
        "--prefix", "Copernicus_DSM_COG_10_", "--no-sign-request",
        "--query", "Contents[?ends_with(Key, '_DEM.tif')].[Key,Size,ETag]", "--output", "json",
    ], text=True, env=dict(os.environ, AWS_PAGER=""))
    objects = [{"key": key, "size": size, "etag": etag} for key, size, etag in json.loads(result)]
    if not objects:
        raise ValueError("No DEMs returned; refusing to replace inventory")
    terrain.save(Path(output), {"bucket": BUCKET, "objects": objects})


@lru_cache(maxsize=4)
def dem_records(path):
    manifest = terrain.read(path)
    if manifest["bucket"] != BUCKET:
        raise ValueError("Unexpected DEM inventory bucket")
    return {Path(item["key"]).stem: item for item in manifest["objects"]}


def download_dem(manifest, name, output):
    item = dem_records(str(manifest))[name]
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    terrain.headroom(output.parent)
    part = output.with_suffix(".tif.part")
    run("aws", "s3", "cp", f"s3://{BUCKET}/{item['key']}", part,
        "--no-sign-request", "--only-show-errors")
    if part.stat().st_size != item["size"]:
        raise ValueError(f"Unexpected download size: {part}")
    part.replace(output)


def terrain_settings(config):
    return {
        "contours": {"interval": int(config["CONTOUR_INTERVAL"]),
                     "index_interval": int(config["INDEX_INTERVAL"])},
        "hillshade": {"bands": config["HILLSHADE_BANDS"], "recipe": "original-gdal",
                      "coarse_resolution": 0.003, "smooth_resolution": 0.00028,
                      "polygon_simplification": 0.0003},
    }


def plan_terrain(manifest, directory, config, kinds):
    data, directory = Path(config["DATA_ROOT"]), Path(directory)
    entries = {}
    for name, item in dem_records(str(manifest)).items():
        match = re.fullmatch(r"Copernicus_DSM_COG_10_([NS])(\d+)_00_([EW])(\d+)_00_DEM", name)
        if not match:
            raise ValueError(f"Unexpected DEM name: {name}")
        lat = int(match[2]) * (1 if match[1] == "N" else -1)
        lon = int(match[4]) * (1 if match[3] == "E" else -1)
        entries[lat, lon] = name
    bbox = [int(value) for value in config["TERRAIN_BBOX"].split(",")] if config["TERRAIN_BBOX"] else None
    report = {"ready": [], "outside_mercator": [], "waiting": [], "missing_downloads": [], "deferred_edges": []}
    for (lat, lon), name in sorted(entries.items(), key=lambda item: item[1]):
        if lat >= terrain.MERCATOR_LATITUDE or lat + 1 <= -terrain.MERCATOR_LATITUDE:
            report["outside_mercator"].append(name)
            continue
        if bbox and not (bbox[0] <= lon < bbox[2] and bbox[1] <= lat < bbox[3]):
            continue
        if config["TERRAIN_BATCH_LIMIT"] and len(report["ready"]) >= config["TERRAIN_BATCH_LIMIT"]:
            break
        neighbors, shifts = [], []
        for y in range(lat - 1, lat + 2):
            for x in range(lon - 1, lon + 2):
                wrapped = (x + 180) % 360 - 180
                if (y, wrapped) in entries:
                    neighbors.append(str(data / "downloads/dem" / (entries[y, wrapped] + ".tif")))
                    shifts.append(x - wrapped)
        terrain.save(directory / (name + ".json"), {
            "lat": lat, "lon": lon, "neighbors": neighbors, "longitude_shifts": shifts,
            "data_root": str(data), "root": str(data / "geometry/terrain"),
            "scratch": str(data / "scratch/terrain-processing"), "kinds": kinds,
        })
        report["ready"].append(name)
    if not report["ready"]:
        raise ValueError("No terrain cores selected")
    terrain.save(directory / "coverage.json", report)


def process_batch(specification, receipt):
    os.environ.setdefault("GDAL_CACHEMAX", "256")
    spec = terrain.read(specification)
    destination = Path(spec["root"]) / "batches" / Path(specification).name.removesuffix(".json") / "batch.json"
    terrain.save(destination, spec)
    terrain.batch(SimpleNamespace(spec=destination, receipt=Path(receipt)))


def tile_terrain(inputs, coverage, kind, config, threads):
    data = Path(config["DATA_ROOT"])
    records = terrain.input_info(inputs)
    settings = terrain_settings(config)[kind]
    for path in inputs:
        metadata = terrain.read(Path(path).with_name(f"{kind}.meta.json"))
        if metadata["settings"] != settings:
            raise ValueError(f"Stale terrain settings: {path}")
    manifest = data / "scratch/snakemake" / f"{kind}-inputs.json"
    terrain.save(manifest, {
        "kind": kind, "output": str(data / "tiles" / f"{kind}.pmtiles"),
        "inputs": records, "minzoom": 9 if kind == "contours" else 5,
        "maxzoom": config["TERRAIN_TILE_MAXZOOM"],
        "simplification": config["TERRAIN_TILE_SIMPLIFICATION"], "threads": threads,
        "data_root": str(data),
        "excluded": {key: len(value) for key, value in terrain.read(coverage).items() if key != "ready"},
        "tippecanoe": subprocess.check_output(["tippecanoe", "--version"], stderr=subprocess.STDOUT, text=True).strip(),
    })
    terrain_tiling.tile(SimpleNamespace(manifest=manifest))


def convert_overview(name, source, output):
    options = {
        "ocean": ["-select", "featurecla"],
        "borders": ["-select", "featurecla"],
        "admin1-borders": ["-select", "featurecla"],
        "countries": ["-dialect", "sqlite", "-sql", "SELECT ST_PointOnSurface(geometry) AS geometry, NAME_EN AS name, LABELRANK AS rank FROM ne_50m_admin_0_countries"],
        "admin1-labels": ["-dialect", "sqlite", "-sql", "SELECT ST_PointOnSurface(geometry) AS geometry, COALESCE(name_en, name) AS name FROM ne_10m_admin_1_states_provinces"],
    }
    run("ogr2ogr", "-overwrite", "-f", "GeoJSONSeq", output, f"/vsizip/{source}", *options[name])


def verify_archive(path):
    run(sys.executable, ROOT / "scripts/fix-pmtiles-center.py", path)
    run("pmtiles", "verify", path)


def planetiler(name, output, config):
    temporary = Path(config["PLANETILER_TMP_DIR"])
    (temporary / Path(output).name).mkdir(parents=True, exist_ok=True)
    run("docker", "run", "--rm", "--user", f"{os.getuid()}:{os.getgid()}",
        *shlex.split(config["PLANETILER_DOCKER_ARGS"]),
        "-e", f"JAVA_TOOL_OPTIONS=-Xmx{config['PLANETILER_HEAP']}",
        "-v", f"{config['OSM_PBF']}:/data/downloads/osm/planet.osm.pbf:ro",
        "-v", f"{temporary}:/data/scratch/planetiler",
        "-v", f"{Path(output).parent}:/data/tiles", config["PLANETILER_IMAGE"],
        f"--archive={name}", "--osm-path=/data/downloads/osm/planet.osm.pbf",
        f"--output=/data/tiles/{name}.pmtiles", f"--tmpdir=/data/scratch/planetiler/{name}.pmtiles",
        f"--minzoom={7 if name == 'ski' else config['BASEMAP_MINZOOM']}",
        f"--maxzoom={14 if name == 'ski' else config['BASEMAP_MAXZOOM']}",
        *shlex.split(config["PLANETILER_ARGS"]))
    verify_archive(output)
    shutil.rmtree(temporary / Path(output).name)
