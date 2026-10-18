# shellcheck shell=bash
# shellcheck disable=SC2034  # the variables below are used by the sourcing scripts
# Shared by dev/ha-*.sh — source it, do not run it.
# Paths, the compose invocation, the node table and a few output helpers.

HA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HA_COMPOSE_FILE="$HA_ROOT/dev/containers/compose.yml"
HA_STATE_DIR="$HA_ROOT/.dev/containers"
HA_PREFIX="${HA_PREFIX:-172.28.0}"
export HA_PREFIX
HA_NODES=(kc-node1 kc-node2 kc-node3)
HA_IPS=("$HA_PREFIX.11" "$HA_PREFIX.12" "$HA_PREFIX.13")
HA_CONTROL_IP="$HA_PREFIX.2"

# Node OS: ubuntu24.04 (default), rocky9 or alma9. dev/ha-up.sh --os records it, so
# the other scripts act on the rig as it was started.
HA_OS="${HA_OS:-$(cat "$HA_STATE_DIR/os" 2>/dev/null || echo ubuntu24.04)}"
case "$HA_OS" in
  ubuntu24.04) HA_NODE_TARGET=node;        HA_SSH_USER=ubuntu ;;
  rocky9)      HA_NODE_TARGET=node-rocky9; HA_SSH_USER=rocky ;;
  alma9)       HA_NODE_TARGET=node-alma9;  HA_SSH_USER=almalinux ;;
  *) echo "error: unknown node OS '$HA_OS' (ubuntu24.04, rocky9 or alma9)" >&2; exit 1 ;;
esac
export HA_NODE_TARGET

# Host port mapped to kc-node1's HTTPS (dev/ha-up.sh --publish, used by ./try).
HA_PUBLISH="${HA_PUBLISH:-$(cat "$HA_STATE_DIR/publish" 2>/dev/null || true)}"

ha_compose() {
  local files=(-f "$HA_COMPOSE_FILE")
  [[ -z "${HA_PUBLISH:-}" ]] || files+=(-f "$HA_ROOT/dev/containers/publish.yml")
  HA_PUBLISH="${HA_PUBLISH:-}" docker compose "${files[@]}" "$@"
}

# Run a command in the control container, in /work (the repo root).
# ANSIBLE_* variables from the caller's environment are passed through.
ha_control() {
  local args=(exec -w /work) v
  [[ -t 0 && -t 1 ]] || args+=(-T)
  for v in $(compgen -e | grep '^ANSIBLE_' || true); do args+=(-e "$v=${!v}"); done
  ha_compose "${args[@]}" control "$@"
}

ha_require_docker() {
  command -v docker >/dev/null || { echo "error: docker not found" >&2; exit 1; }
  docker compose version >/dev/null 2>&1 || { echo "error: the docker compose v2 plugin is required" >&2; exit 1; }
}

# Collapsible log groups on GitHub Actions, plain headings elsewhere — and
# plain headings too when a caller already holds a group open (HA_NESTED=1,
# set by dev/ha-drill.sh for dev/ha-up.sh), since Actions groups do not nest.
ha_group() {
  if [[ -n "${GITHUB_ACTIONS:-}" && -z "${HA_NESTED:-}" ]]; then echo "::group::$*"; else echo; echo "### $*"; fi
}
ha_endgroup() { [[ -z "${GITHUB_ACTIONS:-}" || -n "${HA_NESTED:-}" ]] || echo "::endgroup::"; }
