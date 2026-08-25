# keelinfra/keycloak

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
- **Tested upgrade paths** — every upstream release is run through our upgrade matrix in CI before we tag support for it
- **Offline / air-gapped install** — all artifacts bundled, no internet required at deploy time

## Quick start

```bash
git clone https://github.com/keelinfra/keycloak
cd keycloak
./configure -c examples/ha-3node.yml   # describe your nodes
./install                              # ~10 minutes on 3 clean VMs
```

Then open `https://<your-host>/admin` and you're done. Full docs: https://keelinfra.io/keycloak

## Requirements

- 1 or 3 Linux nodes (Ubuntu 22.04/24.04, RHEL/Rocky 9, Debian 12)
- SSH access with sudo
- That's it — Ansible runs from the control node, nothing is pre-installed on targets

## Upgrades

```bash
./upgrade --to 26.7
```

Supported paths are listed in [UPGRADES.md](UPGRADES.md) and verified in CI. We do not claim to support an upgrade path we have not run.

## Status

| Component | Status |
|---|---|
| 3-node HA install | 🟢 working |
| PostgreSQL HA (Patroni, automatic failover) | 🟢 working |
| Backup / PITR (pgBackRest, restore-tested) | 🟢 working |
| Monitoring (Prometheus + Grafana + alerts) | 🟢 working |
| Tested upgrades (rolling patch / stop-start minor) | 🟢 working — see [UPGRADES.md](UPGRADES.md) |
| Upgrade matrix in CI | ⚪ planned |
| Single-node install | 🟡 CI smoke only |
| Air-gapped bundle | ⚪ planned |

This project is young. Follow the roadmap or star the repo to watch it grow.

## Subscription

The distribution is free and open source. A yearly subscription adds offline bundles, CVE tracking, upgrade runbooks, and direct access to the people who build it. Pricing is per node, not per user. → https://keelinfra.io/pricing

## Related

- `keelinfra/openbao` — the same treatment for OpenBao (secrets), coming next

## License

Apache License 2.0. See [LICENSE](LICENSE).

*Keycloak is a trademark of Red Hat, Inc. keelinfra is an independent project and is not affiliated with or endorsed by Red Hat or the Keycloak project.*
