#!/usr/bin/env python3
"""Correct an out-of-range PMTiles v3 center zoom without rewriting tile data."""

import argparse
from pathlib import Path


def fix_center(path):
    with path.open("r+b") as archive:
        header = archive.read(127)
        if len(header) != 127 or header[:8] != b"PMTiles\x03":
            raise ValueError(f"{path}: expected a PMTiles v3 header")
        minzoom, maxzoom, centerzoom = header[100], header[101], header[118]
        if not 0 <= minzoom <= maxzoom <= 26:
            raise ValueError(f"{path}: invalid zoom range {minzoom}–{maxzoom}")
        if not minzoom <= centerzoom <= maxzoom:
            corrected = max(minzoom, min(11, maxzoom))
            archive.seek(118)
            archive.write(bytes([corrected]))
            print(f"{path}: center zoom {centerzoom} -> {corrected}")
        else:
            print(f"{path}: center zoom {centerzoom} already valid")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    fix_center(parser.parse_args().archive)
