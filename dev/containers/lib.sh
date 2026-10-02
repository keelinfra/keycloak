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

ha_compose() { docker compose -f "$HA_COMPOSE_FILE" "$@"; }

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

# Collapsible log groups on GitHub Actions, plain headings elsewhere.
ha_group() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then echo "::group::$*"; else echo; echo "### $*"; fi
}
ha_endgroup() { [[ -z "${GITHUB_ACTIONS:-}" ]] || echo "::endgroup::"; }
