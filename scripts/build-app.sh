#!/bin/zsh
# Builds the menu bar app and wraps it in a .app bundle (no Xcode project needed).
# Usage: scripts/build-app.sh [debug|release]   → build/Headwaiter.app
#        UNIVERSAL=1 scripts/build-app.sh release  → Apple silicon + Intel (for distribution)
#        UPDATES=1 …               turn on automatic updates (release.sh does this). Off by
#                                  default, so a build of your own isn't replaced by the published one.
#        VERSION=0.3 BUILD=3 …     override the version, to test updating from an older one
set -euo pipefail

config=${1:-release}
version=${VERSION:-0.5}
build=${BUILD:-5}   # must go up with every release: Sparkle compares it
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

# Sparkle, without the XPC services only sandboxed apps need.
sparkle=".build/artifacts/sparkle/Sparkle"
framework="$app/Contents/Frameworks/Sparkle.framework"
mkdir -p "$app/Contents/Frameworks"
ditto "$sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$framework"
rm -rf "$framework/XPCServices" "$framework/Versions/B/XPCServices" \
       "$framework/Headers" "$framework/Versions/B/Headers" \
       "$framework/PrivateHeaders" "$framework/Versions/B/PrivateHeaders" \
       "$framework/Modules" "$framework/Versions/B/Modules"
cp "$sparkle/LICENSE" "$app/Contents/Resources/Sparkle-LICENSE.txt"
exe="$app/Contents/MacOS/Headwaiter"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$exe" 2>/dev/null
# Drop the build machine's own search paths (toolchain, build folder).
for arch in $(lipo -archs "$exe"); do otool -arch "$arch" -l "$exe"; done \
    | sed -n 's/^ *path \(.*\) (offset [0-9]*)$/\1/p' | sort -u | while read -r rpath; do
    [[ "$rpath" == /usr/lib/swift || "$rpath" == @* ]] || install_name_tool -delete_rpath "$rpath" "$exe" 2>/dev/null
done
# Debug entries name every source file by its full path, home folder included.
if [[ "$config" == release ]]; then strip -S "$exe" 2>/dev/null; fi

# The feed and every update must be signed with the private half of this key.
updates=""
if [[ "${UPDATES:-0}" == 1 ]]; then
    key_file="Resources/sparkle-public-key.txt"
    [[ -s "$key_file" ]] || { echo "Missing $key_file (see docs/RELEASING.md)"; exit 1 }
    updates="
    <key>SUFeedURL</key>                  <string>https://github.com/individual11/headwaiter/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key>              <string>$(tr -d '[:space:]' < "$key_file")</string>
    <key>SUVerifyUpdateBeforeExtraction</key> <true/>
    <key>SURequireSignedFeed</key>        <true/>
    <key>SUAllowsAutomaticUpdates</key>   <false/>"
fi

cat > "$app/Contents/Info.plist" <<PLIST
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
    <key>CFBundleShortVersionString</key> <string>$version</string>
    <key>CFBundleVersion</key>            <string>$build</string>
    <key>LSMinimumSystemVersion</key>     <string>15.0</string>
    <!-- Menu bar only: no Dock icon, no app menu. -->
    <key>LSUIElement</key>                <true/>
    <key>NSHighResolutionCapable</key>    <true/>$updates
</dict>
</plist>
PLIST

# Sign with the local dev certificate when present (scripts/make-dev-cert.sh), so privacy
# grants survive rebuilds. Ad-hoc otherwise: macOS then sees every build as a new app.
# Developer ID comes at release.
# Keychain label kept from the working name; users never see it.
identity="WhatsRunning Dev"
sign_all() {   # inside out; Sparkle's helper tools first
    codesign --force --sign "$1" "$framework/Versions/B/Autoupdate" "$framework/Versions/B/Updater.app" "$framework" "$app"
}
if security find-certificate -c "$identity" >/dev/null 2>&1; then
    sign_all "$identity" >/dev/null
    echo "Built $root/$app (signed: $identity)"
else
    sign_all - >/dev/null
    echo "Built $root/$app (ad-hoc signed; run scripts/make-dev-cert.sh to stop repeat permission prompts)"
fi
