#!/usr/bin/env bash
# Build a universal Frida 17.5.0 DEB for jailbroken iOS devices.
# Target verified by design: iPhone 13 (A15), iOS 16.6.
# Produces rootful, Dopamine/rootless and RootHide package variants.
set -Eeuo pipefail

FRIDA_TAG="17.5.0"
INCLUDE_OABI=0
KEEP_WORK=0
OUTPUT_DIR="${PWD}/release-frida-${FRIDA_TAG}"
IOS_CERTID="${IOS_CERTID:-frida-cert}"
XCODE11="${XCODE11:-/Applications/Xcode-11.7.app}"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --include-oabi       Also include the legacy arm64e ABI slice. This requires
                       Xcode 11.7 at: ${XCODE11}
  --output DIR         Output directory. Default: ${OUTPUT_DIR}
  --keep-work          Keep the temporary source/build directory.
  -h, --help           Show this help.

Default output for iPhone 13 / iOS 16.6 does not require legacy arm64e OABI.
The important fix is a universal agent containing both arm64 and arm64e.
USAGE
}

while (($#)); do
  case "$1" in
    --include-oabi) INCLUDE_OABI=1; shift ;;
    --output) OUTPUT_DIR="$2"; shift 2 ;;
    --keep-work) KEEP_WORK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

fail() { echo "[ERROR] $*" >&2; exit 1; }
info() { echo "[INFO] $*"; }

[[ "$(uname -s)" == "Darwin" ]] || fail "This build must run on macOS. Xcode, lipo and codesign are required."

for cmd in git gmake xcrun python3 npm node lipo codesign install_name_tool security; do
  command -v "$cmd" >/dev/null 2>&1 || fail "Missing command: $cmd"
done

xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1 || fail "iPhoneOS SDK not found. Install full Xcode and select it with xcode-select."

if (( INCLUDE_OABI == 1 )); then
  [[ -d "$XCODE11" ]] || fail "Legacy OABI requested, but Xcode 11.7 was not found at $XCODE11"
  export XCODE11
fi

JOBS="$(($(sysctl -n hw.logicalcpu) + 1))"
WORK_DIR="$(mktemp -d /tmp/frida-17.5.0-ios.XXXXXX)"
DIST_DIR="${WORK_DIR}/dist"
ASSET_DIR="${WORK_DIR}/ios-assets"
SLICE_DIR="${WORK_DIR}/slices"
mkdir -p "$DIST_DIR" "$ASSET_DIR/usr/bin" "$ASSET_DIR/usr/lib/frida" "$SLICE_DIR" "$OUTPUT_DIR"

cleanup() {
  if (( KEEP_WORK == 0 )); then
    rm -rf "$WORK_DIR"
  else
    echo "[INFO] Kept work directory: $WORK_DIR"
  fi
}
trap cleanup EXIT INT TERM

info "Cloning Frida ${FRIDA_TAG}"
git clone --branch "$FRIDA_TAG" --single-branch --filter=blob:none https://github.com/frida/frida.git "${WORK_DIR}/frida"
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
export FRIDA_VERSION
FRIDA_VERSION="$(releng/frida_version.py)"
[[ "$FRIDA_VERSION" == "$FRIDA_TAG" ]] || fail "Checked out ${FRIDA_TAG}, but build version is ${FRIDA_VERSION}"

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

# Frida's ios-arm64e build contains the current arm64 and arm64e variants.
build_target ios-arm64e arm64e

if (( INCLUDE_OABI == 1 )); then
  mkdir -p tmp
  if releng/deps.py sync sdk ios-arm64eoabi tmp; then
    rm -rf tmp
  else
    rm -rf tmp
    info "Prebuilt legacy arm64e SDK was not found; building it with Xcode 11.7"
    ./releng/deps.py build --bundle=sdk --host=ios-arm64eoabi
  fi
  build_target ios-arm64eoabi arm64eoabi
fi

SERVER_FAT_SOURCE="${DIST_DIR}/arm64e/usr/bin/frida-server"
AGENT_SOURCE="${DIST_DIR}/arm64e/usr/lib/frida/frida-agent.dylib"
[[ -f "$SERVER_FAT_SOURCE" ]] || fail "frida-server was not generated"
[[ -f "$AGENT_SOURCE" ]] || fail "frida-agent.dylib was not generated"

info "Extracting and signing server slices"
for arch in arm64 arm64e; do
  lipo "$SERVER_FAT_SOURCE" -thin "$arch" -output "${SLICE_DIR}/frida-server-${arch}"
  codesign -f -s - --preserve-metadata=entitlements --timestamp=none "${SLICE_DIR}/frida-server-${arch}"
done

server_inputs=(
  "${SLICE_DIR}/frida-server-arm64"
)

if (( INCLUDE_OABI == 1 )); then
  OABI_SOURCE="${DIST_DIR}/arm64eoabi/usr/bin/frida-server"
  lipo "$OABI_SOURCE" -thin arm64e -output "${SLICE_DIR}/frida-server-arm64eoabi"
  codesign -f -s - --preserve-metadata=entitlements --timestamp=none "${SLICE_DIR}/frida-server-arm64eoabi"
  server_inputs+=("${SLICE_DIR}/frida-server-arm64eoabi")
fi
server_inputs+=("${SLICE_DIR}/frida-server-arm64e")

python3 ./releng/mkfatmacho.py "${ASSET_DIR}/usr/bin/frida-server" "${server_inputs[@]}"

info "Preparing universal arm64 + arm64e agent"
cp "$AGENT_SOURCE" "${ASSET_DIR}/usr/lib/frida/frida-agent.dylib"
install_name_tool -id FridaAgent "${ASSET_DIR}/usr/lib/frida/frida-agent.dylib"

SIGN_ID="-"
if security find-identity -v -p codesigning | grep -Fq "$IOS_CERTID"; then
  SIGN_ID="$IOS_CERTID"
  info "Signing agent with identity: ${IOS_CERTID}"
else
  info "Signing agent ad-hoc. Identity '${IOS_CERTID}' was not found."
fi
codesign -f -s "$SIGN_ID" \
  --preserve-metadata=entitlements \
  --timestamp=none \
  --generate-entitlement-der \
  "${ASSET_DIR}/usr/lib/frida/frida-agent.dylib"

AGENT_ARCHS="$(lipo -archs "${ASSET_DIR}/usr/lib/frida/frida-agent.dylib")"
[[ "$AGENT_ARCHS" == *arm64* ]] || fail "Agent is missing arm64: ${AGENT_ARCHS}"
[[ "$AGENT_ARCHS" == *arm64e* ]] || fail "Agent is missing arm64e: ${AGENT_ARCHS}"
info "Agent slices: ${AGENT_ARCHS}"

PACKAGE_HELPER="./subprojects/frida-core/tools/package-server-fruity.sh"
[[ -x "$PACKAGE_HELPER" ]] || fail "Packaging helper was not found: ${PACKAGE_HELPER}"

info "Packaging three jailbreak variants"
for pkg_arch in arm arm64 arm64e; do
  "$PACKAGE_HELPER" \
    "iphoneos-${pkg_arch}" \
    "$ASSET_DIR" \
    "${OUTPUT_DIR}/frida_${FRIDA_VERSION}_iphoneos-${pkg_arch}_universal.deb"
done

cat > "${OUTPUT_DIR}/BUILD-INFO.txt" <<INFO
Frida version: ${FRIDA_VERSION}
Target device: iPhone 13 (A15)
Target iOS: 16.6
Universal agent slices: ${AGENT_ARCHS}
Legacy arm64e OABI included: ${INCLUDE_OABI}
Build date: $(date -u +'%Y-%m-%dT%H:%M:%SZ')
Package selection:
  iphoneos-arm64 = Dopamine/rootless
  iphoneos-arm64e = RootHide
  iphoneos-arm = rootful
INFO

(
  cd "$OUTPUT_DIR"
  shasum -a 256 ./*.deb > SHA256SUMS
)

info "Build complete: ${OUTPUT_DIR}"
ls -lh "$OUTPUT_DIR"
