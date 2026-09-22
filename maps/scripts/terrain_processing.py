"""Terrain processing tasks; dependency discovery and scheduling belong to Snakemake."""

import gzip
import hashlib
import inspect
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

import hillshade_original
from data_root import data_root

MERCATOR_LATITUDE = 85.0511287798066


def run(*args):
    subprocess.run([str(a) for a in args], check=True)


def read(path):
    return json.loads(Path(path).read_text())


def save(path, value):
    text = json.dumps(value, sort_keys=True, indent=2) + "\n"
    if not path.exists() or path.read_text() != text:
        path.parent.mkdir(parents=True, exist_ok=True)
        part = path.with_name(path.name + ".part")
        part.write_text(text)
        part.replace(path)


def headroom(*paths):
    for path in paths:
        if shutil.disk_usage(path).free < 100 * 1024**3:
            raise SystemExit(f"Less than 100 GiB headroom on {path}; stopping")


def compress(source, target):
    """Publish gzip only after verifying it decodes to the original bytes."""
    target.parent.mkdir(parents=True, exist_ok=True)
    part = target.with_name(target.name + ".part")
    digest = hashlib.sha256()
    with source.open("rb") as src, gzip.open(part, "wb", compresslevel=6) as dst:
        while block := src.read(1024 * 1024):
            digest.update(block)
            dst.write(block)
    with gzip.open(part, "rb") as restored:
        if hashlib.file_digest(restored, "sha256").digest() != digest.digest():
            raise RuntimeError(f"Compression verification failed: {source}")
    part.replace(target)


def input_info(paths):
    return [{"path": str(p), "size": Path(p).stat().st_size,
             "mtime_ns": Path(p).stat().st_mtime_ns} for p in paths]


def signature(spec, kind, settings):
    # Contour implementation matches the old buffered-GDAL/core-clipping recipe.
    recipe = inspect.getsource(buffered) + inspect.getsource(globals()[kind])
    recipe += inspect.getsource(core_bounds)
    recipe += inspect.getsource(hillshade_original.merge)
    if kind == "hillshade":
        recipe += Path(hillshade_original.__file__).read_text()
    return {"algorithm": f"{kind}-v1", "recipe": hashlib.sha256(recipe.encode()).hexdigest(),
            "lat": spec["lat"], "lon": spec["lon"],
            "inputs": input_info(spec["neighbors"]), "settings": settings,
            "longitude_shifts": spec.get("longitude_shifts", [0] * len(spec["neighbors"])),
            "core_bounds": list(core_bounds(spec))}


def core_bounds(spec):
    return (spec["lon"], max(spec["lat"], -MERCATOR_LATITUDE),
            spec["lon"] + 1, min(spec["lat"] + 1, MERCATOR_LATITUDE))


def buffered(spec, work):
    # Restore the original native DEM merge. Do not resample elevations onto a
    # shifted grid: that changes contour geometry as well as hillshade gradients.
    # Whole neighboring tiles provide the processing margin; clip geometry later.
    inputs = []
    for index, (source, shift) in enumerate(zip(spec["neighbors"], spec.get("longitude_shifts", [0] * len(spec["neighbors"])))):
        if shift:
            from osgeo import gdal
            gdal.UseExceptions()
            # Re-label longitude only: a VRT references the original pixels.
            # Keep the window continuous across 180 without reprojecting/resampling.
            shifted = work / f"neighbor-{index}.vrt"
            dataset = gdal.Translate(str(shifted), source, format="VRT")
            transform = list(dataset.GetGeoTransform())
            transform[0] += shift
            dataset.SetGeoTransform(transform)
            dataset = None
            inputs.append(str(shifted))
        else:
            inputs.append(source)
    return hillshade_original.merge(inputs, work / "buffered.tif")


def contours(spec, config, raster, work):
    raw, result = work / "raw.gpkg", work / "contours.geojsonl"
    run("gdal_contour", "-q", "-a", "elevation", "-i", config["interval"],
        "-f", "GPKG", "-nln", "contours", raster, raw)
    bounds = core_bounds(spec)
    # Preserve the exact Mercator cutoff instead of rounding it outside the
    # projection's domain with GeoJSONSeq's default seven decimal places.
    precision = ["-lco", "COORDINATE_PRECISION=15"] if bounds[1] != spec["lat"] or bounds[3] != spec["lat"] + 1 else []
    run("ogr2ogr", "-f", "GeoJSONSeq", result, raw, *precision, "-clipsrc", *bounds,
        "-dialect", "sqlite", "-sql", "SELECT geom, elevation, CASE WHEN CAST(elevation AS INTEGER) % "
        f"{config['index_interval']} = 0 THEN 1 ELSE 0 END AS is_index FROM contours")
    return result


def hillshade(spec, config, raster, work):
    return hillshade_original.geometry(raster, work, config["bands"],
                                       clip=core_bounds(spec))


def batch(args):
    spec = read(args.spec)
    data_root(spec["data_root"])
    root, directory = Path(spec["root"]), args.spec.parent
    configs = {kind: read(root / "settings" / f"{kind}.json") for kind in spec["kinds"]}
    signatures = {kind: signature(spec, kind, config) for kind, config in configs.items()}
    needed = [kind for kind in spec["kinds"] if not (directory / f"{kind}.geojsonl.gz").exists() or
              not (directory / f"{kind}.meta.json").exists() or
              read(directory / f"{kind}.meta.json") != signatures[kind]]
    if needed:
        scratch = Path(spec["scratch"])
        scratch.mkdir(parents=True, exist_ok=True)
        headroom(scratch, directory)
        # Delete disposable work even on an error; only publish complete gzip files.
        with tempfile.TemporaryDirectory(prefix=directory.name + "-", dir=scratch) as work:
            work = Path(work)
            raster = buffered(spec, work)
            for kind in needed:
                result = globals()[kind](spec, configs[kind], raster, work)
                compress(result, directory / f"{kind}.geojsonl.gz")
                save(directory / f"{kind}.meta.json", signatures[kind])
                print(f"Completed {kind}: {directory.name}", flush=True)
    save(args.receipt, signatures)
    # Refresh the per-batch completion receipt after checking cached layers.
    args.receipt.touch()
