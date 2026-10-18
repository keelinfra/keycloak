#!/usr/bin/env bash
# Bring up the 3-node container rig and configure the repo against it.
# Usage: dev/ha-up.sh [--version 26.8.1] [--os ubuntu24.04|rocky9|alma9] [--no-build] [--force]
#                     [--offline <bundle.tar.gz>] [--domain sso.ha.local] [--publish PORT]
# --offline cuts the nodes off from the internet and configures from a bundle
# (bundle/build.sh); the bundle must sit inside the repo, which the control
# container sees as /work. --publish maps kc-node1's HTTPS to 127.0.0.1:PORT
# on this machine (./try uses it with --domain localhost).
# Then:  dev/ha-exec.sh ./install && dev/ha-exec.sh ./verify --drill all
# Down:  dev/ha-down.sh            Details: dev/containers/README.md
set -euo pipefail
# --os goes to lib.sh, which picks the node image and ssh user from it.
for ((i = 1; i < $#; i++)); do
  if [[ "${!i}" == --os ]]; then j=$((i + 1)); export HA_OS="${!j}"; fi
done
# shellcheck source=dev/containers/lib.sh
source "$(dirname "$0")/containers/lib.sh"
cd "$HA_ROOT"

VERSION="26.8.1" BUILD=1 FORCE=0 OFFLINE="" DOMAIN="sso.ha.local" PUBLISH=""
[[ "${HA_SKIP_BUILD:-0}" == "1" ]] && BUILD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)  VERSION="$2"; shift 2 ;;
    --no-build) BUILD=0; shift ;;
    --force)    FORCE=1; shift ;;
    --offline)  OFFLINE="$2"; shift 2 ;;
    --os)       HA_OS="$2"; shift 2 ;;
    --domain)   DOMAIN="$2"; shift 2 ;;
    --publish)  PUBLISH="$2"; shift 2 ;;
    -h|--help)  sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done
[[ "$VERSION" =~ ^26\.[0-9]+\.[0-9]+$ ]] || { echo "error: --version must look like 26.x.y" >&2; exit 1; }
[[ -z "$PUBLISH" || "$PUBLISH" =~ ^[0-9]+$ ]] || { echo "error: --publish must be a port number" >&2; exit 1; }
HA_PUBLISH="$PUBLISH"
ha_require_docker
if [[ -n "$OFFLINE" ]]; then
  [[ -f "$OFFLINE" ]] || { echo "error: offline bundle not found: $OFFLINE" >&2; exit 1; }
  OFFLINE_ABS="$(cd "$(dirname "$OFFLINE")" && pwd)/$(basename "$OFFLINE")"
  [[ "$OFFLINE_ABS" == "$HA_ROOT"/* ]] || { echo "error: the bundle must be inside the repo ($HA_ROOT)" >&2; exit 1; }
  OFFLINE_WORK="/work/${OFFLINE_ABS#"$HA_ROOT"/}"
fi

# inventory/ is rendered for one cluster at a time. Do not overwrite one that
# belongs to a Multipass (dev/up.sh) or real cluster.
if [[ -f inventory/hosts.yml && ! -f "$HA_STATE_DIR/cluster.yml" && "$FORCE" == 0 ]]; then
  echo "error: inventory/ exists and was not rendered for this rig." >&2
  echo "       Remove it (dev/down.sh for a Multipass cluster) or pass --force to re-render it." >&2
  exit 1
fi

mkdir -p "$HA_STATE_DIR" .dev/dist-cache
echo "$HA_OS" > "$HA_STATE_DIR/os"
if [[ -n "$PUBLISH" ]]; then echo "$PUBLISH" > "$HA_STATE_DIR/publish"; else rm -f "$HA_STATE_DIR/publish"; fi

if [[ "$BUILD" == 1 ]]; then
  ha_group "Build rig images"
  ha_compose build
  ha_endgroup
fi

ha_group "Start containers"
ha_compose up -d --wait --no-build
ha_endgroup

# Made in the control container, so this machine needs no ssh client.
ha_control sh -c '[ -f .dev/containers/id_ed25519 ] || ssh-keygen -q -t ed25519 -N "" -C "kc-ha rig" -f .dev/containers/id_ed25519'

ha_group "Start the S3 bucket and alert webhook stand-ins"
ha_control dev/containers/services-up.sh "$HA_CONTROL_IP"
ha_endgroup

ha_group "Authorize the rig ssh key on every node"
for node in "${HA_NODES[@]}"; do
  # shellcheck disable=SC2016  # $U expands on the node
  ha_compose exec -T -e U="$HA_SSH_USER" "$node" sh -c '
    install -d -m 700 -o "$U" -g "$U" "/home/$U/.ssh" &&
    cat > "/home/$U/.ssh/authorized_keys" &&
    chown "$U:$U" "/home/$U/.ssh/authorized_keys" &&
    chmod 600 "/home/$U/.ssh/authorized_keys"' < "$HA_STATE_DIR/id_ed25519.pub"
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
ssh_user: $HA_SSH_USER
ssh_private_key: /work/.dev/containers/id_ed25519
domain: $DOMAIN
vip: ""
keycloak_version: "$VERSION"
tls_mode: selfsigned
# Off-site backup copy and alert routing, to the stand-ins in the control
# container (dev/containers/services-up.sh).
backup_s3:
  endpoint: kc-s3:9000
  region: us-east-1
  bucket: kc-backups
  uri_style: path
  ca_file: s3/ca.crt
alerting:
  webhook_url: http://$HA_CONTROL_IP:9095/
CFG
echo
echo "Cluster definition written to .dev/containers/cluster.yml:"
cat "$HA_STATE_DIR/cluster.yml"
echo

if [[ -n "$OFFLINE" ]]; then
  ha_group "Cut the nodes off from the internet"
  # The nodes keep their rig subnet (each other, the control container) and
  # lose the default route: nothing outside the rig is reachable. A
  # container restart brings the route back.
  for node in "${HA_NODES[@]}"; do
    ha_compose exec -T "$node" sh -c 'ip route del default 2>/dev/null || true'
    if ha_compose exec -T "$node" curl -fsS -m 5 -o /dev/null https://github.com 2>/dev/null; then
      echo "error: $node still reaches the internet" >&2; exit 1
    fi
    echo "$node: offline"
  done
  ha_endgroup
fi

# Nodes get fresh host keys whenever they are recreated; forget the old ones.
ha_control sh -c 'rm -f /root/.ssh/known_hosts'

ha_group "Configure"
# The stand-in bucket accepts any credentials.
if ! ha_compose exec -T -w /work -e KEELINFRA_S3_ACCESS_KEY=rig -e KEELINFRA_S3_SECRET_KEY=rig-secret \
  control ./configure -c .dev/containers/cluster.yml ${OFFLINE:+--offline "$OFFLINE_WORK"}; then
  # Most rig failures here are ssh logins the nodes refused; show why.
  for node in "${HA_NODES[@]}"; do
    echo "--- $node: sshd log"
    ha_compose exec -T "$node" journalctl --no-pager -n 25 -u ssh -u sshd || true
  done
  exit 1
fi
ha_endgroup
echo
echo "✓ rig is up. Next: dev/ha-exec.sh ./install"
