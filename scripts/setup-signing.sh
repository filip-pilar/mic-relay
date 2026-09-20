#!/bin/bash
set -euo pipefail

# One persistent identity for local Xcode builds and DMGs. Never regenerate on rebuild.
SIGNING_NAME="Mic Relay Local Development"
if security find-identity -v -p codesigning | grep -Fq "\"$SIGNING_NAME\""; then
    echo "$SIGNING_NAME is already available."
    exit 0
fi

umask 077
SIGNING_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/mic-relay-signing.XXXXXX")"
trap 'rm -rf "$SIGNING_TEMP"' EXIT

if security find-certificate -c "$SIGNING_NAME" -p > "$SIGNING_TEMP/certificate.pem" 2>/dev/null; then
    echo "Reusing the existing certificate; its private key must remain in your Keychain."
else
    /usr/bin/openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 3650 \
        -subj "/CN=$SIGNING_NAME/" \
        -addext "basicConstraints=critical,CA:FALSE" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning" \
        -keyout "$SIGNING_TEMP/private-key.pem" -out "$SIGNING_TEMP/certificate.pem" \
        2> "$SIGNING_TEMP/openssl.log" || { cat "$SIGNING_TEMP/openssl.log" >&2; exit 1; }
    /usr/bin/openssl rand -hex 32 > "$SIGNING_TEMP/passphrase"
    /usr/bin/openssl pkcs12 -export -name "$SIGNING_NAME" \
        -inkey "$SIGNING_TEMP/private-key.pem" -in "$SIGNING_TEMP/certificate.pem" \
        -out "$SIGNING_TEMP/identity.p12" -passout "file:$SIGNING_TEMP/passphrase"
    # Non-exportable key; only codesign gets access without another Keychain prompt.
    security import "$SIGNING_TEMP/identity.p12" -P "$(cat "$SIGNING_TEMP/passphrase")" -x -T /usr/bin/codesign
fi

# Trust only code signing, in this user's trust store (not SSL or system-wide trust).
security add-trusted-cert -r trustRoot -p codeSign "$SIGNING_TEMP/certificate.pem"
if ! security find-identity -v -p codesigning | grep -Fq "\"$SIGNING_NAME\""; then
    echo "Signing identity is unavailable. Check its certificate and private key in Keychain Access; do not delete it to fix a build." >&2
    exit 1
fi
echo "Local signing is ready. Keep this identity to retain permissions across builds."
