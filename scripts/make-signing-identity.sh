#!/bin/sh
# Makes the self-signed code-signing identity Deckhand's builds sign with (scripts/sign.sh,
# docs/DEVELOPING.md "Code signing"): an RSA key and a 10-year certificate with the codeSigning
# extended key usage, imported into the login keychain with codesign allowed to use the key.
# Once per Mac. The key never leaves the keychain: it is made in a private temporary folder,
# imported, and the folder is removed; nothing is printed but the certificate's fingerprint.
# Not trusted (no admin prompt): codesign signs with it all the same, and the designated
# requirement names the certificate's hash, not a trust anchor.
# Every Mac that builds gets its own certificate: builds from another Mac (or a new certificate)
# ask for the privacy grants once more.
# Usage: scripts/make-signing-identity.sh [NAME]   (default: $DECKHAND_SIGN_IDENTITY, else
#        "Deckhand Self-Signed")
set -eu
NAME=${1:-${DECKHAND_SIGN_IDENTITY:-Deckhand Self-Signed}}
KC=$HOME/Library/Keychains/login.keychain-db
if security find-identity -p codesigning 2>/dev/null | grep -qF "\"$NAME\""; then
  echo "make-signing-identity: \"$NAME\" is already in the keychain"
  exit 0
fi
umask 077
D=$(mktemp -d "${TMPDIR:-/tmp}/deckhand-sign.XXXXXX")
trap 'rm -rf "$D"' EXIT INT TERM
cat > "$D/cfg" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
# /usr/bin/openssl (LibreSSL): its .p12 is one `security import` reads (OpenSSL 3's default
# ciphers are not)
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 -config "$D/cfg" \
  -keyout "$D/key.pem" -out "$D/cert.pem" 2>/dev/null
P=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -inkey "$D/key.pem" -in "$D/cert.pem" -name "$NAME" \
  -out "$D/id.p12" -passout "pass:$P" 2>/dev/null
rm -f "$D/key.pem"
security import "$D/id.p12" -k "$KC" -f pkcs12 -P "$P" -T /usr/bin/codesign >/dev/null
echo "make-signing-identity: \"$NAME\" is in $KC ($(/usr/bin/openssl x509 -in "$D/cert.pem" -noout -fingerprint -sha1))"
