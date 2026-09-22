"""Stream a scheduled terrain input manifest into a verified PMTiles archive."""

import gzip
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

from data_root import data_root
import terrain_processing as terrain

SCRIPT = Path(__file__).resolve()


def tile(args):
    config = terrain.read(args.manifest)
    root = data_root(config["data_root"])
    output = Path(config["output"])
    output.parent.mkdir(parents=True, exist_ok=True)
    scratch_root = root / "scratch/terrain-tiles"
    scratch_root.mkdir(parents=True, exist_ok=True)
    terrain.headroom(output.parent, scratch_root)
    part = output.with_name(output.stem + ".part.pmtiles")
    with tempfile.TemporaryDirectory(prefix=config["kind"] + "-", dir=scratch_root) as scratch:
        command = ["tippecanoe", "--force", "-o", str(part), "--name=" + config["kind"],
                   "--layer=" + config["kind"], "--minimum-zoom=" + str(config["minzoom"]),
                   "--maximum-zoom=" + str(config["maxzoom"]),
                   "--simplification=" + str(config["simplification"]),
                   "--no-tile-size-limit", "--no-feature-limit", "--temporary-directory=" + scratch,
                   "--attribution=Copernicus DEM GLO-30 (public AWS mirror); derived by Sunō"]
        env = dict(os.environ, TIPPECANOE_MAX_THREADS=str(config["threads"]))
        print(shlex.join(command), flush=True)
        process = subprocess.Popen(command, stdin=subprocess.PIPE, env=env)
        total = 0
        try:
            for index, record in enumerate(config["inputs"], 1):
                path = Path(record["path"])
                current = path.stat()
                if current.st_size != record["size"] or current.st_mtime_ns != record["mtime_ns"]:
                    raise RuntimeError(f"Input changed after planning: {path}")
                with gzip.open(path, "rb") as src:
                    while block := src.read(1024 * 1024):
                        process.stdin.write(block)
                        total += len(block)
                process.stdin.write(b"\n")
                if index % 500 == 0 or index == len(config["inputs"]):
                    print(f"Streamed {index}/{len(config['inputs'])} batches, {total/1e9:.1f} GB decoded", flush=True)
            process.stdin.close()
            code = process.wait()
            if code:
                raise RuntimeError(f"Tippecanoe exited with status {code}; existing archive was not replaced")
            if not total:
                raise RuntimeError("Selected geometry is entirely empty; existing archive was not replaced")
        except BaseException:
            if process.poll() is None:
                process.terminate()
            process.wait()
            raise
    subprocess.run(["python3", str(SCRIPT.with_name("fix-pmtiles-center.py")), str(part)], check=True)
    subprocess.run(["pmtiles", "verify", str(part)], check=True)
    part.replace(output)
    terrain.save(output.with_suffix(".build.json"), {key: value for key, value in config.items() if key != "inputs"} |
                 {"batch_count": len(config["inputs"]), "gzip_bytes": sum(i["size"] for i in config["inputs"])})
    print(f"Published {output} ({output.stat().st_size/1e9:.2f} GB)", flush=True)
