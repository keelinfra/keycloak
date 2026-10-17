#!/usr/bin/env bash
# Lose a node of the container rig: kill its container and start a fresh one
# with the same name and address, as if the machine had been rebuilt from
# its image. Only the rig ssh key is put back. Then ./replace-node brings it
# back into the cluster.
# Usage: dev/ha-wipe-node.sh kc-node3
set -euo pipefail
# shellcheck source=dev/containers/lib.sh
source "$(dirname "$0")/containers/lib.sh"
NODE="${1:-}"
[[ " ${HA_NODES[*]} " == *" $NODE "* ]] || { sed -n '2,6p' "$0"; exit 1; }

ha_group "Kill $NODE and start a fresh machine in its place"
docker rm -f "$NODE"
ha_compose up -d --wait --no-build "$NODE"
# shellcheck disable=SC2016  # $U expands on the node
ha_compose exec -T -e U="$HA_SSH_USER" "$NODE" sh -c '
  install -d -m 700 -o "$U" -g "$U" "/home/$U/.ssh" &&
  cat > "/home/$U/.ssh/authorized_keys" &&
  chown "$U:$U" "/home/$U/.ssh/authorized_keys" &&
  chmod 600 "/home/$U/.ssh/authorized_keys"' < "$HA_STATE_DIR/id_ed25519.pub"
echo "$NODE: fresh machine up"
ha_endgroup
