#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
MAESTRO_BIN_DIR="$(swift build -c release --show-bin-path)"
MAESTRO_APP="$PWD/dist/Codex Maestro.app"
mkdir -p "$MAESTRO_APP/Contents/MacOS" "$MAESTRO_APP/Contents/Resources" .build/AppIcon.iconset
cp "$MAESTRO_BIN_DIR/CodexMaestro" "$MAESTRO_APP/Contents/MacOS/CodexMaestro"
cp Resources/Info.plist "$MAESTRO_APP/Contents/Info.plist"
swift scripts/make-icon.swift .build/AppIcon.png
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" .build/AppIcon.png --out ".build/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" .build/AppIcon.png --out ".build/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns .build/AppIcon.iconset -o "$MAESTRO_APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$MAESTRO_APP"
codesign --verify --strict "$MAESTRO_APP"
echo "$MAESTRO_APP"
