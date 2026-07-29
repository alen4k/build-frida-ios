#!/usr/bin/env bash
set -Eeuo pipefail

DEB="${1:-}"
SSH_PORT="${SSH_PORT:-2222}"
SSH_USER="${SSH_USER:-root}"
SSH_HOST="${SSH_HOST:-127.0.0.1}"

[[ -n "$DEB" && -f "$DEB" ]] || {
  echo "Usage: SSH_PORT=2222 SSH_USER=root $0 <frida_17.5.0_iphoneos-arm64_universal.deb>" >&2
  exit 2
}

REMOTE="/var/mobile/$(basename "$DEB")"
scp -P "$SSH_PORT" "$DEB" "${SSH_USER}@${SSH_HOST}:${REMOTE}"
ssh -p "$SSH_PORT" "${SSH_USER}@${SSH_HOST}" "
  set -e
  dpkg -i '${REMOTE}' || apt-get -f install -y
  launchctl kickstart -k system/re.frida.server 2>/dev/null || true
  sleep 2
  /var/jb/usr/sbin/frida-server --version 2>/dev/null || \
  /var/jb/usr/bin/frida-server --version 2>/dev/null || \
  frida-server --version
"

echo "Install complete. On the host use: frida-ps -Uai"
