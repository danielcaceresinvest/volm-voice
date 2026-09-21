#!/bin/bash
# One-time: creates a self-signed "VOLM Dev" code-signing certificate in the login keychain.
# A stable signature lets macOS remember the mic and speech permissions across rebuilds.
set -euo pipefail
NAME="VOLM Dev"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then echo "\"$NAME\" already exists"; exit 0; fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem"
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" -out "$TMP/cert.p12" -passout pass:volm 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" -out "$TMP/cert.p12" -passout pass:volm
security import "$TMP/cert.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P volm -T /usr/bin/codesign
echo "Created \"$NAME\""
