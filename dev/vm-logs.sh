#!/usr/bin/env bash
# Collect diagnostics from the VM rig's nodes: the journal, failed units,
# listeners, SELinux mode and denials. Safe on a half-installed rig.
# Usage: dev/vm-logs.sh [outdir]        (default .dev/vm/artifacts)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE="$ROOT/.dev/vm"
OUT="${1:-$STATE/artifacts}"
mkdir -p "$OUT"
user=rocky
[[ "$(cat "$STATE/os" 2>/dev/null)" == ubuntu24.04 ]] && user=ubuntu
for i in 1 2 3; do
  node="kc-vm$i" ip="192.168.123.1$i"
  mkdir -p "$OUT/$node"
  on() {
    local file="$1"; shift
    ssh -q -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -i "$STATE/id_ed25519" "$user@$ip" "$@" \
      > "$OUT/$node/$file" 2>&1 || true
  }
  on journal.log sudo journalctl --no-pager -o short-iso
  on units.txt sh -c 'systemctl --failed --no-pager; echo; systemctl list-units --type=service --no-pager'
  on listeners.txt sudo ss -tlnp
  on selinux.txt sh -c 'getenforce 2>/dev/null || echo "no SELinux"; sudo ausearch -m AVC,USER_AVC -ts boot -i 2>&1 | tail -n 200'
  on patroni.txt sudo patronictl -c /etc/patroni/config.yml list
  on ip.txt ip -br addr
  echo "$node: collected"
done
# Serial consoles: the boot, cloud-init and login prompt, even when ssh never came up.
cp "${VM_DISK_DIR:-$STATE}"/kc-vm*-console.log "$OUT/" 2>/dev/null || true
echo "→ $OUT"
