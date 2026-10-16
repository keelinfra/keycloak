#!/usr/bin/env bash
# Bring up three real VMs (KVM/libvirt) and configure the repo against them.
# Usage: dev/vm-up.sh [--os rocky9|ubuntu24.04] [--version 26.8.1] [--mem 4096] [--cpus 2]
# Then:  dev/vm-exec.sh ./install && dev/vm-exec.sh ./verify --drill all
# Down:  dev/vm-down.sh
#
# What the container rig (dev/ha-up.sh) cannot show: SELinux enforcing (Rocky
# images ship it on), a real kernel for sysctl, chrony, hostnames, and a
# keepalived VIP. The nodes are the distributions' own cloud images, booted
# with cloud-init on a libvirt network (192.168.123.0/24, VIP .10). Ansible
# runs from the rig's control container on the host network, which also
# serves the S3 and webhook stand-ins to the VMs at 192.168.123.1.
# Needs: Linux with /dev/kvm, libvirt (virsh, virt-install), qemu-img,
# cloud-localds (cloud-image-utils), docker, ssh-keygen. VM_DISK_DIR moves the
# disks somewhere QEMU may read (default .dev/vm; CI uses /var/lib/libvirt/images).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
STATE="$ROOT/.dev/vm"
IMAGES="$ROOT/.dev/vm-images"
DISKS="${VM_DISK_DIR:-$STATE}"
NET=kc-vm
PREFIX=192.168.123
NODES=(kc-vm1 kc-vm2 kc-vm3)
CONTROL=kc-vm-control
export LIBVIRT_DEFAULT_URI=qemu:///system

OS=rocky9 VERSION=26.8.1 MEM=4096 CPUS=2
while [[ $# -gt 0 ]]; do
  case "$1" in
    --os)      OS="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --mem)     MEM="$2"; shift 2 ;;
    --cpus)    CPUS="$2"; shift 2 ;;
    -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done
case "$OS" in
  rocky9)
    IMAGE_URL=https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2
    SSH_USER=rocky
    # Under SeaBIOS the image never reaches its bootloader (no serial output,
    # no DHCP request); it boots with UEFI firmware (OVMF).
    BOOT=(--boot uefi) ;;
  ubuntu24.04)
    IMAGE_URL=https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
    SSH_USER=ubuntu
    BOOT=() ;;
  *) echo "error: --os must be rocky9 or ubuntu24.04" >&2; exit 1 ;;
esac
[[ "$VERSION" =~ ^26\.[0-9]+\.[0-9]+$ ]] || { echo "error: --version must look like 26.x.y" >&2; exit 1; }
for tool in virsh virt-install qemu-img cloud-localds docker ssh-keygen; do
  command -v "$tool" >/dev/null || { echo "error: $tool not found" >&2; exit 1; }
done
[[ -w /dev/kvm ]] || { echo "error: /dev/kvm is missing or not writable" >&2; exit 1; }
if [[ -f inventory/hosts.yml && ! -f "$STATE/cluster.yml" ]]; then
  echo "error: inventory/ exists and was not rendered for this rig; remove it first." >&2
  exit 1
fi

group() { if [[ -n "${GITHUB_ACTIONS:-}" ]]; then echo "::group::$*"; else echo; echo "### $*"; fi; }
endgroup() { [[ -z "${GITHUB_ACTIONS:-}" ]] || echo "::endgroup::"; }

mkdir -p "$STATE" "$IMAGES" "$DISKS" .dev/dist-cache
echo "$OS" > "$STATE/os"
[[ -f "$STATE/id_ed25519" ]] || ssh-keygen -q -t ed25519 -N "" -C "kc-vm rig" -f "$STATE/id_ed25519"

group "Cloud image ($OS)"
# Re-download once a day: the images are rebuilt with security updates.
CACHED="$IMAGES/$(basename "$IMAGE_URL")"
BASE="$DISKS/$(basename "$IMAGE_URL")"
if [[ ! -f "$CACHED" || -n "$(find "$CACHED" -mtime +0 2>/dev/null)" ]]; then
  curl -fL --retry 3 -o "$IMAGES/image.part" "$IMAGE_URL"
  mv "$IMAGES/image.part" "$CACHED"
fi
# The overlays below are backed by this copy, next to them where QEMU can read it.
cp -u "$CACHED" "$BASE"
ls -la "$BASE"
endgroup

group "libvirt network $NET ($PREFIX.0/24)"
if ! virsh net-info "$NET" >/dev/null 2>&1; then
  {
    echo "<network><name>$NET</name><forward mode='nat'/>"
    echo "<bridge name='virbr-kc' stp='on' delay='0'/>"
    echo "<ip address='$PREFIX.1' netmask='255.255.255.0'><dhcp>"
    echo "<range start='$PREFIX.100' end='$PREFIX.200'/>"
    for i in 1 2 3; do echo "<host mac='52:54:00:6b:00:1$i' ip='$PREFIX.1$i'/>"; done
    echo "</dhcp></ip></network>"
  } > "$STATE/network.xml"
  virsh net-define "$STATE/network.xml"
fi
virsh net-info "$NET" | grep -q 'Active:.*yes' || virsh net-start "$NET"
# Docker's FORWARD policy drops traffic it does not know; let the VMs out.
if sudo -n iptables -L DOCKER-USER >/dev/null 2>&1; then
  for dir in -i -o; do
    sudo -n iptables -C DOCKER-USER "$dir" virbr-kc -j ACCEPT 2>/dev/null \
      || sudo -n iptables -I DOCKER-USER "$dir" virbr-kc -j ACCEPT
  done
fi
endgroup

group "Boot ${NODES[*]}"
for i in 1 2 3; do
  node="${NODES[$((i - 1))]}"
  if virsh dominfo "$node" >/dev/null 2>&1; then echo "$node: exists"; continue; fi
  qemu-img create -q -f qcow2 -F qcow2 -b "$BASE" "$DISKS/$node.qcow2" 20G
  cat > "$STATE/$node-user-data" <<CLOUD
#cloud-config
hostname: $node
manage_etc_hosts: false
ssh_authorized_keys:
  - $(cat "$STATE/id_ed25519.pub")
bootcmd:
  - grep -q kc-s3 /etc/hosts || echo "$PREFIX.1 kc-s3" >> /etc/hosts
CLOUD
  printf 'instance-id: %s\nlocal-hostname: %s\n' "$node-$(date +%s)" "$node" > "$STATE/$node-meta-data"
  cloud-localds "$DISKS/$node-seed.iso" "$STATE/$node-user-data" "$STATE/$node-meta-data"
  virt-install --name "$node" --memory "$MEM" --vcpus "$CPUS" --cpu host-passthrough \
    --import --disk "path=$DISKS/$node.qcow2,bus=virtio" \
    --disk "path=$DISKS/$node-seed.iso,device=cdrom" \
    --network "network=$NET,mac=52:54:00:6b:00:1$i,model=virtio" \
    --osinfo detect=on,require=off --graphics none \
    --serial "file,path=$DISKS/$node-console.log" \
    "${BOOT[@]}" --noautoconsole
done
for i in 1 2 3; do
  node="${NODES[$((i - 1))]}" ip="$PREFIX.1$i"
  for attempt in $(seq 1 90); do
    if ssh -q -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no \
         -o UserKnownHostsFile=/dev/null -i "$STATE/id_ed25519" "$SSH_USER@$ip" \
         'cloud-init status --wait >/dev/null 2>&1; sudo -n true'; then
      echo "$node ($ip): up"; break
    fi
    if [[ "$attempt" == 90 ]]; then
      echo "error: $node did not come up. DHCP leases and the end of its serial console:" >&2
      virsh net-dhcp-leases "$NET" >&2 || true
      virsh domstate --reason "$node" >&2 || true
      if [[ -s "$DISKS/$node-console.log" ]]; then tail -n 80 "$DISKS/$node-console.log" >&2
      else echo "(the serial console is empty: the firmware never handed over to the bootloader)" >&2; fi
      exit 1
    fi
    sleep 5
  done
done
endgroup

group "Control container and the S3 / webhook stand-ins"
docker image inspect kc-ha-control:local >/dev/null 2>&1 \
  || docker compose -f dev/containers/compose.yml build control
if [[ -z "$(docker ps -q -f "name=^$CONTROL$")" ]]; then
  docker rm -f "$CONTROL" >/dev/null 2>&1 || true
  docker run -d --name "$CONTROL" --network host --add-host kc-s3:127.0.0.1 --init \
    -v "$ROOT:/work" -v "$ROOT/.dev/dist-cache:/dist" -w /work \
    kc-ha-control:local sleep infinity >/dev/null
fi
docker exec "$CONTROL" rm -f /root/.ssh/known_hosts
docker exec "$CONTROL" dev/containers/services-up.sh "$PREFIX.1" /work/.dev/vm
endgroup

cat > "$STATE/cluster.yml" <<CFG
---
# Written by dev/vm-up.sh for the VM rig.
cluster_name: keycloak-vm
nodes:
  - host: $PREFIX.11
    name: ${NODES[0]}
  - host: $PREFIX.12
    name: ${NODES[1]}
  - host: $PREFIX.13
    name: ${NODES[2]}
ssh_user: $SSH_USER
ssh_private_key: /work/.dev/vm/id_ed25519
domain: sso.vm.local
vip: "$PREFIX.10"
keycloak_version: "$VERSION"
tls_mode: selfsigned
backup_s3:
  endpoint: kc-s3:9000
  region: us-east-1
  bucket: kc-backups
  uri_style: path
  ca_file: s3/ca.crt
alerting:
  webhook_url: http://$PREFIX.1:9095/
CFG

group "Configure"
docker exec -w /work -e KEELINFRA_S3_ACCESS_KEY=rig -e KEELINFRA_S3_SECRET_KEY=rig-secret \
  "$CONTROL" ./configure -c .dev/vm/cluster.yml
endgroup
echo
echo "✓ VMs are up ($OS). Next: dev/vm-exec.sh ./install"
