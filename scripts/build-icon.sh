#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
iconset_dir="$repo_dir/.build/AppIcon.iconset"
mkdir -p "$iconset_dir"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$repo_dir/Resources/AppIcon.png" \
        --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
    sips -z "$((size * 2))" "$((size * 2))" "$repo_dir/Resources/AppIcon.png" \
        --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$iconset_dir" -o "$repo_dir/.build/AppIcon.icns"
