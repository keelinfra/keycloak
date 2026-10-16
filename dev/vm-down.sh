#!/usr/bin/env bash
# Tear down the VM rig: the VMs and their disks, the libvirt network, the
# control container, the rendered inventory and the rig state. Keeps the
# downloaded cloud images (.dev/vm-images) and .dev/dist-cache.
# Usage: dev/vm-down.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
STATE="$ROOT/.dev/vm"
DISKS="${VM_DISK_DIR:-$STATE}"
export LIBVIRT_DEFAULT_URI=qemu:///system
for node in kc-vm1 kc-vm2 kc-vm3; do
  if virsh dominfo "$node" >/dev/null 2>&1; then
    virsh destroy "$node" >/dev/null 2>&1 || true
    virsh undefine "$node" --nvram >/dev/null 2>&1 || virsh undefine "$node" >/dev/null
    echo "$node: removed"
  fi
  rm -f "$DISKS/$node.qcow2" "$DISKS/$node-seed.iso"
done
if virsh net-info kc-vm >/dev/null 2>&1; then
  virsh net-destroy kc-vm >/dev/null 2>&1 || true
  virsh net-undefine kc-vm >/dev/null
fi
docker rm -f kc-vm-control >/dev/null 2>&1 || true
# Only remove an inventory this rig rendered.
if [[ -f "$STATE/cluster.yml" ]]; then rm -rf inventory; fi
rm -rf "$STATE"
echo "✓ VM rig removed (kept .dev/vm-images)"
