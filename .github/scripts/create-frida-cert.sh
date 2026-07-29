#!/usr/bin/env bash
# Create a temporary, trusted code-signing identity for Frida builds on a
# GitHub-hosted macOS runner. Nothing is persisted after the job finishes.
set -Eeuo pipefail

CERT_NAME="frida-cert"
CERT_DIR="${RUNNER_TEMP:-/tmp}/frida-signing-cert"
KEYCHAIN_PATH="${RUNNER_TEMP:-/tmp}/frida-build.keychain-db"
KEYCHAIN_PASSWORD="$(uuidgen)"
P12_PASSWORD="$(uuidgen)"

mkdir -p "$CERT_DIR"

cat > "$CERT_DIR/openssl.cnf" <<CONF
[ req ]
default_bits = 2048
encrypt_key = no
default_md = sha256
prompt = no
distinguished_name = codesign_dn
x509_extensions = codesign_ext

[ codesign_dn ]
commonName = ${CERT_NAME}

[ codesign_ext ]
basicConstraints = critical,CA:true
keyUsage = critical,digitalSignature,keyCertSign
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
CONF

openssl req \
  -new -newkey rsa:2048 -x509 -nodes -days 30 \
  -config "$CERT_DIR/openssl.cnf" \
  -out "$CERT_DIR/${CERT_NAME}.pem" \
  -keyout "$CERT_DIR/${CERT_NAME}.key"

openssl pkcs12 -export \
  -name "$CERT_NAME" \
  -inkey "$CERT_DIR/${CERT_NAME}.key" \
  -in "$CERT_DIR/${CERT_NAME}.pem" \
  -out "$CERT_DIR/${CERT_NAME}.p12" \
  -passout "pass:${P12_PASSWORD}"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

# Keep the runner's existing keychains searchable and prepend our temporary one.
# macOS still ships Bash 3.2, so avoid mapfile/readarray.
CURRENT_KEYCHAINS="$(security list-keychains -d user | tr -d '"' | xargs)"
# shellcheck disable=SC2086
security list-keychains -d user -s "$KEYCHAIN_PATH" $CURRENT_KEYCHAINS
security default-keychain -d user -s "$KEYCHAIN_PATH"

security import "$CERT_DIR/${CERT_NAME}.p12" \
  -k "$KEYCHAIN_PATH" \
  -P "$P12_PASSWORD" \
  -T /usr/bin/codesign \
  -T /usr/bin/security

# Prevent a GUI key-access prompt on the headless CI runner.
security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s -k "$KEYCHAIN_PASSWORD" \
  "$KEYCHAIN_PATH"

# Trust the generated root for the code-signing policy in the user trust domain.
security add-trusted-cert \
  -r trustRoot \
  -p codeSign \
  -k "$KEYCHAIN_PATH" \
  "$CERT_DIR/${CERT_NAME}.pem"

security find-certificate -a -c "$CERT_NAME" "$KEYCHAIN_PATH"
security find-identity -v -p codesigning "$KEYCHAIN_PATH"

IDENTITY_HASH="$(security find-identity -v -p codesigning "$KEYCHAIN_PATH" | awk -v name="\"${CERT_NAME}\"" '$0 ~ name { print $2; exit }')"
if [[ -z "$IDENTITY_HASH" ]]; then
  echo "[ERROR] ${CERT_NAME} was imported, but macOS did not expose it as a valid code-signing identity." >&2
  exit 1
fi

# Use the SHA-1 identity hash so codesign does not depend on name matching.
echo "IOS_CERTID=${IDENTITY_HASH}" >> "$GITHUB_ENV"
echo "FRIDA_KEYCHAIN_PATH=${KEYCHAIN_PATH}" >> "$GITHUB_ENV"
echo "[INFO] Temporary Frida code-signing identity: ${IDENTITY_HASH}"
