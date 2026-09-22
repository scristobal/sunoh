"""Adapt the canonical default style to the hosted package."""

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
COMPONENTS = ("basemap", "ski", "contours", "hillshade", "overview", "coastlines")


def hosted_style(ranges):
    style = json.loads((ROOT / "styles/default.json").read_text())
    # One physical archive, with source views capped at the original maximum
    # zooms. Explicit tiles URLs avoid TileJSON replacing those individual caps.
    tiles = "{origin}/package/{z}/{x}/{y}.mvt"
    sources, groups, source_names = {}, {}, {}
    for name in COMPONENTS:
        limits = ranges[name]
        cap = limits["maxzoom"]
        if cap not in groups:
            key = "sunoh" if name == "basemap" else name
            groups[cap] = key
            sources[key] = {"type": "vector", "tiles": [tiles],
                            "minzoom": limits["minzoom"], "maxzoom": cap}
        key = groups[cap]
        source_names[name] = key
        sources[key]["minzoom"] = min(sources[key]["minzoom"], limits["minzoom"])
        attribution = style["sources"][name].get("attribution")
        if name in ("contours", "hillshade"):
            attribution = "Copernicus DEM"
        if attribution:
            existing = sources[key].get("attribution", "")
            if attribution not in existing:
                sources[key]["attribution"] = existing + ("; " if existing else "") + attribution
    for layer in style["layers"]:
        if "source" in layer:
            layer["source"] = source_names[layer["source"]]
    style["sources"] = sources
    base = "{origin}/package/assets"
    style["sprite"] = base + "/sprite"
    fonts = sorted({font for layer in style["layers"] for font in layer.get("layout", {}).get("text-font", [])})
    style["font-faces"] = {font: f"{base}/{font}.ttf" for font in fonts}
    return style
