#!/bin/bash
set -euo pipefail
# Also support running this script directly, without command-runner configuration.
gdal_python_tool() {
    if command -v "$1" >/dev/null 2>&1; then
        printf '%s' "$1"
    else
        printf '%s.py' "$1"
    fi
}

missing=0
for tool in uv snakemake just bash curl aws \
    "${GDAL_MERGE:-$(gdal_python_tool gdal_merge)}" gdal_contour \
    "${GDAL_CALC:-$(gdal_python_tool gdal_calc)}" \
    "${GDAL_POLYGONIZE:-$(gdal_python_tool gdal_polygonize)}" \
    gdaldem gdalwarp gdalbuildvrt ogr2ogr tippecanoe pmtiles magick jq python3 docker; do
    if command -v "$tool" >/dev/null 2>&1; then
        printf 'OK       %s\n' "$tool"
    else
        printf 'MISSING  %s\n' "$tool"
        missing=1
    fi
done
if command -v docker >/dev/null 2>&1 && ! docker info >/dev/null 2>&1; then
    echo 'MISSING  Docker daemon access (docker info failed)'
    missing=1
fi
if python3 -c 'from osgeo import gdal, ogr; import numpy' >/dev/null 2>&1; then
    echo 'OK       Python GDAL and NumPy (batched terrain)'
else
    echo 'MISSING  Python GDAL/NumPy bindings (batched terrain)'
    missing=1
fi
if [ "$missing" -ne 0 ]; then
    echo 'Install the missing tools using the setup instructions in README.md.' >&2
    exit 1
fi
