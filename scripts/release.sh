#!/bin/zsh
# Builds a distributable Headwaiter: universal app, signed with Developer ID and the hardened
# runtime, packed in a DMG, notarized by Apple and stapled, so it opens without Gatekeeper
# warnings on any Mac.
#
# Usage: scripts/release.sh            full release (needs the setup below)
#        scripts/release.sh --dry-run  everything except Developer ID signing and notarization
#                                      (signs with the local dev cert instead)
#
# One-time setup, with your own Apple Developer account:
#   1. Xcode › Settings › Accounts › Manage Certificates › + › Developer ID Application
#   2. xcrun notarytool store-credentials headwaiter-notary --apple-id <you> --team-id <TEAMID>
# Override the certificate with DEVELOPER_ID="Developer ID Application: Name (TEAMID)".
set -euo pipefail

root=${0:A:h:h}
cd "$root"
dry_run=0
[[ "${1:-}" == "--dry-run" ]] && dry_run=1
profile="headwaiter-notary"

step() { print -P "\n%B==> $1%b" }
fail() { print -P "%F{red}✗ $1%f"; exit 1 }

# --- Identity -------------------------------------------------------------------------------
if (( dry_run )); then
    identity="WhatsRunning Dev"
    security find-certificate -c "$identity" >/dev/null 2>&1 || identity="-"
else
    identity=${DEVELOPER_ID:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}
    [[ -n "$identity" ]] || fail "No 'Developer ID Application' certificate in your keychain (see setup at the top of this script)."
    xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 \
        || fail "No notarization profile '$profile' (run: xcrun notarytool store-credentials $profile …)."
fi

# --- Build ----------------------------------------------------------------------------------
step "Building universal app"
UNIVERSAL=1 scripts/build-app.sh release
app="build/Headwaiter.app"
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$app/Contents/Info.plist")
print "Headwaiter $version ($build), $(lipo -archs "$app/Contents/MacOS/Headwaiter")"

# --- Sign: hardened runtime + secure timestamp (both required for notarization) -------------
step "Signing with: $identity"
timestamp=(--timestamp)
(( dry_run )) && timestamp=(--timestamp=none)   # a self-signed cert can't get Apple's timestamp
codesign --force --options runtime "${timestamp[@]}" --sign "$identity" "$app"
codesign --verify --strict --verbose=2 "$app" 2>&1 | tail -2
codesign -dv "$app" 2>&1 | grep -E "^(Authority|TeamIdentifier|Runtime|Timestamp)" || true

# --- DMG: the app plus an Applications shortcut to drag it onto -----------------------------
step "Creating DMG"
dmg="build/Headwaiter-$version.dmg"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
rm -f "$dmg"
hdiutil create -volname "Headwaiter $version" -srcfolder "$stage" -ov -format UDZO -quiet "$dmg"
codesign --force "${timestamp[@]}" --sign "$identity" "$dmg"
print "$dmg ($(du -h "$dmg" | cut -f1))"

if (( dry_run )); then
    print -P "\n%F{yellow}Dry run: skipped notarization. Gatekeeper would reject this build on other Macs.%f"
    exit 0
fi

# --- Notarize and staple --------------------------------------------------------------------
step "Notarizing (usually 1–5 minutes)"
xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait | tee build/notarize.log
grep -q "status: Accepted" build/notarize.log || {
    id=$(sed -n 's/^ *id: //p' build/notarize.log | head -1)
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$profile" build/notarize-errors.json
    fail "Notarization failed; details in build/notarize-errors.json"
}

step "Stapling the notarization ticket"
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"

step "Gatekeeper check"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
print -P "\n%F{green}✓ Ready to distribute: $dmg%f"
