#!/bin/zsh
set -euo pipefail

cd "${0:A:h:h}"
mkdir -p Resources/AppIcon.iconset
icon_sdk="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk}"
swift -sdk "$icon_sdk" -module-cache-path /private/tmp/local-dictation-icon-module-cache \
    scripts/draw-icon.swift Resources/AppIcon-1024.png

for pixels in 16 32 128 256 512; do
    sips -s format png -z "$pixels" "$pixels" Resources/AppIcon-1024.png \
        --out "Resources/AppIcon.iconset/icon_${pixels}x${pixels}.png" >/dev/null
    double=$((pixels * 2))
    sips -s format png -z "$double" "$double" Resources/AppIcon-1024.png \
        --out "Resources/AppIcon.iconset/icon_${pixels}x${pixels}@2x.png" >/dev/null
done
iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
