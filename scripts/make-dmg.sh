#!/bin/zsh
# Packs the app in a DMG: an Applications shortcut to drag it onto, the window layout and
# background from Resources/dmg (see make-dmg-layout.sh) and the app's icon for the disk.
#
# Usage: scripts/make-dmg.sh <Headwaiter.app> <output.dmg>
set -euo pipefail

[[ $# -eq 2 && -d "$1" ]] || { echo "usage: make-dmg.sh <Headwaiter.app> <output.dmg>"; exit 1; }
app=${1:A}
dmg=${2:A}
cd "${0:A:h:h}"

work=$(mktemp -d)
mounted=0
cleanup() {
    (( mounted )) && hdiutil detach "$work/mount" -quiet -force || true
    rm -rf "$work"
}
trap cleanup EXIT

stage="$work/stage"
mkdir -m 755 "$stage" "$work/mount"
cp -R "$app" "$stage/Headwaiter.app"   # the layout places icons by name
ln -s /Applications "$stage/Applications"
mkdir "$stage/.background"
cp Resources/dmg/background.tiff "$stage/.background/"
cp Resources/dmg/DS_Store "$stage/.DS_Store"
cp Resources/AppIcon.icns "$stage/.VolumeIcon.icns"

# The layout refers to the background on a disk with this name.
hdiutil create -volname "Headwaiter" -srcfolder "$stage" -fs HFS+ -format UDRW -quiet "$work/rw.dmg"
# Finder's "has a custom icon" flag can only be set on the mounted disk.
hdiutil attach -readwrite -noverify -nobrowse -noautoopen -mountpoint "$work/mount" -quiet "$work/rw.dmg"
mounted=1
xattr -wx com.apple.FinderInfo \
    "0000000000000000040000000000000000000000000000000000000000000000" "$work/mount"
rm -rf "$work/mount/.fseventsd"
hdiutil detach "$work/mount" -quiet
mounted=0

rm -f "$dmg"
# LZMA: smaller, and readable since macOS 10.15.
hdiutil convert "$work/rw.dmg" -format ULMO -quiet -o "$dmg"
