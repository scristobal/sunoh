#!/bin/sh
set -eu

destination="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/SkiData"
for package in lifts ski_areas; do
    if [ ! -f "$SUNOH_SKI_DATA_DIRECTORY/$package.gpkg" ]; then
        echo "error: Missing $package.gpkg in SUNOH_SKI_DATA_DIRECTORY. Build the packages with scripts/ski_data.py and set SUNOH_SKI_DATA_DIRECTORY in Configuration/SkiData.local.xcconfig."
        exit 1
    fi
done
if [ ! -f "$SUNOH_SKI_DATA_DIRECTORY/offline-regions.geojson" ]; then
    echo "error: Missing offline-regions.geojson. Run just offline-catalog with the published OpenSkiData GeoPackage and an output path in SUNOH_SKI_DATA_DIRECTORY."
    exit 1
fi
mkdir -p "$destination"
rm -f "$destination/runs.gpkg" "$destination/spots.gpkg"
for package in lifts ski_areas; do
    cp "$SUNOH_SKI_DATA_DIRECTORY/$package.gpkg" "$destination/$package.gpkg"
done
cp "$SUNOH_SKI_DATA_DIRECTORY/offline-regions.geojson" "$destination/offline-regions.geojson"
rm -f "$destination/offline-map-sizes.json" "$destination/offline-cell-sizes.json"
