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

**Production-ready, self-hosted Keycloak distribution.** HA, backups, monitoring, and tested upgrade paths — on your own infrastructure, in one command.

Keycloak is powerful. Running it in production is not. keelinfra packages what every team ends up building by hand: clustering, a highly available database, backup and point-in-time recovery, observability, and — the part nobody ships — an upgrade path that is actually tested against every upstream release.

## Why

Keycloak has no rolling upgrades across minor versions, a cluster layer that is easy to misconfigure, and a realm import/export story that loses settings. Managed Keycloak vendors solve this by hosting your identity data on their cloud. If you can't or won't do that — regulated industry, data residency, air-gapped — you are on your own.

keelinfra is the third option: a distribution you run yourself, with a subscription for the people who need someone to call.

## What you get

- **HA Keycloak cluster** — multi-node, DB-persisted sessions, load balancer, TLS
- **PostgreSQL HA** — Patroni-managed, automatic failover
- **Backups & PITR** — pgBackRest, scheduled, restore-tested
- **Observability** — Prometheus, Grafana dashboards, alert rules for the things that actually page you
- **Config as code** — realms, clients, and roles managed via keycloak-config-cli
- **Tested upgrade paths** — every supported path runs nightly in the [upgrade matrix](https://github.com/keelinfra/keycloak/actions/workflows/upgrade-matrix.yml): install, log in, upgrade, and the pre-upgrade session must survive

## Quick start

```bash
git clone https://github.com/keelinfra/keycloak
cd keycloak
./configure -c examples/ha-3node.yml   # describe your nodes
./install                              # ~10 minutes on 3 clean VMs
```

Single machine instead? Use `examples/single-node.yml` — same flow, no HA.

Then open `https://<your-host>/admin` and you're done. Full docs: https://keelinfra.io/docs/keycloak/

## Requirements

- 1 or 3 Linux nodes (Ubuntu 22.04/24.04, RHEL/Rocky 9, Debian 12)
- SSH access with sudo
- That's it — Ansible runs from the control node, nothing is pre-installed on targets

## Don't take our word for it

Every claim above is a drill you can run against your own cluster:

```bash
./verify                     # health of every component
./verify --drill failover    # switch the PostgreSQL leader over, write through it
./verify --drill restore     # restore the latest backup to a scratch directory
./verify --drill session     # rolling-restart every node; logins must survive
```

CI runs a clean install plus the session drill on every commit, and the upgrade matrix re-proves every supported upgrade path nightly.

## Upgrades

```bash
./upgrade --to 26.7.3
```

Supported paths are listed in [UPGRADES.md](UPGRADES.md) and re-verified nightly in CI. We do not claim to support an upgrade path we have not run.

## Subscription

The distribution is free and open source. A yearly subscription adds offline bundles, CVE tracking, upgrade runbooks, and direct access to the people who build it. $1,500 per node, per year — not per user. → https://keelinfra.io/pricing

## License

Apache License 2.0. See [LICENSE](LICENSE).

*Keycloak is a trademark of The Linux Foundation. keelinfra is an independent project and is not affiliated with or endorsed by The Linux Foundation or the Keycloak project.*
