#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
data_root=$(python3 scripts/data_root.py)
mkdir -p "$data_root/resources" "$data_root/scratch"
work=$(mktemp -d "$data_root/scratch/sprites.XXXXXX")
trap 'rm -rf "$work"' EXIT
for scale in 1 2; do
    suffix=""
    if [ "$scale" -eq 2 ]; then suffix="@2x"; fi
    json="{}"; x=0; max_h=0
    composite=()
    for file in sprites/*.png; do
        name=$(basename "$file" .png)
        sw=$(magick identify -format '%w' "$file")
        sh=$(magick identify -format '%h' "$file")
        w=$((sw * scale)); h=$((sh * scale))
        scaled="$work/${name}${suffix}.png"
        if [ "$scale" -eq 1 ]; then
            cp "$file" "$scaled"
        else
            magick "$file" -resize "${w}x${h}" "$scaled"
        fi
        json=$(printf '%s' "$json" | jq \
            --arg n "$name" --argjson x "$x" --argjson y 0 \
            --argjson w "$w" --argjson h "$h" --argjson pr "$scale" \
            '. + {($n): {x: $x, y: $y, width: $w, height: $h, pixelRatio: $pr}}')
        composite+=("$scaled" -geometry "+${x}+0" -composite)
        x=$((x + w))
        if [ "$h" -gt "$max_h" ]; then max_h=$h; fi
    done
    magick -size "${x}x${max_h}" xc:transparent "${composite[@]}" \
        "$work/sprite${suffix}.png"
    printf '%s\n' "$json" > "$work/sprite${suffix}.json"
done
for file in "$work"/sprite*; do
    mv "$file" "$data_root/resources/$(basename "$file")"
done
echo 'Generated sprite atlases at 1x and 2x'
