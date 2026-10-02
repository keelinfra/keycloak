#!/usr/bin/env bash
# Bring up the 3-node container rig and configure the repo against it.
# Usage: dev/ha-up.sh [--version 26.8.0] [--no-build] [--force]
# Then:  dev/ha-exec.sh ./install && dev/ha-exec.sh ./verify --drill all
# Down:  dev/ha-down.sh            Details: dev/containers/README.md
set -euo pipefail
# shellcheck source=dev/containers/lib.sh
source "$(dirname "$0")/containers/lib.sh"
cd "$HA_ROOT"

VERSION="26.8.0" BUILD=1 FORCE=0
[[ "${HA_SKIP_BUILD:-0}" == "1" ]] && BUILD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)  VERSION="$2"; shift 2 ;;
    --no-build) BUILD=0; shift ;;
    --force)    FORCE=1; shift ;;
    -h|--help)  sed -n '2,5p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done
[[ "$VERSION" =~ ^26\.[0-9]+\.[0-9]+$ ]] || { echo "error: --version must look like 26.x.y" >&2; exit 1; }
ha_require_docker
command -v ssh-keygen >/dev/null || { echo "error: ssh-keygen not found (install the OpenSSH client)" >&2; exit 1; }

# inventory/ is rendered for one cluster at a time. Do not overwrite one that
# belongs to a Multipass (dev/up.sh) or real cluster.
if [[ -f inventory/hosts.yml && ! -f "$HA_STATE_DIR/cluster.yml" && "$FORCE" == 0 ]]; then
  echo "error: inventory/ exists and was not rendered for this rig." >&2
  echo "       Remove it (dev/down.sh for a Multipass cluster) or pass --force to re-render it." >&2
  exit 1
fi

mkdir -p "$HA_STATE_DIR" .dev/dist-cache
if [[ ! -f "$HA_STATE_DIR/id_ed25519" ]]; then
  ssh-keygen -q -t ed25519 -N "" -C "kc-ha rig" -f "$HA_STATE_DIR/id_ed25519"
fi

if [[ "$BUILD" == 1 ]]; then
  ha_group "Build rig images"
  ha_compose build
  ha_endgroup
fi

ha_group "Start containers"
ha_compose up -d --wait --no-build
ha_endgroup

ha_group "Authorize the rig ssh key on every node"
for node in "${HA_NODES[@]}"; do
  ha_compose exec -T "$node" sh -c '
    install -d -m 700 -o ubuntu -g ubuntu /home/ubuntu/.ssh &&
    cat > /home/ubuntu/.ssh/authorized_keys &&
    chown ubuntu:ubuntu /home/ubuntu/.ssh/authorized_keys &&
    chmod 600 /home/ubuntu/.ssh/authorized_keys' < "$HA_STATE_DIR/id_ed25519.pub"
  echo "$node: ok"
done
ha_endgroup

cat > "$HA_STATE_DIR/cluster.yml" <<CFG
---
# Written by dev/ha-up.sh for the container rig (dev/containers/).
cluster_name: keycloak-ha
nodes:
  - host: ${HA_IPS[0]}
    name: ${HA_NODES[0]}
  - host: ${HA_IPS[1]}
    name: ${HA_NODES[1]}
  - host: ${HA_IPS[2]}
    name: ${HA_NODES[2]}
ssh_user: ubuntu
ssh_private_key: /work/.dev/containers/id_ed25519
domain: sso.ha.local
vip: ""
keycloak_version: "$VERSION"
tls_mode: selfsigned
CFG
echo
echo "Cluster definition written to .dev/containers/cluster.yml:"
cat "$HA_STATE_DIR/cluster.yml"
echo

# Nodes get fresh host keys whenever they are recreated; forget the old ones.
ha_control sh -c 'rm -f /root/.ssh/known_hosts'

ha_group "Configure"
ha_control ./configure -c .dev/containers/cluster.yml
ha_endgroup
echo
echo "✓ rig is up. Next: dev/ha-exec.sh ./install"
