#!/bin/sh
# Builds a RHEL-family 9 rig node (Rocky Linux, AlmaLinux) from its
# container image: what the GenericCloud image ships and the roles rely on,
# plus systemd and sshd. Run by dev/containers/Dockerfile.
# Usage: el9-node.sh <cloud-image user>   (rocky, almalinux)
set -eu
user="$1"
dnf -y install --setopt=install_weak_deps=False \
  systemd openssh-server openssh-clients sudo cronie \
  python3 python3-libselinux ca-certificates iproute procps-ng tar
dnf clean all
# Same reasons as for the Ubuntu node: chronyd stays off in containers, and
# every container gets its own host keys (sshd-keygen makes them at boot).
systemctl mask chronyd.service
systemctl enable sshd.service
rm -f /etc/ssh/ssh_host_*
# useradd leaves the account locked ("!!"), which sshd on this family
# refuses even for key logins; cloud-init unlocks it the same way ("*").
# pam_loginuid cannot write the audit login uid in a container, and
# pam_unix's account check cannot read /etc/shadow through its helper here
# ("could not obtain user info"); broken_shadow skips that read. Rig only.
useradd -m -s /bin/bash "$user"
usermod -p '*' "$user"
echo "$user ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$user"
chmod 440 "/etc/sudoers.d/90-$user"
sed -i 's/^session\s\+required\s\+pam_loginuid.so/session optional pam_loginuid.so/' /etc/pam.d/sshd
for f in /etc/pam.d/password-auth /etc/pam.d/system-auth; do
  sed -i 's/^\(account\s\+required\s\+pam_unix.so\)\(.*\)$/\1\2 broken_shadow/' "$(readlink -f "$f")"
done
: > /etc/machine-id
