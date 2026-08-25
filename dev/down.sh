#!/usr/bin/env bash
# Tear down the local dev cluster and its generated inventory.
set -euo pipefail
cd "$(dirname "$0")/.."
for name in kc-dev1 kc-dev2 kc-dev3; do
  if multipass info "$name" >/dev/null 2>&1; then
    echo "→ deleting $name"
    multipass delete --purge "$name"
  fi
done
rm -rf inventory .dev
echo "✓ dev cluster removed"
