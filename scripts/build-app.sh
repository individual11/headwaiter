#!/bin/zsh
# Builds the menu bar app and wraps it in a .app bundle (no Xcode project needed).
# Usage: scripts/build-app.sh [debug|release]   → build/Headwaiter.app
#        UNIVERSAL=1 scripts/build-app.sh release  → Apple silicon + Intel (for distribution)
set -euo pipefail

config=${1:-release}
root=${0:A:h:h}
cd "$root"

arch_flags=()
[[ "${UNIVERSAL:-0}" == 1 ]] && arch_flags=(--arch arm64 --arch x86_64)
swift build -c "$config" "${arch_flags[@]}" --product Headwaiter
bin=$(swift build -c "$config" "${arch_flags[@]}" --show-bin-path)/Headwaiter

app="build/Headwaiter.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Headwaiter"
# App icon (Dock while Settings is open, ⌘-Tab, Finder, About). Regenerate with scripts/make-icon.sh.
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>               <string>Headwaiter</string>
    <key>CFBundleDisplayName</key>        <string>Headwaiter</string>
    <key>CFBundleIdentifier</key>         <string>com.individual-11.headwaiter</string>
    <key>CFBundleExecutable</key>         <string>Headwaiter</string>
    <key>CFBundleIconFile</key>           <string>AppIcon</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>0.3</string>
    <key>CFBundleVersion</key>            <string>3</string>
    <key>LSMinimumSystemVersion</key>     <string>15.0</string>
    <!-- Menu bar only: no Dock icon, no app menu. -->
    <key>LSUIElement</key>                <true/>
    <key>NSHighResolutionCapable</key>    <true/>
</dict>
</plist>
PLIST

# Sign with the local dev certificate when present (scripts/make-dev-cert.sh), so privacy
# grants survive rebuilds. Ad-hoc otherwise: macOS then sees every build as a new app.
# Developer ID comes at release.
# Keychain label kept from the working name; users never see it.
identity="WhatsRunning Dev"
if security find-certificate -c "$identity" >/dev/null 2>&1; then
    codesign --force --sign "$identity" "$app" >/dev/null
    echo "Built $root/$app (signed: $identity)"
else
    codesign --force --sign - "$app" >/dev/null
    echo "Built $root/$app (ad-hoc signed; run scripts/make-dev-cert.sh to stop repeat permission prompts)"
fi
