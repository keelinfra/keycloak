#!/usr/bin/env bash
# Run a command in the VM rig's control container, from the repo root (/work).
# Usage: dev/vm-exec.sh ./install
#        dev/vm-exec.sh ./verify --drill all
#        dev/vm-exec.sh bash
# ANSIBLE_* variables are passed through (e.g. ANSIBLE_VERBOSITY=2).
set -euo pipefail
[[ $# -gt 0 ]] || { sed -n '2,6p' "$0"; exit 1; }
args=(exec -w /work)
[[ -t 0 && -t 1 ]] && args+=(-it)
for v in $(compgen -e | grep '^ANSIBLE_' || true); do args+=(-e "$v=${!v}"); done
exec docker "${args[@]}" kc-vm-control "$@"
