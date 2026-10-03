#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
MAESTRO_ICONSET="Resources/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$MAESTRO_ICONSET" .build
swift scripts/make-icon.swift .build/AppIcon.png
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" .build/AppIcon.png --out "$MAESTRO_ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" .build/AppIcon.png --out "$MAESTRO_ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
