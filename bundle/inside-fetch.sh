#!/usr/bin/env bash
# Runs inside ubuntu:24.04 for bundle/build.sh. Downloads the release
# artifacts the roles fetch with get_url (Keycloak, etcd, keycloak-config-cli,
# and on Rocky Linux the Prometheus tools) into /out/dist and the Ansible collections into /out/collections, then
# writes /out/bundle.yml. Versions are read from the roles, so a bundle
# always matches the checkout that built it.
# Env: VERSION, OS, ARCH, DIST_URL.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates curl python3-venv >/dev/null
python3 -m venv /tmp/venv
/tmp/venv/bin/pip install -q ansible-core pyyaml

mkdir -p /out/dist /out/collections
get() { curl -fsSL --retry 4 -o "$2" "$1"; }

# Keycloak: the upstream tarball or the LTS build passed with --dist-url,
# checked as roles/keycloak checks it online (keycloak_dist_checksum: an
# algorithm, then a digest or the URL of a checksum file).
kc_file="$(basename "$DIST_URL")"
get "$DIST_URL" "/out/dist/$kc_file"
kc_sum="$(cd /src && ANSIBLE_LOCALHOST_WARNING=False /tmp/venv/bin/ansible localhost -c local \
  -e @roles/keycloak/defaults/main.yml -e "keycloak_version=$VERSION" -e "keycloak_dist_url=$DIST_URL" \
  -m ansible.builtin.debug -a 'msg={{ keycloak_dist_checksum }}' 2>/dev/null \
  | sed -n 's/.*"msg": "\(.*\)".*/\1/p')"
kc_algo="${kc_sum%%:*}" kc_digest="${kc_sum#*:}"
[[ "$kc_algo" =~ ^sha(1|256|512)$ ]] || { echo "error: could not resolve keycloak_dist_checksum" >&2; exit 1; }
if [[ "$kc_digest" == http*://* ]]; then
  get "$kc_digest" /tmp/kc.sums
  # A bare digest, or "<digest>  <file>" lines.
  if [[ "$(wc -w < /tmp/kc.sums)" -eq 1 ]]; then kc_digest="$(cat /tmp/kc.sums)"
  else kc_digest="$(grep " $kc_file\$" /tmp/kc.sums | cut -d' ' -f1)"; fi
fi
echo "$kc_digest  /out/dist/$kc_file" | "${kc_algo}sum" -c --quiet

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
cli_file="$(basename "$cli_url")"
get "$cli_url" "/out/dist/$cli_file"
get "$cli_url.sha256" /tmp/cli.sums
(cd /out/dist && grep " $cli_file\$" /tmp/cli.sums | sha256sum -c --quiet)

# Rocky Linux packages none of the Prometheus tools; roles/monitoring
# installs the upstream releases listed in its defaults. Each is checked
# against its release's sha256sums.txt.
if [[ "$OS" == rocky9 ]]; then
  while read -r rel_repo rel_version; do
    file="$(basename "$rel_repo")-$rel_version.linux-$ARCH.tar.gz"
    base="https://github.com/$rel_repo/releases/download/v$rel_version"
    get "$base/$file" "/out/dist/$file"
    get "$base/sha256sums.txt" /tmp/release.sums
    (cd /out/dist && grep " $file\$" /tmp/release.sums | sha256sum -c --quiet)
  done < <(cd /src && ANSIBLE_LOCALHOST_WARNING=False /tmp/venv/bin/ansible localhost -c local \
    -e @roles/monitoring/defaults/main.yml -m ansible.builtin.debug \
    -a "msg={{ monitoring_releases.values() | map(attribute='repo') | zip(monitoring_releases.values() | map(attribute='version')) | map('join', ' ') | join(';') }}" \
    2>/dev/null | sed -n 's/.*"msg": "\(.*\)".*/\1/p' | tr ';' '\n')
  [[ "$(find /out/dist -name 'prometheus-*' | wc -l)" -eq 1 ]] \
    || { echo "error: could not resolve the Prometheus releases from roles/monitoring" >&2; exit 1; }
fi

# Collections for the control node (./configure installs them with --offline).
/tmp/venv/bin/ansible-galaxy collection download -r /src/requirements.yml -p /out/collections >/dev/null

repo_sha="$(sha256sum /out/repo.tar | cut -d' ' -f1)"
cat > /out/bundle.yml <<YML
---
# keelinfra/keycloak offline bundle — read by ./configure and roles/common.
format: 1
os: $OS
family: $([[ "$OS" == rocky9 ]] && echo redhat || echo debian)
codename: $([[ "$OS" == rocky9 ]] && echo '"9"' || echo noble)
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
