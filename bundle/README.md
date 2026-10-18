# Offline bundles

For nodes with no internet access. An offline bundle is one tarball holding
everything `./install` and `./upgrade` otherwise download: the packages
(apt on Ubuntu 24.04, dnf on Rocky Linux 9) with their whole dependency tree, the Keycloak distribution, etcd,
keycloak-config-cli, and the Ansible collections for the control node.

## Build one

On any machine with Docker and internet access:

```bash
bundle/build.sh --version 26.8.1                 # Ubuntu 24.04, amd64, upstream Keycloak
bundle/build.sh --version 26.8.1 --os rocky9     # Rocky Linux 9 nodes
bundle/build.sh --version 26.8.1 --arch arm64    # for arm64 nodes (needs qemu binfmt on an amd64 host)
bundle/build.sh --version 26.2.16 \
  --dist-url https://github.com/keelinfra/keycloak/releases/download/kc-26.2.16-keel1/keycloak-26.2.16.tar.gz
```

It writes `.dev/bundle/keelinfra-keycloak-offline-<version>-<os>-<arch>.tar.gz`
and a `.sha256` file next to it. Every release artifact in it is checked against
its publisher's checksums while the bundle is built. Versions of etcd,
keycloak-config-cli and PostgreSQL are read from the roles in the checkout
that builds the bundle, so build from the same checkout you install with.

Packages are resolved in an `ubuntu:24.04` or `rockylinux/rockylinux:9`
container as if nothing were installed, so the bundle serves a minimal node
as well as a full one. The package lists are [packages.txt](packages.txt)
(Ubuntu) and [packages-rocky9.txt](packages-rocky9.txt). A Rocky bundle also
carries the upstream Prometheus releases, which that family does not
package.

## Install from it

Copy the checkout and the bundle (with its `.sha256`) to the control node,
then:

```bash
./configure -c cluster.yml --offline keelinfra-keycloak-offline-26.8.1-ubuntu24.04-amd64.tar.gz
./install
```

`./configure --offline` checks the bundle against its checksums, unpacks it
into `inventory/offline/`, installs the Ansible collections from it (`ansible-galaxy collection install --offline`), and
records offline mode in the inventory. The control node needs `ansible-core`
2.14 or newer already installed (from your OS packages or an internal pip
mirror); nothing else.

On each node, `./install` unpacks the bundle's package repository into
`/opt/keelinfra/offline-repo`. Sources already configured (an internal
mirror, say) stay:

- Ubuntu: the repository becomes an apt source pinned above the others. The
  others are not refreshed during the install, and nothing is fetched from
  them while the bundle has the package.
- Rocky Linux: the repository is added as `keelinfra-offline`, disabled, and
  every package the install adds comes from it alone
  (`--disablerepo='*' --enablerepo=keelinfra-offline`). Your own `dnf` runs
  keep their usual sources. EPEL, PGDG and Grafana are not added.

Release artifacts (Keycloak, etcd, keycloak-config-cli, and on Rocky the
Prometheus tools) are copied from the control node instead of downloaded.

To go back to online installs, delete `inventory/offline/` and re-run
`./configure`.

## Upgrade with it

Build a bundle for the target version and pass it to `./upgrade`:

```bash
./upgrade --to 26.8.1 --offline keelinfra-keycloak-offline-26.8.1-ubuntu24.04-amd64.tar.gz
```

Without `--offline`, an offline cluster upgrades from the bundle already in
`inventory/offline/`, and `./upgrade` stops before it takes a backup or
touches a node if that bundle does not carry the target version.

## What is tested

The [offline workflow](../.github/workflows/offline.yml) builds bundles for
two releases, on Ubuntu 24.04 and on Rocky Linux 9, removes the default
route on all three nodes of the container rig, then runs `./configure --offline`, `./install`, every `./verify` drill,
and a rolling `./upgrade --offline` onto the next patch. It runs on every
change to the roles or the bundle scripts and weekly, since a package update
upstream can change the dependency tree.

Limits today: RHEL and AlmaLinux 9 take the Rocky bundle but are not
tested with it; arm64 bundles are built the same way but not tested; the rig's
control container keeps its internet access (the collections are baked into
its image), so the control node's offline path is covered by the checksum
and `--offline` collection install, not by a cut-off control node.
