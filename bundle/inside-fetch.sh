#!/usr/bin/env bash
# Runs inside ubuntu:24.04 for bundle/build.sh. Downloads the release
# artifacts the roles fetch with get_url (Keycloak, etcd, keycloak-config-cli)
# into /out/dist and the Ansible collections into /out/collections, then
# writes /out/bundle.yml. Versions are read from the roles, so a bundle
# always matches the checkout that built it.
# Env: VERSION, ARCH, DIST_URL.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates curl python3-venv >/dev/null
python3 -m venv /tmp/venv
/tmp/venv/bin/pip install -q ansible-core pyyaml

mkdir -p /out/dist /out/collections
get() { curl -fsSL --retry 4 -o "$2" "$1"; }

# Keycloak: the upstream tarball, or the LTS build passed with --dist-url.
kc_file="$(basename "$DIST_URL")"
get "$DIST_URL" "/out/dist/$kc_file"
if curl -fsSL -o /tmp/kc.sha1 "$DIST_URL.sha1" 2>/dev/null; then
  echo "$(cut -d' ' -f1 /tmp/kc.sha1)  /out/dist/$kc_file" | sha1sum -c --quiet
fi

# etcd, checked against the release's SHA256SUMS.
etcd_version="$(sed -n 's/^etcd_version: *"\{0,1\}\([0-9.]*\).*/\1/p' /src/roles/etcd/defaults/main.yml)"
etcd_file="etcd-v$etcd_version-linux-$ARCH.tar.gz"
etcd_base="https://github.com/etcd-io/etcd/releases/download/v$etcd_version"
get "$etcd_base/$etcd_file" "/out/dist/$etcd_file"
get "$etcd_base/SHA256SUMS" /tmp/etcd.sums
(cd /out/dist && grep " $etcd_file\$" /tmp/etcd.sums | sha256sum -c --quiet)

# keycloak-config-cli: let Ansible evaluate the role's own expression for
# the jar URL, so the pick (newest build not newer than Keycloak) cannot drift.
cli_url="$(cd /src && ANSIBLE_LOCALHOST_WARNING=False /tmp/venv/bin/ansible localhost -c local \
  -e "keycloak_version=$VERSION" -e @roles/config_cli/defaults/main.yml \
  -m ansible.builtin.debug -a 'msg={{ config_cli_jar_url }}' 2>/dev/null \
  | sed -n 's/.*"msg": "\(.*\)".*/\1/p')"
[[ "$cli_url" == https://* ]] || { echo "error: could not resolve config_cli_jar_url" >&2; exit 1; }
get "$cli_url" "/out/dist/$(basename "$cli_url")"

# Collections for the control node (./configure installs them with --offline).
/tmp/venv/bin/ansible-galaxy collection download -r /src/requirements.yml -p /out/collections >/dev/null

repo_sha="$(sha256sum /out/repo.tar | cut -d' ' -f1)"
cat > /out/bundle.yml <<YML
---
# keelinfra/keycloak offline bundle — read by ./configure and roles/common.
format: 1
os: ubuntu24.04
codename: noble
arch: $ARCH
keycloak_version: "$VERSION"
keycloak_dist: "$kc_file"
etcd_version: "$etcd_version"
config_cli_jar: "$(basename "$cli_url")"
repo_id: "$repo_sha"
built: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
YML
(cd /out && find . -type f -printf '%P\n' | LC_ALL=C sort | xargs sha256sum > /tmp/SHA256SUMS)
mv /tmp/SHA256SUMS /out/SHA256SUMS
ls -la /out/dist
