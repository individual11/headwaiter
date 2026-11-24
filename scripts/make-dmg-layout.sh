#!/bin/zsh
# Draws the DMG window's background and records its Finder layout (window size, icon positions)
# in Resources/dmg, which release.sh copies into every DMG. Re-run after changing
# scripts/dmg-background.swift, and commit the result.
#
# Finder writes the layout, so macOS asks once to let your terminal control Finder, and a
# window opens for a moment. Finder has to be showing hidden files (⇧⌘. turns that on and off),
# or their positions aren't recorded.
#
# Usage: scripts/make-dmg-layout.sh            background and layout
#        scripts/make-dmg-layout.sh --picture  background only
set -euo pipefail

root=${0:A:h:h}
cd "$root"
out="Resources/dmg"
volume="Headwaiter"   # recorded in the layout: release.sh must use the same name
work=/private/tmp/headwaiter-dmg   # Finder records this path in the layout, so keep it neutral
rm -rf "$work"; mkdir -m 700 "$work"
device=""
cleanup() {
    [[ -n "$device" ]] && hdiutil detach "$device" -quiet -force || true
    rm -rf "$work"
}
trap cleanup EXIT

# --- Background: one file with the 1x and 2x pictures ---------------------------------------
swiftc -swift-version 5 -o "$work/draw" scripts/dmg-background.swift
"$work/draw" design/logo/app-icon.png "$work"
tiffutil -cathidpicheck "$work/background.png" "$work/background@2x.png" -out "$work/background.tiff" >/dev/null 2>&1
mkdir -p "$out"
tiffutil -lzw "$work/background.tiff" -out "$out/background.tiff" >/dev/null 2>&1
cp "$work/mockup.png" design/current/dmg-window.png
echo "Wrote $out/background.tiff"
[[ "${1:-}" == "--picture" ]] && exit 0

# --- Layout ---------------------------------------------------------------------------------
[[ ! -e "/Volumes/$volume" ]] || { echo "Eject the $volume disk first."; exit 1; }
mkdir -p "$work/stage/.background" "$work/stage/Headwaiter.app"   # only the names matter here
cp "$out/background.tiff" "$work/stage/.background/"
cp Resources/AppIcon.icns "$work/stage/.VolumeIcon.icns"
ln -s /Applications "$work/stage/Applications"
hdiutil create -volname "$volume" -srcfolder "$work/stage" -fs HFS+ -format UDRW -size 20m -quiet "$work/layout.dmg"
device=$(hdiutil attach -readwrite -noverify -noautoopen "$work/layout.dmg" | awk '/^\/dev\// { print $1; exit }')

osascript <<APPLESCRIPT
with timeout of 60 seconds
    tell application "Finder"
        tell disk "$volume"
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set pathbar visible of container window to false
            -- 440 points of content plus the title bar
            set bounds of container window to {200, 160, 900, 628}
            set options to icon view options of container window
            set arrangement of options to not arranged
            set icon size of options to 128
            set text size of options to 13
            set background picture of options to file ".background:background.tiff"
            set position of item "Headwaiter.app" of container window to {170, 160}
            set position of item "Applications" of container window to {530, 160}
            -- Finder can be set to show hidden files. Park them below the window, where they
            -- don't cover anything or push the icons down.
            repeat with parked in {{".background", 170}, {".VolumeIcon.icns", 350}, {".fseventsd", 530}}
                try
                    set position of item (item 1 of parked) of container window to {item 2 of parked, 640}
                end try
            end repeat
            update without registering applications
            delay 2
            close
        end tell
    end tell
end timeout
APPLESCRIPT
sync
for i in {1..20}; do [[ -s "/Volumes/$volume/.DS_Store" ]] && break; sleep 0.5; done
[[ -s "/Volumes/$volume/.DS_Store" ]] || { echo "Finder didn't save a layout."; exit 1; }
sleep 1
cp "/Volumes/$volume/.DS_Store" "$out/DS_Store"
# Finder also records the ID of the disk the image was on. Blank it: it identifies this Mac.
disk=$(diskutil info "$(df "$work" | awk 'END { print $1 }')" | sed -n 's/.*Volume UUID: *//p')
[[ -n "$disk" ]] && LC_ALL=C sed -i '' "s/$disk/00000000-0000-0000-0000-000000000000/g" "$out/DS_Store"
if ! LC_ALL=C grep -aqF ".VolumeIcon.icns" <(tr -d '\000' < "$out/DS_Store"); then
    echo "Hidden files weren't placed. Show them in Finder (⇧⌘.) and run this again."; exit 1
fi
if LC_ALL=C grep -aqE "$disk|/Users/|var/folders" "$out/DS_Store"; then
    rm "$out/DS_Store"; echo "The layout still names this Mac; not keeping it."; exit 1
fi
echo "Wrote $out/DS_Store"
