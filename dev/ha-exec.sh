#!/usr/bin/env bash
# Run a command in the rig's control container, from the repo root (/work).
# Usage: dev/ha-exec.sh ./install
#        dev/ha-exec.sh ./verify --drill all
#        dev/ha-exec.sh ./upgrade --to 26.8.0
#        dev/ha-exec.sh bash                      # a shell on the control node
# ANSIBLE_* variables are passed through (e.g. ANSIBLE_VERBOSITY=2).
set -euo pipefail
# shellcheck source=dev/containers/lib.sh
source "$(dirname "$0")/containers/lib.sh"
[[ $# -gt 0 ]] || { sed -n '2,7p' "$0"; exit 1; }
ha_control "$@"
