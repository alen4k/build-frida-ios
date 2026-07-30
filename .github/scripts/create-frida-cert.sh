#!/usr/bin/env bash
# Create a temporary code-signing identity for a GitHub-hosted macOS runner.
# Important: do NOT call `security add-trusted-cert` here. On headless hosted
# runners that command may wait indefinitely for an authorization UI.
set -Eeuo pipefail

CERT_NAME="frida-cert"
CERT_DIR="${RUNNER_TEMP:-/tmp}/frida-signing-cert"
KEYCHAIN_PATH="${RUNNER_TEMP:-/tmp}/frida-build.keychain-db"
KEYCHAIN_PASSWORD="$(uuidgen)"
P12_PASSWORD="$(uuidgen)"

rm -rf "$CERT_DIR"
rm -f "$KEYCHAIN_PATH"
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
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CONF

openssl req \
  -new -newkey rsa:2048 -x509 -nodes -days 7 \
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

# Keep the runner keychains searchable and prepend the temporary keychain.
CURRENT_KEYCHAINS="$(security list-keychains -d user | tr -d '"' | xargs)"
# shellcheck disable=SC2086
security list-keychains -d user -s "$KEYCHAIN_PATH" $CURRENT_KEYCHAINS
security default-keychain -d user -s "$KEYCHAIN_PATH"

security import "$CERT_DIR/${CERT_NAME}.p12" \
  -k "$KEYCHAIN_PATH" \
  -P "$P12_PASSWORD" \
  -T /usr/bin/codesign \
  -T /usr/bin/security

# Allow headless codesign access to the imported private key.
security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s -k "$KEYCHAIN_PASSWORD" \
  "$KEYCHAIN_PATH"

# Obtain the certificate SHA-1 directly. We intentionally do not modify the
# macOS trust store; codesign only needs the identity and its private key.
IDENTITY_HASH="$(security find-certificate -Z -c "$CERT_NAME" "$KEYCHAIN_PATH" | awk '/SHA-1 hash:/ { print $3; exit }')"
if [[ ! "$IDENTITY_HASH" =~ ^[0-9A-Fa-f]{40}$ ]]; then
  echo "[ERROR] Failed to obtain SHA-1 for ${CERT_NAME}." >&2
  security find-certificate -a -c "$CERT_NAME" "$KEYCHAIN_PATH" || true
  exit 1
fi

# Prove that the identity is usable before beginning the long Frida build.
cat > "$CERT_DIR/probe.c" <<'C'
int main(void) { return 0; }
C
xcrun clang "$CERT_DIR/probe.c" -o "$CERT_DIR/probe"
codesign --force --sign "$IDENTITY_HASH" \
  --keychain "$KEYCHAIN_PATH" \
  --timestamp=none \
  "$CERT_DIR/probe"
codesign --verify --strict "$CERT_DIR/probe"

# Diagnostic only. A locally generated certificate may not be reported as a
# globally trusted identity, but the probe above is the authoritative test.
security find-identity -v -p codesigning "$KEYCHAIN_PATH" || true

echo "IOS_CERTID=${IDENTITY_HASH}" >> "$GITHUB_ENV"
echo "FRIDA_KEYCHAIN_PATH=${KEYCHAIN_PATH}" >> "$GITHUB_ENV"
echo "[INFO] Temporary Frida signing identity is usable: ${IDENTITY_HASH}"
