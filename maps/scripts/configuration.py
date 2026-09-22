"""Shared pipeline configuration for Just commands and Snakemake."""

import os
from pathlib import Path
import shlex
import tomllib

from data_root import data_root

ROOT = Path(__file__).resolve().parent.parent


def load(overrides=()):
    config = tomllib.loads((ROOT / "config.toml").read_text())
    local = ROOT / "config.local.toml"
    if local.exists():
        config.update(tomllib.loads(local.read_text()))
    elif (ROOT / "config.local.mk").exists():
        raise ValueError("Migrate config.local.mk to config.local.toml before continuing")

    allowed = set(config) | {"OSM_PBF", "FONT_TTFS", "PLANETILER_TMP_DIR"}
    for argument in overrides:
        key, separator, value = argument.partition("=")
        if not separator or key not in allowed:
            raise ValueError(f"Unknown configuration override: {argument}")
        if isinstance(config.get(key), (int, float)):
            value = type(config[key])(value)
        elif key == "FONT_TTFS":
            value = shlex.split(value)
        config[key] = value

    selected = Path(config["DATA_ROOT"]).expanduser()
    config["DATA_ROOT"] = str(data_root(selected if selected.is_absolute() else ROOT / selected))
    data = Path(config["DATA_ROOT"])
    config.setdefault("OSM_PBF", str(data / "downloads/osm/planet.osm.pbf"))
    config.setdefault("FONT_TTFS", [str(data / "downloads/fonts" / f"NotoSans-{weight}.ttf")
                                    for weight in ("Regular", "Medium", "Bold", "Italic")])
    config.setdefault("PLANETILER_TMP_DIR", str(data / "scratch/planetiler"))
    for key in ("OSM_PBF", "PLANETILER_TMP_DIR"):
        config[key] = str(Path(config[key]).expanduser().resolve())
    if isinstance(config["FONT_TTFS"], str):
        config["FONT_TTFS"] = shlex.split(config["FONT_TTFS"])
    config["FONT_TTFS"] = [str(Path(path).expanduser().resolve()) for path in config["FONT_TTFS"]]
    for key, value in config.items():
        os.environ[key] = shlex.join(value) if isinstance(value, list) else str(value)
    return config
