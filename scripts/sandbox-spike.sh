#!/bin/zsh
# Runs sandbox-spike twice against the same target process, once
# unsandboxed and once signed with the App Sandbox entitlement, to show exactly which
# calls an App Store edition would lose.
#
# Usage: scripts/sandbox-spike.sh <target-pid> <target-port> <project-file> <kill-pid>
set -euo pipefail

root=${0:A:h:h}
cd "$root"
swift build -c release --product sandbox-spike >/dev/null
bin=$(swift build -c release --show-bin-path)/sandbox-spike

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# A sandboxed executable needs a bundle identifier, so wrap it in a minimal .app.
app="$work/SandboxSpike.app"
mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/sandbox-spike"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.individual-11.headwaiter.sandbox-spike</string>
  <key>CFBundleExecutable</key><string>sandbox-spike</string>
  <key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
cat > "$work/sandbox.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.network.client</key><true/>
  <key>com.apple.security.network.server</key><true/>
</dict></plist>
PLIST

identity="WhatsRunning Dev"
security find-certificate -c "$identity" >/dev/null 2>&1 || identity="-"

echo "=== Without sandbox ==="
codesign --force --sign "$identity" "$app" >/dev/null 2>&1
"$app/Contents/MacOS/sandbox-spike" "$1" "$2" "$3" 1 || true   # pid 1: kill test skipped

echo
echo "=== With App Sandbox (network client + server entitlements) ==="
codesign --force --sign "$identity" --entitlements "$work/sandbox.entitlements" "$app" >/dev/null
"$app/Contents/MacOS/sandbox-spike" "$1" "$2" "$3" "$4" || true
