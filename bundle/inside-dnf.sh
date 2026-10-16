#!/usr/bin/env bash
# Runs inside rockylinux/rockylinux:9 (target architecture) for bundle/build.sh.
# Writes /out/repo.tar: a dnf repository holding the packages in
# bundle/packages-rocky9.txt and their whole dependency tree, resolved
# against an empty installroot, so it serves a minimal node as well as a
# full one.
set -euo pipefail

dnf -q -y install createrepo_c epel-release >/dev/null

# The same third-party repositories the roles add (roles/postgres, roles/monitoring).
pg_version="$(sed -n 's/^postgres_version: *\([0-9]*\).*/\1/p' /src/playbooks/group_vars/all.yml)"
[[ -n "$pg_version" ]] || { echo "error: postgres_version not found in playbooks/group_vars/all.yml" >&2; exit 1; }
cat > /etc/yum.repos.d/keelinfra-build.repo <<REPO
[pgdg$pg_version]
name=PostgreSQL $pg_version
baseurl=https://download.postgresql.org/pub/repos/yum/$pg_version/redhat/rhel-\$releasever-\$basearch
gpgcheck=1
gpgkey=https://download.postgresql.org/pub/repos/yum/keys/PGDG-RPM-GPG-KEY-RHEL

[pgdg-common]
name=PostgreSQL common
baseurl=https://download.postgresql.org/pub/repos/yum/common/redhat/rhel-\$releasever-\$basearch
gpgcheck=1
gpgkey=https://download.postgresql.org/pub/repos/yum/keys/PGDG-RPM-GPG-KEY-RHEL

[grafana]
name=Grafana
baseurl=https://rpm.grafana.com
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
REPO

mapfile -t pkgs < <(grep -v '^\s*\(#\|$\)' /src/bundle/packages-rocky9.txt)
pkgs+=("postgresql$pg_version-server" "postgresql$pg_version-contrib")

# An empty installroot makes dnf resolve and download the full tree, weak
# dependencies included, exactly as an install on an empty system would.
# --nogpgcheck only skips the rpmdb key import into the empty root: every
# package is still checked against its repository's signed metadata.
mkdir -p /tmp/empty /out/repo
dnf -q -y install --downloadonly --downloaddir=/out/repo \
  --installroot=/tmp/empty --releasever=9 \
  --setopt=reposdir=/etc/yum.repos.d --setopt=varsdir=/etc/dnf/vars \
  --setopt=cachedir=/var/cache/dnf \
  --setopt=install_weak_deps=True --nogpgcheck \
  "${pkgs[@]}" >/dev/null

createrepo_c -q /out/repo
cd /out
tar -cf repo.tar -C repo .
echo "$(find repo -name '*.rpm' | wc -l) packages, $(du -sh repo | cut -f1)"
rm -rf repo
printf '%s\n' "${pkgs[@]}" > /out/packages.txt
