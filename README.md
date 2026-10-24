<a href="https://keelinfra.io">
  <picture>
    <source media="(prefers-color-scheme: dark)"
            srcset="https://raw.githubusercontent.com/keelinfra/.github/main/assets/wordmark-dark.svg">
    <img alt="keelinfra" width="280"
         src="https://raw.githubusercontent.com/keelinfra/.github/main/assets/wordmark-light.svg">
  </picture>
</a>

# keelinfra/keycloak

> [!WARNING]
> **Discontinued on 24 October 2026.** This distribution is no longer maintained: no new releases, no security updates, no support, and no subscriptions. The repository is kept read-only as a record. No subscription or support contract was ever sold for it.
>
> If you run it, move to a maintained Keycloak: the upstream [Keycloak](https://www.keycloak.org/) project (its container image or the Keycloak Operator), or a commercially supported build such as the Red Hat build of Keycloak. The playbooks here stay readable under Apache-2.0 if you want to keep them yourself.

[![smoke](https://github.com/keelinfra/keycloak/actions/workflows/smoke.yml/badge.svg)](https://github.com/keelinfra/keycloak/actions/workflows/smoke.yml)
[![upgrade matrix](https://github.com/keelinfra/keycloak/actions/workflows/upgrade-matrix.yml/badge.svg)](https://github.com/keelinfra/keycloak/actions/workflows/upgrade-matrix.yml)
[![HA matrix](https://github.com/keelinfra/keycloak/actions/workflows/ha-matrix.yml/badge.svg)](https://github.com/keelinfra/keycloak/actions/workflows/ha-matrix.yml)

**Production-ready, self-hosted Keycloak distribution.** HA, backups, monitoring, and tested upgrade paths — on your own infrastructure, in one command.

Keycloak is powerful. Running it in production is not. keelinfra packages what every team ends up building by hand: clustering, a highly available database, backup and point-in-time recovery, observability, and — the part nobody ships — an upgrade path that is actually tested against every upstream release.

## Why

Keycloak has no rolling upgrades across minor versions, a cluster layer that is easy to misconfigure, and a realm import/export story that loses settings. Managed Keycloak vendors solve this by hosting your identity data on their cloud. If you can't or won't do that — regulated industry, data residency, air-gapped — you are on your own.

keelinfra was the third option: a distribution you run yourself.

## What you get

- **HA Keycloak cluster** — multi-node, DB-persisted sessions, load balancer, TLS for users and between the nodes (etcd, PostgreSQL, Patroni, metrics, all checked by `./verify`)
- **PostgreSQL HA** — Patroni-managed, automatic failover, synchronous replication: a failover loses no saved write
- **Backups & PITR** — pgBackRest, scheduled, restore-tested; optional encrypted off-site copy to any S3-compatible bucket
- **Observability** — Prometheus metrics and alert rules for the things that actually page you, Alertmanager routing to a webhook or email from two nodes (losing either still pages you), and a Grafana overview dashboard
- **Config as code** — realms, clients, and roles managed via keycloak-config-cli
- **Tested upgrade paths** — every supported path runs nightly, single-node in the [upgrade matrix](https://github.com/keelinfra/keycloak/actions/workflows/upgrade-matrix.yml) and on a 3-node cluster under load-balancer probes in the [HA matrix](https://github.com/keelinfra/keycloak/actions/workflows/ha-matrix.yml): install, log in, upgrade, and the pre-upgrade session must survive

## Quick start

Just want to look first? On any machine with Docker (about 10 GB of memory for it):

```bash
git clone https://github.com/keelinfra/keycloak
cd keycloak
./try          # 3-node cluster in containers; prints the admin console URL and password
./try --down   # remove it
```

`./try` starts three containers standing in for three servers and runs the same `./install` on them as on real machines. On a 4-core GitHub runner it takes 7 minutes, after a first build of the container images. Then stop a node, run the drills below with `./verify --drill failover`, and watch the console keep working. It is for a look, not for production.

On your own machines:

```bash
git clone https://github.com/keelinfra/keycloak
cd keycloak
./configure -c examples/ha-3node.yml   # describe your nodes
./preflight                            # check them; changes nothing
./install                              # ~10 minutes on 3 clean VMs
```

Single machine instead? Use `examples/single-node.yml` — same flow, no HA. Going to production? Start from `examples/production.yml`: VIP, your own certificate, off-site backups and alert routing all switched on.

`./preflight` looks at every node before anything is installed and lists everything that is wrong in one report: an unsupported OS, too little memory or disk, a port another program already holds, a host address that is not on the node, nodes that cannot reach each other, download sources the nodes cannot reach, a host firewall, and a VIP that is off the nodes' network or already taken. `./install` runs the same checks first and stops before changing anything if one fails.

No internet on the nodes? Build an [offline bundle](bundle/README.md) on a machine that has it, then `./configure -c <cluster.yml> --offline <bundle.tar.gz>` — packages, Keycloak and every other artifact come from the bundle, and CI proves it on nodes with no route out.

Then open `https://<your-host>/admin` and you're done. Before production, read the [deployment guide](DEPLOYMENT.md): network, backups off the cluster, alert routing. Full docs: https://keelinfra.io/docs/keycloak/

## Requirements

- 1 or 3 Linux nodes running Ubuntu 24.04, Rocky Linux 9 or AlmaLinux 9 (all tested in CI). RHEL 9 takes the same path but is not in CI (it needs a subscription for packages); Ubuntu 22.04 and Debian 12 are untested. On the RHEL family the nodes need EPEL (the roles enable it) and SELinux stays enforcing: a [weekly VM test](https://github.com/keelinfra/keycloak/actions/workflows/vm.yml) installs and drills three Rocky 9 VMs with SELinux enforcing and fails on any denial. Offline bundles cover Ubuntu 24.04 and Rocky Linux 9
- SSH access with passwordless sudo
- Internet access from the nodes, or an [offline bundle](bundle/README.md)
- That's it — Ansible runs from the control node, nothing is pre-installed on targets

## Don't take our word for it

Every claim above is a drill you can run against your own cluster:

```bash
./verify                     # health of every component
./verify --drill failover    # switch the PostgreSQL leader over, write through it
./verify --drill crash       # freeze the leader mid-write; no acknowledged write may be lost
./verify --drill restore     # restore the latest backup of every repository to a scratch directory
./verify --drill session     # rolling-restart every node; logins must survive
./verify --drill alert       # send a test alert; every configured receiver must accept it
```

When an alert fires, [RUNBOOKS.md](RUNBOOKS.md) says what is broken for your users, what to check and what to do, one section per alert; every alert notification links to its section.

When the data itself is wrong (a deleted realm, a bad change), `./restore --time "2026-10-17 09:30:00+00"` puts the database back as it was at that moment, on every node; without `--time` it restores as close to now as the archived WAL goes. CI drops a table and restores it on three nodes.

When a machine dies, `./replace-node kc-node3` installs a fresh one at the same address and joins it to the running cluster, the first node included (its CAs come back from an encrypted copy on your control machine); CI kills the third node, then the first, and replaces each. When every machine is gone, `./rebuild` installs blank ones and restores the database from the off-site bucket; CI wipes all three nodes and gets its data back.

`./verify` and an alert warn 30 days before any certificate on a node expires; `./renew-certs` renews the ones the cluster signs itself, without downtime.

When a certificate authority is distrusted, `./update-trust` removes it from every node's system and Java trust stores and restarts Keycloak one node at a time, without waiting for the OS packages; `./verify` fails until it is gone ([why](CVE-POLICY.md#when-a-certificate-authority-is-distrusted)).

CI runs a clean single-node install with the session and restore drills on every commit, installs a 3-node cluster and runs every drill on it whenever the roles change, and re-proves every supported upgrade path nightly — single-node, and on three nodes under load-balancer probes.

## Upgrades

```bash
./upgrade --to 26.8.1
```

Supported paths are listed in [UPGRADES.md](UPGRADES.md) and were re-verified nightly in CI until the distribution was discontinued. We do not claim to support an upgrade path we have not run. 

## Security

The distribution is discontinued and gets no security updates: [SECURITY.md](SECURITY.md). Releases from October 2026 on carry a CycloneDX SBOM and signed attestations you can check with `gh attestation verify`; how that and our vulnerability handling line up with the EU Cyber Resilience Act is in [CRA.md](CRA.md).

## License

Apache License 2.0. See [LICENSE](LICENSE).

*Keycloak is a trademark of The Linux Foundation. keelinfra is an independent project and is not affiliated with or endorsed by The Linux Foundation or the Keycloak project.*
