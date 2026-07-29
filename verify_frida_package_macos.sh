#!/usr/bin/env bash
set -Eeuo pipefail

DEB="${1:-}"
[[ -n "$DEB" && -f "$DEB" ]] || { echo "Usage: $0 <frida.deb>" >&2; exit 2; }
command -v dpkg-deb >/dev/null || { echo "Install dpkg: brew install dpkg" >&2; exit 1; }

TMP="$(mktemp -d /tmp/frida-deb-check.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

dpkg-deb -x "$DEB" "$TMP"
SERVER="$(find "$TMP" -type f \( -name frida-server -o -name frida-server64 \) | head -n1)"
AGENT="$(find "$TMP" -type f -name frida-agent.dylib | head -n1)"

[[ -n "$SERVER" ]] || { echo "frida-server not found" >&2; exit 1; }
[[ -n "$AGENT" ]] || { echo "frida-agent.dylib not found" >&2; exit 1; }

echo "Package: $DEB"
echo "Server: $SERVER"
file "$SERVER"
echo "Agent: $AGENT"
file "$AGENT"
echo "Agent architectures: $(lipo -archs "$AGENT")"
codesign -d --entitlements :- "$SERVER" 2>/dev/null || true
codesign -d --entitlements :- "$AGENT" 2>/dev/null || true

ARCHS="$(lipo -archs "$AGENT")"
[[ "$ARCHS" == *arm64* && "$ARCHS" == *arm64e* ]] || {
  echo "FAIL: agent must contain both arm64 and arm64e" >&2
  exit 1
}
echo "PASS: universal agent contains arm64 and arm64e"
