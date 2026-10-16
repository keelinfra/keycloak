#!/usr/bin/env bash
# Runs inside ubuntu:24.04 (target architecture) for bundle/build.sh.
# Writes /out/repo.tar: a flat apt repository holding the packages in
# bundle/packages.txt and their whole dependency tree, resolved as if
# nothing were installed, so it serves a minimal node as well as a full one.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates curl gnupg apt-utils >/dev/null

# The same third-party repositories the roles add (roles/postgres, roles/monitoring).
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/keyrings/pgdg.gpg
curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg
cat > /etc/apt/sources.list.d/keelinfra-build.sources <<SRC
Types: deb
URIs: https://apt.postgresql.org/pub/repos/apt
Suites: noble-pgdg
Components: main
Signed-By: /etc/apt/keyrings/pgdg.gpg

Types: deb
URIs: https://apt.grafana.com
Suites: stable
Components: main
Signed-By: /etc/apt/keyrings/grafana.gpg
SRC
apt-get update -qq

pg_version="$(sed -n 's/^postgres_version: *\([0-9]*\).*/\1/p' /src/playbooks/group_vars/all.yml)"
[[ -n "$pg_version" ]] || { echo "error: postgres_version not found in playbooks/group_vars/all.yml" >&2; exit 1; }
mapfile -t pkgs < <(grep -v '^\s*\(#\|$\)' /src/bundle/packages.txt)
pkgs+=("postgresql-$pg_version")

# An empty dpkg status makes apt resolve and download the full tree,
# recommends included, exactly as an install on an empty system would.
mkdir -p /tmp/empty /out/repo
: > /tmp/empty/status
apt-get install -y -qq --download-only \
  -o Dir::State::status=/tmp/empty/status \
  -o Dir::Cache::archives=/out/repo \
  -o APT::Install-Recommends=true \
  "${pkgs[@]}" >/dev/null
rm -rf /out/repo/partial /out/repo/lock

cd /out/repo
apt-ftparchive packages . > Packages
gzip -9k Packages
apt-ftparchive \
  -o APT::FTPArchive::Release::Origin=keelinfra-offline \
  -o APT::FTPArchive::Release::Label=keelinfra-offline \
  -o APT::FTPArchive::Release::Suite=noble \
  -o APT::FTPArchive::Release::Codename=noble \
  -o APT::FTPArchive::Release::Architectures="$(dpkg --print-architecture) all" \
  release . > Release
cd /out
tar -cf repo.tar -C repo .
echo "$(find repo -name '*.deb' | wc -l) packages, $(du -sh repo | cut -f1)"
rm -rf repo
printf '%s\n' "${pkgs[@]}" > /out/packages.txt
