#!/usr/bin/env python3
"""Assemble the immutable map package from completed pipeline outputs."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

from data_root import data_root
from map_style import COMPONENTS, hosted_style

ROOT = Path(__file__).resolve().parent.parent


def archive_range(path):
    if not path.is_file() or path.name.endswith(".part.pmtiles"):
        raise SystemExit(f"Not a completed input archive: {path}")
    with path.open("rb") as stream:
        header = stream.read(127)
    if len(header) != 127 or header[:8] != b"PMTiles\x03" or header[99] != 1:
        raise SystemExit(f"Expected vector PMTiles v3: {path}")
    return {"minzoom": header[100], "maxzoom": header[101]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-root", type=Path)
    parser.add_argument("--archive", type=Path, action="append",
                        help="Override merge inputs (for example an already-joined copy of the same six components); default: the six named archives in DATA_ROOT/tiles/")
    args = parser.parse_args()
    data = data_root(args.data_root)
    dest = data / "package"
    if dest.exists():
        raise SystemExit(f"Package already exists: {dest}. Remove it explicitly before rebuilding.")
    components = {name: data / "tiles" / f"{name}.pmtiles" for name in COMPONENTS}
    ranges = {name: archive_range(path) for name, path in components.items()}
    archives = [p.resolve() for p in args.archive] if args.archive else list(components.values())
    for path in archives:
        archive_range(path)
    style = hosted_style(ranges)
    asset_files = [(data / "resources" / ("sprite" + suffix), "sprite" + suffix)
                   for suffix in (".png", ".json", "@2x.png", "@2x.json")]
    asset_files += [(data / "downloads/fonts" / f"{font}.ttf", f"{font}.ttf")
                    for font in style["font-faces"]]
    for path, _ in asset_files:
        if not path.is_file() or not path.stat().st_size:
            raise SystemExit(f"Missing or empty package asset: {path}; build resources first")
    work = dest.with_name(dest.name + ".part")
    if work.exists():
        raise SystemExit(f"Incomplete preparation at {work}; remove it explicitly before retrying")
    print(f"Preparing package: {len(archives)} archives, "
          f"{sum(p.stat().st_size for p in archives)/1e9:.2f} GB; destination {dest}", flush=True)
    print("Source zoom ranges: " + ", ".join(f"{name} {r['minzoom']}–{r['maxzoom']}" for name, r in ranges.items()), flush=True)
    work.mkdir(parents=True)
    archive = work / "map.pmtiles"
    if len(archives) == 1:
        shutil.copyfile(archives[0], archive)
    else:
        scratch = data / "scratch"
        scratch.mkdir(parents=True, exist_ok=True)
        subprocess.run(["tile-join", "--no-tile-size-limit", "-o", str(archive), *map(str, archives)], check=True,
                       env=dict(os.environ, TMPDIR=str(scratch), SQLITE_TMPDIR=str(scratch)))
    subprocess.run(["python3", str(ROOT / "scripts/fix-pmtiles-center.py"), str(archive)], check=True)
    subprocess.run(["pmtiles", "verify", str(archive)], check=True)
    assets = work / "assets"
    assets.mkdir()
    for path, name in asset_files:
        shutil.copyfile(path, assets / name)
    (work / "style.json").write_text(json.dumps(style, ensure_ascii=False, indent=2) + "\n")
    print("Hashing the merged archive and package assets...", flush=True)
    files = {}
    for path in sorted(p for p in work.rglob("*") if p.is_file()):
        with path.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        files[str(path.relative_to(work))] = {"bytes": path.stat().st_size, "sha256": digest}
    (work / "manifest.json").write_text(json.dumps({
        "inputs": [str(p) for p in archives],
        "components": {name: {"path": str(path), **ranges[name]} for name, path in components.items()},
        "files": files,
    }, indent=2) + "\n")
    work.rename(dest)
    print(f"Prepared {dest}")


if __name__ == "__main__":
    main()
