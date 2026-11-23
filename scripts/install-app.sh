#!/bin/zsh
# Builds a release app and installs it to ~/Applications for daily use, replacing any
# previous copy, then launches it. Open at Login points at this stable copy.
# Usage: scripts/install-app.sh
set -euo pipefail

root=${0:A:h:h}
cd "$root"

scripts/build-app.sh release
dest="$HOME/Applications"
mkdir -p "$dest"

# Quit whichever copy is running: debug build or previous install.
pkill -f "Headwaiter.app/Contents/MacOS/Headwaiter" 2>/dev/null || true
sleep 1

rm -rf "$dest/Headwaiter.app"
cp -R "build/Headwaiter.app" "$dest/"
open "$dest/Headwaiter.app"
echo "Installed and launched $dest/Headwaiter.app"
