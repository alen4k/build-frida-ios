#!/usr/bin/env bash
# Build a complete Frida iOS toolkit from the selected upstream tag.
#
# Primary target:
#   - iPhone 13 (A15)
#   - iOS 16.6
#   - standard rootless jailbreak layout
#
# Output:
#   - rootless/rootful DEB packages
#   - universal Frida Gadget
#   - frida-inject
#   - standalone universal server and Agent
#   - Gadget configuration
#   - host-side requirements file
set -Eeuo pipefail

FRIDA_TAG="${FRIDA_TAG:-17.16.4}"
INCLUDE_OABI=0
KEEP_WORK=0
OUTPUT_DIR="${PWD}/release-frida-${FRIDA_TAG}"
IOS_CERTID="${IOS_CERTID:--}"
XCODE11="${XCODE11:-/Applications/Xcode-11.7.app}"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --include-oabi       Include the legacy arm64e ABI server slice.
                       Requires Xcode 11.7 at: ${XCODE11}
  --output DIR         Output directory.
                       Default: ${OUTPUT_DIR}
  --keep-work          Keep the temporary source/build directory.
  -h, --help           Show this help.

The default iPhone 13 / iOS 16.6 build does not require the legacy
arm64e OABI. The generated Agent and Gadget must contain arm64 + arm64e.
USAGE
}

while (($#)); do
  case "$1" in
    --include-oabi)
      INCLUDE_OABI=1
      shift
      ;;
    --output)
      [[ $# -ge 2 ]] || { echo "--output requires a directory" >&2; exit 2; }
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --keep-work)
      KEEP_WORK=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

fail() {
  echo "[ERROR] $*" >&2
  exit 1
}

info() {
  echo "[INFO] $*"
}

[[ "$(uname -s)" == "Darwin" ]] || \
  fail "This build must run on macOS because Xcode, lipo and codesign are required."

for cmd in git gmake xcrun python3 npm node lipo codesign install_name_tool file; do
  command -v "$cmd" >/dev/null 2>&1 || fail "Missing command: $cmd"
done

xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1 || \
  fail "iPhoneOS SDK not found. Install full Xcode and select it with xcode-select."

if (( INCLUDE_OABI == 1 )); then
  [[ -d "$XCODE11" ]] || \
    fail "Legacy OABI requested, but Xcode 11.7 was not found at ${XCODE11}"
  export XCODE11
fi

JOBS="$(($(sysctl -n hw.logicalcpu) + 1))"
WORK_DIR="$(mktemp -d "/tmp/frida-${FRIDA_TAG}-ios.XXXXXX")"
DIST_DIR="${WORK_DIR}/dist"
ASSET_DIR="${WORK_DIR}/ios-assets"
SLICE_DIR="${WORK_DIR}/slices"
TOOLS_DIR="${OUTPUT_DIR}/ios-tools"

mkdir -p \
  "$DIST_DIR" \
  "$ASSET_DIR/usr/bin" \
  "$ASSET_DIR/usr/lib/frida-1.0" \
  "$SLICE_DIR" \
  "$TOOLS_DIR"

cleanup() {
  if (( KEEP_WORK == 0 )); then
    rm -rf "$WORK_DIR"
  else
    info "Kept work directory: $WORK_DIR"
  fi
}
trap cleanup EXIT INT TERM

info "Cloning Frida ${FRIDA_TAG}"
git clone \
  --branch "$FRIDA_TAG" \
  --single-branch \
  --filter=blob:none \
  https://github.com/frida/frida.git \
  "${WORK_DIR}/frida"

cd "${WORK_DIR}/frida"

git submodule update --init --depth 1 releng
(
  cd releng
  git submodule update --init --depth 1
)

python3 -m venv --upgrade-deps .venv
# shellcheck disable=SC1091
source .venv/bin/activate
python3 -m pip install --upgrade pip setuptools wheel

export PYTHON="$(command -v python3)"
export PYTHONWARNINGS=all
export IOS_CERTID

if [[ "$IOS_CERTID" == "-" ]]; then
  info "Using ad-hoc signing for jailbreak-targeted artifacts"
else
  info "Using configured signing identity: ${IOS_CERTID}"
fi

FRIDA_VERSION="$(releng/frida_version.py)"
export FRIDA_VERSION
[[ "$FRIDA_VERSION" == "$FRIDA_TAG" ]] || \
  fail "Checked out ${FRIDA_TAG}, but upstream build version is ${FRIDA_VERSION}"

build_target() {
  local host="$1"
  local name="$2"
  local build_root="${WORK_DIR}/build-${name}"
  local dest_root="${DIST_DIR}/${name}"

  info "Building ${host}"
  export MESON_BUILD_ROOT="$build_root"

  ./configure \
    --prefix=/usr \
    --host="$host" \
    -- \
    -Dfrida-core:assets=installed

  gmake -j"$JOBS"
  DESTDIR="$dest_root" gmake -j"$JOBS" install
}

# Current Frida ios-arm64e builds universal arm64 + arm64e fruity artifacts.
build_target ios-arm64e arm64e

if (( INCLUDE_OABI == 1 )); then
  mkdir -p tmp
  if releng/deps.py sync sdk ios-arm64eoabi tmp; then
    rm -rf tmp
  else
    rm -rf tmp
    info "Prebuilt legacy arm64e SDK not found; building it with Xcode 11.7"
    ./releng/deps.py build --bundle=sdk --host=ios-arm64eoabi
  fi
  build_target ios-arm64eoabi arm64eoabi
fi

SERVER_SOURCE="${DIST_DIR}/arm64e/usr/bin/frida-server"
INJECT_SOURCE="${DIST_DIR}/arm64e/usr/bin/frida-inject"

find_asset() {
  local description="$1"
  shift

  local candidate
  for candidate in "$@"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  fail "${description} was not generated. Checked: $*"
}

AGENT_SOURCE="$(find_asset \
  "frida-agent.dylib" \
  "${DIST_DIR}/arm64e/usr/lib/frida-1.0/frida-agent.dylib" \
  "${DIST_DIR}/arm64e/usr/lib/frida/frida-agent.dylib")"

GADGET_SOURCE="$(find_asset \
  "frida-gadget.dylib" \
  "${DIST_DIR}/arm64e/usr/lib/frida-1.0/frida-gadget.dylib" \
  "${DIST_DIR}/arm64e/usr/lib/frida/frida-gadget.dylib")"

[[ -f "$SERVER_SOURCE" ]] || \
  fail "frida-server was not generated: ${SERVER_SOURCE}"
[[ -f "$INJECT_SOURCE" ]] || \
  fail "frida-inject was not generated: ${INJECT_SOURCE}"

info "Using Agent: ${AGENT_SOURCE}"
info "Using Gadget: ${GADGET_SOURCE}"

# ---------------------------------------------------------------------------
# Build universal server
# ---------------------------------------------------------------------------
info "Extracting and signing server slices"

for arch in arm64 arm64e; do
  lipo "$SERVER_SOURCE" \
    -thin "$arch" \
    -output "${SLICE_DIR}/frida-server-${arch}"

  codesign \
    --force \
    --sign "$IOS_CERTID" \
    --preserve-metadata=entitlements \
    --timestamp=none \
    --generate-entitlement-der \
    "${SLICE_DIR}/frida-server-${arch}"
done

server_inputs=("${SLICE_DIR}/frida-server-arm64")

if (( INCLUDE_OABI == 1 )); then
  OABI_SOURCE="${DIST_DIR}/arm64eoabi/usr/bin/frida-server"
  [[ -f "$OABI_SOURCE" ]] || fail "Legacy OABI server was not generated"

  lipo "$OABI_SOURCE" \
    -thin arm64e \
    -output "${SLICE_DIR}/frida-server-arm64eoabi"

  codesign \
    --force \
    --sign "$IOS_CERTID" \
    --preserve-metadata=entitlements \
    --timestamp=none \
    --generate-entitlement-der \
    "${SLICE_DIR}/frida-server-arm64eoabi"

  server_inputs+=("${SLICE_DIR}/frida-server-arm64eoabi")
fi

server_inputs+=("${SLICE_DIR}/frida-server-arm64e")

python3 ./releng/mkfatmacho.py \
  "${ASSET_DIR}/usr/bin/frida-server" \
  "${server_inputs[@]}"

codesign \
  --force \
  --sign "$IOS_CERTID" \
  --preserve-metadata=entitlements \
  --timestamp=none \
  --generate-entitlement-der \
  "${ASSET_DIR}/usr/bin/frida-server"

# ---------------------------------------------------------------------------
# Prepare universal external Agent
# ---------------------------------------------------------------------------
info "Preparing universal arm64 + arm64e Agent"

cp "$AGENT_SOURCE" \
  "${ASSET_DIR}/usr/lib/frida-1.0/frida-agent.dylib"

install_name_tool \
  -id FridaAgent \
  "${ASSET_DIR}/usr/lib/frida-1.0/frida-agent.dylib"

codesign \
  --force \
  --sign "$IOS_CERTID" \
  --preserve-metadata=entitlements \
  --timestamp=none \
  --generate-entitlement-der \
  "${ASSET_DIR}/usr/lib/frida-1.0/frida-agent.dylib"

AGENT_ARCHS="$(lipo -archs \
  "${ASSET_DIR}/usr/lib/frida-1.0/frida-agent.dylib")"

[[ "$AGENT_ARCHS" == *arm64* ]] || \
  fail "Agent is missing arm64: ${AGENT_ARCHS}"
[[ "$AGENT_ARCHS" == *arm64e* ]] || \
  fail "Agent is missing arm64e: ${AGENT_ARCHS}"

info "Agent slices: ${AGENT_ARCHS}"

# ---------------------------------------------------------------------------
# Export Gadget and other standalone iOS tools
# ---------------------------------------------------------------------------
info "Exporting Gadget and standalone iOS tools"

cp "$GADGET_SOURCE" "${TOOLS_DIR}/FridaGadget.dylib"
cp "$INJECT_SOURCE" "${TOOLS_DIR}/frida-inject"
cp "${ASSET_DIR}/usr/bin/frida-server" "${TOOLS_DIR}/frida-server"
cp "${ASSET_DIR}/usr/lib/frida-1.0/frida-agent.dylib" \
  "${TOOLS_DIR}/frida-agent.dylib"

chmod 755 \
  "${TOOLS_DIR}/frida-inject" \
  "${TOOLS_DIR}/frida-server"

# Re-sign copied artifacts so the final exported files are self-consistent.
for artifact in \
  "${TOOLS_DIR}/FridaGadget.dylib" \
  "${TOOLS_DIR}/frida-inject" \
  "${TOOLS_DIR}/frida-server" \
  "${TOOLS_DIR}/frida-agent.dylib"
do
  codesign \
    --force \
    --sign "$IOS_CERTID" \
    --preserve-metadata=entitlements \
    --timestamp=none \
    --generate-entitlement-der \
    "$artifact"
done

GADGET_ARCHS="$(lipo -archs "${TOOLS_DIR}/FridaGadget.dylib")"
SERVER_ARCHS="$(lipo -archs "${TOOLS_DIR}/frida-server")"
INJECT_ARCHS="$(lipo -archs "${TOOLS_DIR}/frida-inject" 2>/dev/null || true)"

[[ "$GADGET_ARCHS" == *arm64* ]] || \
  fail "Gadget is missing arm64: ${GADGET_ARCHS}"
[[ "$GADGET_ARCHS" == *arm64e* ]] || \
  fail "Gadget is missing arm64e: ${GADGET_ARCHS}"

info "Gadget slices: ${GADGET_ARCHS}"
info "Server slices: ${SERVER_ARCHS}"
info "frida-inject slices: ${INJECT_ARCHS:-unknown}"

cat > "${TOOLS_DIR}/FridaGadget.config" <<'JSON'
{
  "interaction": {
    "type": "listen",
    "address": "127.0.0.1",
    "port": 27042,
    "on_port_conflict": "pick-next",
    "on_load": "wait"
  },
  "teardown": "minimal",
  "runtime": "qjs",
  "code_signing": "optional"
}
JSON

cat > "${TOOLS_DIR}/README.txt" <<'TEXT'
FridaGadget.dylib
  Universal arm64 + arm64e Gadget for embedding into an authorized iOS app.

FridaGadget.config
  Matching Gadget configuration. Keep the base name identical to the dylib.

frida-inject
  Device-side injection utility.

frida-server
  Standalone universal server used by the generated DEB packages.

frida-agent.dylib
  External installed-assets Agent. Standard rootless package path:
  /var/jb/usr/lib/frida-1.0/frida-agent.dylib
TEXT

cat > "${OUTPUT_DIR}/requirements-host.txt" <<REQ
frida==${FRIDA_VERSION}
frida-tools
REQ

# ---------------------------------------------------------------------------
# Package DEBs
# ---------------------------------------------------------------------------
PACKAGE_HELPER="./subprojects/frida-core/tools/package-server-fruity.sh"
[[ -x "$PACKAGE_HELPER" ]] || \
  fail "Packaging helper not found: ${PACKAGE_HELPER}"

grep -Fq 'usr/lib/frida-1.0/frida-agent.dylib' "$PACKAGE_HELPER" || \
  fail "Selected Frida tag uses an unexpected installed Agent path"

info "Packaging jailbreak variants"

for pkg_arch in arm arm64 arm64e; do
  "$PACKAGE_HELPER" \
    "iphoneos-${pkg_arch}" \
    "$ASSET_DIR" \
    "${OUTPUT_DIR}/frida_${FRIDA_VERSION}_iphoneos-${pkg_arch}_universal.deb"
done

cat > "${OUTPUT_DIR}/BUILD-INFO.txt" <<INFO
Frida version: ${FRIDA_VERSION}
Primary target device: iPhone 13 (A15)
Primary target iOS: 16.6
Primary jailbreak layout: standard rootless
Universal Agent slices: ${AGENT_ARCHS}
Universal Gadget slices: ${GADGET_ARCHS}
Universal Server slices: ${SERVER_ARCHS}
frida-inject slices: ${INJECT_ARCHS:-unknown}
Installed Agent namespace: /usr/lib/frida-1.0
Standard rootless Agent path: /var/jb/usr/lib/frida-1.0/frida-agent.dylib
Legacy arm64e OABI included: ${INCLUDE_OABI}
Signing identity: ${IOS_CERTID}
Build date: $(date -u +'%Y-%m-%dT%H:%M:%SZ')

Package selection:
  iphoneos-arm64  = standard rootless
  iphoneos-arm    = rootful
  iphoneos-arm64e = RootHide-style package architecture; validate separately
INFO

# The workflow regenerates this file after adding the ObjC bridge bundle.
(
  cd "$OUTPUT_DIR"
  : > SHA256SUMS
  while IFS= read -r item; do
    shasum -a 256 "$item"
  done < <(
    find . -type f ! -name SHA256SUMS -print | LC_ALL=C sort
  ) > SHA256SUMS
)

info "Build complete: ${OUTPUT_DIR}"
find "$OUTPUT_DIR" -maxdepth 3 -type f -print | LC_ALL=C sort
