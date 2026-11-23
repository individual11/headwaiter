#!/bin/zsh
# Renders the app icon (bow tie, accent blue) from the vector artwork in LogoArt.swift at
# every size macOS uses and packs it into Resources/AppIcon.icns, which build-app.sh bundles.
# Re-run after changing the artwork.
set -euo pipefail

root=${0:A:h:h}
cd "$root"
swift build --product Headwaiter >/dev/null
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

HW_ICONSET="$work/AppIcon.iconset" "$(swift build --show-bin-path)/Headwaiter"
mkdir -p Resources
iconutil -c icns "$work/AppIcon.iconset" -o Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns"
