# Offline bundles

For nodes with no internet access. An offline bundle is one tarball holding
everything `./install` and `./upgrade` otherwise download: the apt packages
with their whole dependency tree, the Keycloak distribution, etcd,
keycloak-config-cli, and the Ansible collections for the control node.

## Build one

On any machine with Docker and internet access:

```bash
bundle/build.sh --version 26.8.1                 # amd64, upstream Keycloak
bundle/build.sh --version 26.8.1 --arch arm64    # for arm64 nodes (needs qemu binfmt on an amd64 host)
bundle/build.sh --version 26.2.16 \
  --dist-url https://github.com/keelinfra/keycloak/releases/download/kc-26.2.16-keel1/keycloak-26.2.16.tar.gz
```

It writes `.dev/bundle/keelinfra-keycloak-offline-<version>-ubuntu24.04-<arch>.tar.gz`
(about 1 GB) and a `.sha256` file next to it. Versions of etcd,
keycloak-config-cli and PostgreSQL are read from the roles in the checkout
that builds the bundle, so build from the same checkout you install with.

Packages are resolved in an `ubuntu:24.04` container as if nothing were
installed, so the bundle serves a minimal node as well as a full one. The
package list is [packages.txt](packages.txt).

## Install from it

Copy the checkout and the bundle (with its `.sha256`) to the control node,
then:

```bash
./configure -c cluster.yml --offline keelinfra-keycloak-offline-26.8.1-ubuntu24.04-amd64.tar.gz
./install
```

`./configure --offline` checks the bundle against its checksums, unpacks it
into `inventory/offline/`, installs the Ansible collections from it, and
records offline mode in the inventory. The control node needs `ansible-core`
2.14 or newer already installed (from your OS packages or an internal pip
mirror); nothing else.

On each node, `./install` unpacks the bundle's package repository into
`/opt/keelinfra/offline-repo` and adds it as an apt source pinned above the
others. Sources already configured (an internal mirror, say) stay; they are
not refreshed during the install, and nothing is fetched from them while the
bundle has the package.

Release artifacts (Keycloak, etcd, keycloak-config-cli) are copied from the
control node instead of downloaded.

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
two releases, removes the default route on all three nodes of the container
rig, then runs `./configure --offline`, `./install`, every `./verify` drill,
and a rolling `./upgrade --offline` onto the next patch. It runs on every
change to the roles or the bundle scripts and weekly, since a package update
upstream can change the dependency tree.

Limits today: Ubuntu 24.04 nodes only, as for online installs; the rig's
control container keeps its internet access (the collections are baked into
its image), so the control node's offline path is covered by the checksum
and `--offline` collection install, not by a cut-off control node.
