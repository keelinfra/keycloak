<a href="https://keelinfra.io">
  <picture>
    <source media="(prefers-color-scheme: dark)"
            srcset="https://raw.githubusercontent.com/keelinfra/.github/main/assets/wordmark-dark.svg">
    <img alt="keelinfra" width="280"
         src="https://raw.githubusercontent.com/keelinfra/.github/main/assets/wordmark-light.svg">
  </picture>
</a>

# keelinfra/keycloak

[![smoke](https://github.com/keelinfra/keycloak/actions/workflows/smoke.yml/badge.svg)](https://github.com/keelinfra/keycloak/actions/workflows/smoke.yml)
[![upgrade matrix](https://github.com/keelinfra/keycloak/actions/workflows/upgrade-matrix.yml/badge.svg)](https://github.com/keelinfra/keycloak/actions/workflows/upgrade-matrix.yml)
[![HA matrix](https://github.com/keelinfra/keycloak/actions/workflows/ha-matrix.yml/badge.svg)](https://github.com/keelinfra/keycloak/actions/workflows/ha-matrix.yml)

**Production-ready, self-hosted Keycloak distribution.** HA, backups, monitoring, and tested upgrade paths — on your own infrastructure, in one command.

Keycloak is powerful. Running it in production is not. keelinfra packages what every team ends up building by hand: clustering, a highly available database, backup and point-in-time recovery, observability, and — the part nobody ships — an upgrade path that is actually tested against every upstream release.

## Why

Keycloak has no rolling upgrades across minor versions, a cluster layer that is easy to misconfigure, and a realm import/export story that loses settings. Managed Keycloak vendors solve this by hosting your identity data on their cloud. If you can't or won't do that — regulated industry, data residency, air-gapped — you are on your own.

keelinfra is the third option: a distribution you run yourself, with a subscription for the people who need someone to call.

## What you get

- **HA Keycloak cluster** — multi-node, DB-persisted sessions, load balancer, TLS
- **PostgreSQL HA** — Patroni-managed, automatic failover
- **Backups & PITR** — pgBackRest, scheduled, restore-tested; optional encrypted off-site copy to any S3-compatible bucket
- **Observability** — Prometheus metrics and alert rules for the things that actually page you, Alertmanager routing to a webhook or email, and a Grafana overview dashboard
- **Config as code** — realms, clients, and roles managed via keycloak-config-cli
- **Tested upgrade paths** — every supported path runs nightly, single-node in the [upgrade matrix](https://github.com/keelinfra/keycloak/actions/workflows/upgrade-matrix.yml) and on a 3-node cluster under load-balancer probes in the [HA matrix](https://github.com/keelinfra/keycloak/actions/workflows/ha-matrix.yml): install, log in, upgrade, and the pre-upgrade session must survive

## Quick start

```bash
git clone https://github.com/keelinfra/keycloak
cd keycloak
./configure -c examples/ha-3node.yml   # describe your nodes
./install                              # ~10 minutes on 3 clean VMs
```

Single machine instead? Use `examples/single-node.yml` — same flow, no HA.

No internet on the nodes? Build an [offline bundle](bundle/README.md) on a machine that has it, then `./configure -c <cluster.yml> --offline <bundle.tar.gz>` — packages, Keycloak and every other artifact come from the bundle, and CI proves it on nodes with no route out.

Then open `https://<your-host>/admin` and you're done. Before production, read the [deployment guide](DEPLOYMENT.md): network, backups off the cluster, alert routing. Full docs: https://keelinfra.io/docs/keycloak/

## Requirements

- 1 or 3 Linux nodes running Ubuntu 24.04 (tested in CI); Ubuntu 22.04 and Debian 12 are untested, and RHEL/Rocky are not supported yet (the roles install packages with apt)
- SSH access with passwordless sudo
- Internet access from the nodes, or an [offline bundle](bundle/README.md)
- That's it — Ansible runs from the control node, nothing is pre-installed on targets

## Don't take our word for it

Every claim above is a drill you can run against your own cluster:

```bash
./verify                     # health of every component
./verify --drill failover    # switch the PostgreSQL leader over, write through it
./verify --drill restore     # restore the latest backup of every repository to a scratch directory
./verify --drill session     # rolling-restart every node; logins must survive
./verify --drill alert       # send a test alert; every configured receiver must accept it
```

CI runs a clean single-node install with the session and restore drills on every commit, installs a 3-node cluster and runs every drill on it whenever the roles change, and re-proves every supported upgrade path nightly — single-node, and on three nodes under load-balancer probes.

## Upgrades

```bash
./upgrade --to 26.8.1
```

Supported paths are listed in [UPGRADES.md](UPGRADES.md) and re-verified nightly in CI. We do not claim to support an upgrade path we have not run. Need one that isn't listed? [Request it](https://github.com/keelinfra/keycloak/issues/new?template=upgrade_path_request.yml) — we drill it in public CI before it goes on the list.

## Subscription

The distribution is free and open source. A yearly subscription adds [CVE tracking](CVE-POLICY.md), upgrade runbooks, and direct access to the people who build it; prebuilt offline bundles for each release join it when they ship (anyone can build one today with `bundle/build.sh`). Standard is $4,500 per production cluster per year (up to 3 Keycloak nodes), Enterprise from $12,000 — not per user. → https://keelinfra.io/keycloak/pricing/

CVE tracking means notification, impact analysis against your configuration, and help upgrading along a drilled path — **not** backported patches. [CVE-POLICY.md](CVE-POLICY.md) states the boundary, and works through what "20 CVEs" actually meant for two recent releases.

## License

Apache License 2.0. See [LICENSE](LICENSE).

*Keycloak is a trademark of The Linux Foundation. keelinfra is an independent project and is not affiliated with or endorsed by The Linux Foundation or the Keycloak project.*
