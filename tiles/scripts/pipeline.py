#!/usr/bin/env python3
"""Just command entry point; Snakemake owns all generation dependencies."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

from configuration import ROOT, load
import preflight
from workflow_tasks import NATURAL_EARTH

BUILD_TARGETS = {
    "build": "build", "maps": "maps", "osm": "osm", "overview": "overview",
    "coastlines": "coastlines", "resources": "resources", "sprites": "sprites",
    "fonts": "fonts", "terrain": "terrain_geometry", "terrain-contours": "terrain_geometry",
    "terrain-hillshade": "terrain_geometry", "terrain-tiles": "terrain_tiles",
    "planetiler-image": "planetiler_image", "terrain-inventory": "dem_inventory",
    "package": "package",
}
SOURCES = {"all", "dem", "osm", "natural-earth", "coastlines", "fonts"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["build", "download", "check", "clean"])
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    arguments = args.arguments
    target, archive = "build", ""
    if args.action in ("build", "download"):
        if arguments and "=" not in arguments[0] and not arguments[0].startswith("--"):
            target, *arguments = arguments
        elif args.action == "download":
            parser.error("Specify a download source: all, dem, osm, natural-earth, coastlines or fonts")
        if args.action == "build" and target not in BUILD_TARGETS:
            parser.error(f"Unknown build target: {target}")
        if args.action == "download" and target not in SOURCES:
            parser.error(f"Unknown download source: {target}")
    overrides, dry_run, include_downloads, include_package = [], False, False, False
    while arguments:
        argument, *arguments = arguments
        if argument == "--dry-run" and args.action in ("build", "download"):
            dry_run = True
        elif argument == "--include-downloads" and args.action == "clean":
            include_downloads = True
        elif argument == "--include-package" and args.action == "clean":
            include_package = True
        elif argument == "--archive" and args.action == "build" and target == "package" and arguments:
            archive, *arguments = arguments
            archive = str(Path(archive).expanduser().resolve())
        elif "=" in argument:
            overrides.append(argument)
        else:
            parser.error(f"Unexpected argument: {argument}")

    config = load(overrides)
    data = Path(config["DATA_ROOT"])
    if args.action == "clean":
        paths = ["scratch", "geometry/overview", "geometry/coastlines", "tiles", "resources"]
        if include_package:
            paths += ["package", "package.part"]
        if include_downloads:
            paths += [f"downloads/{name}" for name in ("osm", "natural-earth", "coastlines", "fonts")]
        for name in paths:
            path = data / name
            if path.is_symlink():
                path.unlink()
            elif path.exists():
                shutil.rmtree(path)
        return

    preflight.configuration()
    for key in ("CORES", "MEM_MB"):
        if int(config[key]) < 1:
            raise ValueError(f"{key} must be positive")
    if args.action == "check":
        inputs = [config["OSM_PBF"], *config["FONT_TTFS"],
                  str(data / "downloads/coastlines/water-polygons-split-4326.zip")]
        inputs += [str(data / "downloads/natural-earth" / f"{name}.zip") for name, _ in NATURAL_EARTH.values()]
        command = [sys.executable, str(ROOT / "scripts/preflight.py")]
        for path in inputs:
            command += ["--input", path]
        subprocess.run(command, check=True)
        return

    if target == "package":
        destination = data / "package"
        if destination.exists() or destination.with_name("package.part").exists():
            raise ValueError(f"Package or incomplete preparation already exists: {destination}")
    config.update(TARGET=target, ARCHIVE=archive)
    scratch = data / "scratch/snakemake"
    configs = scratch / "configs"
    configs.mkdir(parents=True, exist_ok=True)
    text = json.dumps(config, sort_keys=True, indent=2) + "\n"
    snapshot = configs / (hashlib.sha256(text.encode()).hexdigest() + ".json")
    if not snapshot.exists():
        snapshot.write_text(text)
    temporary = scratch / "tmp"
    temporary.mkdir(exist_ok=True)
    os.environ["TMPDIR"] = str(temporary)
    os.environ["XDG_CACHE_HOME"] = str(scratch / "cache")
    selected = BUILD_TARGETS[target] if args.action == "build" else "download_" + target.replace("-", "_")
    command = [
        sys.executable, "-m", "snakemake", selected,
        "--snakefile", str(ROOT / "workflow/Snakefile"),
        "--directory", str(scratch), "--configfile", str(snapshot),
        "--cores", str(config["CORES"]),
        "--resources", f"mem_mb={config['MEM_MB']}",
        f"terrain_jobs={config['TERRAIN_PROCESS_WORKERS']}",
        f"downloads={config['TERRAIN_DOWNLOAD_WORKERS']}", "--printshellcmds",
    ]
    if dry_run:
        command.append("--dry-run")
    os.execv(sys.executable, command)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
