#!/usr/bin/env python3
"""Check source inputs and configuration without generating or validating outputs."""

import argparse
import json
import math
import os
from pathlib import Path
import sys
import zipfile

from data_root import data_root
from map_style import COMPONENTS

ROOT = Path(__file__).resolve().parent.parent


def integer(name, minimum, maximum=None):
    value = int(os.environ[name])
    if value < minimum or (maximum is not None and value > maximum):
        raise ValueError(f"Invalid {name}: {value}")
    return value


def configuration():
    minimum = integer("BASEMAP_MINZOOM", 0, 14)
    maximum = integer("BASEMAP_MAXZOOM", 0, 14)
    if minimum > maximum:
        raise ValueError("BASEMAP_MINZOOM exceeds BASEMAP_MAXZOOM")

    for name in ("TERRAIN_DOWNLOAD_WORKERS", "TERRAIN_PROCESS_WORKERS",
                 "TERRAIN_TILE_THREADS", "CONTOUR_INTERVAL", "INDEX_INTERVAL"):
        integer(name, 1)

    for name in ("TERRAIN_DOWNLOAD_LIMIT", "TERRAIN_BATCH_LIMIT"):
        integer(name, 0)

    # The common setting must support both contour and hillshade tiling.
    integer("TERRAIN_TILE_MAXZOOM", 9, 14)
    simplification = float(os.environ["TERRAIN_TILE_SIMPLIFICATION"])
    if not math.isfinite(simplification) or simplification < 0:
        raise ValueError("TERRAIN_TILE_SIMPLIFICATION must be finite and nonnegative")

    bbox = os.environ["TERRAIN_BBOX"]
    if bbox:
        bounds = [int(value) for value in bbox.split(",")]
        if len(bounds) != 4 or bounds[0] >= bounds[2] or bounds[1] >= bounds[3]:
            raise ValueError("TERRAIN_BBOX must be west,south,east,north with increasing bounds")

    bands = os.environ["HILLSHADE_BANDS"].split()
    if not bands:
        raise ValueError("HILLSHADE_BANDS is empty")

    for band in bands:
        kind, level, low, high = band.split(":")
        if (kind not in ("shadow", "highlight") or not 0 <= int(level) <= 255
                or not 0 <= int(low) < int(high) <= 256):
            raise ValueError(f"Invalid hillshade band: {band}")

    for name in ("OSM_URL", "NOTO_SANS_URL"):
        if not os.environ[name].startswith(("https://", "http://")):
            raise ValueError(f"{name} must be an HTTP(S) URL")

    for name in ("PLANETILER_IMAGE", "PLANETILER_HEAP"):
        if not os.environ[name].strip():
            raise ValueError(f"{name} is empty")


def input_file(path):
    if not path.is_file() or path.stat().st_size == 0:
        raise ValueError(f"Missing or empty input: {path}")
    if path.suffix == ".zip" and not zipfile.is_zipfile(path):
        raise ValueError(f"Invalid source ZIP: {path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", action="append", type=Path, required=True)
    args = parser.parse_args()

    try:
        data = data_root()
        configuration()

        for path in args.input:
            input_file(path)

        style = json.loads((ROOT / "styles/default.json").read_text())
        if style.get("version") != 8 or not style.get("layers") or not style.get("sources"):
            raise ValueError("Expected a MapLibre version 8 source style with layers and sources")
        for name in COMPONENTS:
            if name not in style["sources"]:
                raise ValueError(f"Missing default style source: {name}")

        for layer in style["layers"]:
            for font in layer.get("layout", {}).get("text-font", []):
                input_file(data / "downloads/fonts" / f"{font}.ttf")

        sprites = list((ROOT / "sprites").glob("*.png"))
        if not sprites:
            raise ValueError("No source sprite PNGs found")
        for path in [*sprites, ROOT / "planetiler/Sunoh.java", ROOT / "planetiler/Dockerfile"]:
            input_file(path)

        cache = data / "downloads/dem"
        inventory = json.loads((cache / "inventory.json").read_text())
        if inventory.get("bucket") != "copernicus-dem-30m" or not inventory.get("objects"):
            raise ValueError("Invalid or empty Copernicus DEM inventory")

        # Metadata only: no raster processing, full-file hashes or network calls.
        for item in inventory["objects"]:
            path = cache / Path(item["key"]).name
            if not path.is_file() or path.stat().st_size != item["size"]:
                raise ValueError(f"Missing or size-mismatched DEM: {path}")

        print("Preflight passed: configuration and source inputs are available.")
        print("Checked presence, DEM sizes, ZIP structure and configuration syntax; not full input integrity.")
        return 0
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"Preflight error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
