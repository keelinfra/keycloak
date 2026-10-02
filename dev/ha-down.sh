#!/usr/bin/env bash
# Tear down the container rig: containers, network, the rendered inventory
# and the rig state. Keeps .dev/dist-cache (downloaded tarballs).
# Usage: dev/ha-down.sh
set -euo pipefail
# shellcheck source=dev/containers/lib.sh
source "$(dirname "$0")/containers/lib.sh"
cd "$HA_ROOT"
ha_require_docker

# ./configure ran as root inside the control container, so on Linux hosts
# inventory/ is root-owned: remove it from where it was written. Only touch
# an inventory this rig rendered.
if [[ -f "$HA_STATE_DIR/cluster.yml" ]]; then
  if [[ -n "$(ha_compose ps -q control 2>/dev/null)" ]]; then
    ha_compose exec -T control rm -rf /work/inventory /work/.dev/containers || true
  fi
  rm -rf inventory "$HA_STATE_DIR" 2>/dev/null \
    || echo "warning: could not remove inventory/ or .dev/containers/ (root-owned?) — remove them by hand" >&2
fi

ha_compose down -v --remove-orphans
echo "✓ rig removed (kept .dev/dist-cache)"
