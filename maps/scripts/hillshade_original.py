#!/usr/bin/env python3
"""The original Sunō GDAL hillshade recipe, without custom lighting or grid changes."""

import shutil
import subprocess


def tool(name):
    return name if shutil.which(name) else name + ".py"


def run(*args):
    subprocess.run([str(a) for a in args], check=True)


def merge(inputs, target):
    # Same source ordering, resolution and merge defaults as the original Makefile.
    run(tool("gdal_merge"), "-o", target, "-q", *inputs)
    return target


def geometry(raster, work, bands, clip=None):
    """Only optional core clipping is additional to the original derivation."""
    shade = work / "hillshade.tif"
    coarse = work / "hillshade_coarse.tif"
    smooth = work / "hillshade_smooth.tif"
    run("gdaldem", "hillshade", raster, shade, "-multidirectional", "-compute_edges", "-q")
    run("gdalwarp", "-tr", "0.003", "0.003", "-r", "average", shade, coarse, "-overwrite", "-q")
    run("gdalwarp", "-tr", "0.00028", "0.00028", "-r", "cubicspline", coarse, smooth, "-overwrite", "-q")
    result = work / "hillshade.geojsonl"
    with result.open("wb") as output:
        for band in bands.split():
            cls, level, lo, hi = band.split(":")
            if cls not in ("shadow", "highlight") or not 0 <= int(lo) < int(hi) <= 256:
                raise ValueError(f"Invalid band: {band}")
            level = int(level)
            mask = work / f"band_{cls}_{level}.tif"
            polygons = work / f"band_{cls}_{level}.gpkg"
            polygons.unlink(missing_ok=True)
            run(tool("gdal_calc"), "-A", smooth, f"--outfile={mask}",
                f"--calc=(A>={lo})*(A<{hi})", "--type=Byte", "--quiet", "--overwrite")
            run(tool("gdal_polygonize"), mask, "-q", "-f", "GPKG", polygons, "polygons")
            command = ["ogr2ogr", "-f", "GeoJSONSeq", "/vsistdout/", str(polygons),
                       "-t_srs", "EPSG:4326", "-simplify", "0.0003", "-sql",
                       f"SELECT '{cls}' AS class, {level} AS level, geom FROM polygons WHERE DN=1"]
            if clip:
                # Clip after simplification, never change the shading/smoothing to
                # repair seams. Without clipping this is the verbatim recipe.
                command += ["-clipdst", *map(str, clip)]
                if not float(clip[1]).is_integer() or not float(clip[3]).is_integer():
                    # A fractional polar cutoff must not round outside Mercator.
                    command += ["-lco", "COORDINATE_PRECISION=15"]
            subprocess.run(command, stdout=output, check=True)
    return result

