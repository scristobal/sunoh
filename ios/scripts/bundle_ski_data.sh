#!/bin/sh
set -eu

destination="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/SkiData"
for package in lifts ski_areas; do
    if [ ! -f "$SUNOH_SKI_DATA_DIRECTORY/$package.gpkg" ]; then
        echo "error: Missing $package.gpkg in SUNOH_SKI_DATA_DIRECTORY. Build the packages with scripts/ski_data.py and set SUNOH_SKI_DATA_DIRECTORY in Configuration/SkiData.local.xcconfig."
        exit 1
    fi
done
mkdir -p "$destination"
rm -f "$destination/runs.gpkg" "$destination/spots.gpkg"
for package in lifts ski_areas; do
    cp "$SUNOH_SKI_DATA_DIRECTORY/$package.gpkg" "$destination/$package.gpkg"
done
