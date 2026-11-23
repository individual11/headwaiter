#!/bin/zsh
# Creates a local, self-signed code-signing certificate "WhatsRunning Dev" (label kept from
# the app's working name) in your login
# keychain, so development builds keep one stable identity and macOS privacy grants
# (Desktop, Documents...) survive rebuilds. Local only; release builds use Developer ID.
#
# Run it yourself: macOS asks for your login password to trust the certificate for code signing.
# Undo: Keychain Access → login → My Certificates → delete "WhatsRunning Dev".
set -euo pipefail

name="WhatsRunning Dev"
keychain="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$name" "$keychain" >/dev/null 2>&1; then
    echo "\"$name\" already exists in your login keychain."
    exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -config "$tmp/cert.cnf" 2>/dev/null
# Throwaway password, only used for the hand-off to `security import`.
/usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
    -out "$tmp/dev.p12" -passout pass:whatsrunning -name "$name"

# -T lets codesign use the key without a keychain prompt on every build.
security import "$tmp/dev.p12" -k "$keychain" -P whatsrunning -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$tmp/cert.pem"

echo "Created \"$name\". scripts/build-app.sh will now sign with it."
