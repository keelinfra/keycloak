#!/usr/bin/env bash
# Spin up a 3-node local dev cluster with Multipass and configure the repo against it.
# Usage: dev/up.sh [--nodes 3] [--mem 3G] [--cpus 2] [--disk 15G]
set -euo pipefail
cd "$(dirname "$0")/.."

NODES=3 MEM=3G CPUS=2 DISK=15G
while [[ $# -gt 0 ]]; do
  case "$1" in
    --nodes) NODES="$2"; shift 2 ;;
    --mem)   MEM="$2";   shift 2 ;;
    --cpus)  CPUS="$2";  shift 2 ;;
    --disk)  DISK="$2";  shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done
[[ "$NODES" == "1" || "$NODES" == "3" ]] || { echo "error: --nodes must be 1 or 3" >&2; exit 1; }

command -v multipass >/dev/null || { echo "error: multipass not found (brew install --cask multipass)" >&2; exit 1; }

# SSH key to inject (prefer ed25519)
PUBKEY=""
for k in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub; do
  [[ -f "$k" ]] && PUBKEY="$k" && break
done
if [[ -z "$PUBKEY" ]]; then
  echo "No SSH key found — generating ~/.ssh/id_ed25519"
  ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
  PUBKEY=~/.ssh/id_ed25519.pub
fi

mkdir -p .dev
cat > .dev/cloud-init.yml <<CLOUDINIT
#cloud-config
users:
  - name: ubuntu
    ssh_authorized_keys:
      - $(cat "$PUBKEY")
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
CLOUDINIT

for i in $(seq 1 "$NODES"); do
  name="kc-dev$i"
  if multipass info "$name" >/dev/null 2>&1; then
    echo "→ $name already exists, skipping launch"
  else
    echo "→ launching $name (Ubuntu 24.04, ${CPUS}c/${MEM})"
    multipass launch 24.04 --name "$name" --cpus "$CPUS" --memory "$MEM" --disk "$DISK" \
      --cloud-init .dev/cloud-init.yml
  fi
done

# Build the dev cluster definition from live VM IPs
{
  echo "---"
  echo "cluster_name: keycloak-dev"
  echo "nodes:"
  for i in $(seq 1 "$NODES"); do
    ip=$(multipass info "kc-dev$i" --format csv | tail -1 | cut -d, -f3)
    echo "  - host: $ip"
    echo "    name: kc-dev$i"
  done
  echo "ssh_user: ubuntu"
  echo "domain: sso.dev.local"
  echo 'vip: ""'
  echo 'keycloak_version: "26.7.3"'
  echo "tls_mode: selfsigned"
} > .dev/cluster.yml

echo
echo "Dev cluster definition written to .dev/cluster.yml:"
cat .dev/cluster.yml
echo
./configure -c .dev/cluster.yml
