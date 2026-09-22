#!/usr/bin/env python3
"""Validate existing component archives and generated map resources."""

import argparse
import json
from pathlib import Path
import struct
import sys

from data_root import data_root

ARCHIVES = ("basemap", "ski", "contours", "hillshade")


def validate(data):
    tiles = data / "tiles"
    resources = data / "resources"
    style_path = resources / "style.json"
    style = json.loads(style_path.read_text())
    if style.get("version") != 8:
        raise ValueError("Expected a MapLibre version 8 style")
    files = []
    for name in ARCHIVES:
        path = tiles / f"{name}.pmtiles"
        with path.open("rb") as stream:
            header = stream.read(127)
        if len(header) != 127 or header[:8] != b"PMTiles\x03":
            raise ValueError(f"Invalid PMTiles v3 archive: {path}")
        if style["sources"][name]["url"] != f"pmtiles://{path.name}":
            raise ValueError(f"Unexpected source URL for {name}")
        files.append(path)

    for scale, suffix in ((1, ""), (2, "@2x")):
        png_path = resources / f"sprite{suffix}.png"
        json_path = resources / f"sprite{suffix}.json"
        with png_path.open("rb") as stream:
            header = stream.read(24)
        if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n":
            raise ValueError(f"Invalid sprite PNG: {png_path}")
        width, height = struct.unpack(">II", header[16:24])
        atlas = json.loads(json_path.read_text())
        if not atlas:
            raise ValueError(f"Empty sprite atlas: {json_path}")
        for name, entry in atlas.items():
            if (entry["pixelRatio"] != scale or entry["x"] < 0 or entry["y"] < 0
                    or entry["width"] <= 0 or entry["height"] <= 0
                    or entry["x"] + entry["width"] > width
                    or entry["y"] + entry["height"] > height):
                raise ValueError(f"Invalid sprite bounds: {json_path}: {name}")
        files.extend((png_path, json_path))

    fonts = set()
    for layer in style["layers"]:
        fonts.update(layer.get("layout", {}).get("text-font", []))
    if not fonts:
        raise ValueError("No font stacks found in style")
    for font in sorted(fonts):
        ttf = data / "downloads" / "fonts" / f"{font}.ttf"
        if not ttf.is_file() or ttf.stat().st_size == 0:
            raise ValueError(f"Missing or empty font: {ttf}")
        files.append(ttf)
    if style.get("sprite") != "sprite://sprite":
        raise ValueError("Unexpected sprite URL template")
    return style, files, fonts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-root", type=Path)
    args = parser.parse_args()
    try:
        data = data_root(args.data_root)
        _, files, _ = validate(data)
        print(f"Validated {len(files) + 1} map resource files")
        return 0
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"Resource error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
