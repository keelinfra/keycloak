#!/usr/bin/env bash
# Collect diagnostics from every rig node: the journal, unit states,
# listeners, Patroni and HAProxy status. Safe on a half-installed rig.
# Usage: dev/ha-logs.sh [outdir]        (default .dev/containers/artifacts)
set -euo pipefail
# shellcheck source=dev/containers/lib.sh
source "$(dirname "$0")/containers/lib.sh"
cd "$HA_ROOT"
OUT="${1:-$HA_STATE_DIR/artifacts}"
mkdir -p "$OUT"

# ha_node <node> <file> <command...>: run on a node, keep the output.
ha_node() {
  local node="$1" file="$2"; shift 2
  ha_compose exec -T "$node" "$@" > "$OUT/$node/$file" 2>&1 || true
}

for node in "${HA_NODES[@]}"; do
  mkdir -p "$OUT/$node"
  if ! ha_compose exec -T "$node" true >/dev/null 2>&1; then
    echo "$node: not running" | tee "$OUT/$node/NOT-RUNNING"
    continue
  fi
  ha_node "$node" journal.log journalctl --no-pager -o short-iso
  for unit in keycloak patroni etcd haproxy; do
    ha_node "$node" "journal-$unit.log" journalctl --no-pager -o short-iso -u "$unit"
  done
  ha_node "$node" units.txt sh -c 'systemctl --failed --no-pager; echo; systemctl list-units --type=service --no-pager'
  ha_node "$node" listeners.txt ss -tlnp
  ha_node "$node" patroni.txt sh -c 'command -v patronictl >/dev/null && patronictl -c /etc/patroni/config.yml list'
  ha_node "$node" haproxy-stat.csv sh -c 'echo "show stat" | socat stdio /run/haproxy/admin.sock'
  ha_node "$node" system.txt sh -c 'cat /etc/hosts; echo; free -m; echo; df -h /; echo; nproc'
  echo "$node: collected"
done
docker stats --no-stream > "$OUT/docker-stats.txt" 2>&1 || true
ha_compose ps > "$OUT/compose-ps.txt" 2>&1 || true
echo "→ $OUT"
