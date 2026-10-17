# Deployment guide

How to put a keelinfra Keycloak cluster into production: what runs where, what the network must
allow, how backups leave the cluster, where alerts go, and how to prove each piece works before
users depend on it. It covers the 3-node HA layout; a single node runs the same components
without the redundancy.

Everything below is what the roles in this repository do. Where something is not tested, the guide
says so.

## What you are deploying

Three identical nodes. Each one runs:

| Component | Role | Port |
|---|---|---|
| HAProxy | Public entrypoint: TLS passthrough to every healthy Keycloak node | 443 |
| Keycloak | The identity server, clustered (Infinispan, JDBC-ping discovery) | 8443, 9000 (health, metrics), 7800 (cluster) |
| PostgreSQL 17 + Patroni | Database with one leader and two streaming replicas, automatic failover | 5432, 8008 (Patroni API) |
| HAProxy (local) | Sends Keycloak's database connections to the current Patroni leader | 127.0.0.1:5433 |
| etcd | Leader election for Patroni; needs two of three nodes up | 2379, 2380 |
| pgBackRest | WAL archiving and backups | ssh between nodes |
| node / postgres exporters | Host and database metrics | 9100, 9187 |
| keepalived (optional) | Floating VIP across the three nodes | VRRP |

The first node also runs the shared services:

| Component | Role | Port |
|---|---|---|
| pgBackRest repository 1 | Backups on the first node's disk | — |
| Prometheus | Scrapes every node, evaluates the alert rules | 9090 |
| Alertmanager | Routes alerts to your webhook and/or email | 127.0.0.1:9093 |
| Grafana | Overview dashboard, Prometheus and Alertmanager data sources | 3000 |

The optional off-site copy (pgBackRest repository 2) lives in an S3-compatible bucket you
provide.

What survives what, on a 3-node cluster:

- **One node down:** logins keep working through the other two nodes' HAProxy. If it was the
  PostgreSQL leader, Patroni promotes a replica. `./verify --drill failover` and
  `./verify --drill session` exercise both, and CI runs them on three nodes.
- **Two nodes down:** etcd loses quorum and PostgreSQL stops accepting writes. Keycloak cannot
  serve logins. Three nodes tolerate one failure, not two.
- **The first node down:** the cluster keeps serving, but backups, Prometheus, Alertmanager and
  Grafana are down with it until it returns. If its disk is lost, so is repository 1. This is why
  production clusters should set `backup_s3`.

## Before you start

**Nodes.** Three machines running Ubuntu 24.04, Rocky Linux 9 or AlmaLinux 9 (all tested in CI;
RHEL 9 takes the same path but is not in CI).
For evaluation, 4 GB RAM and 2 vCPU per node is enough. The defaults size Keycloak's heap at
512 MB to 1 GB and PostgreSQL's shared buffers at 512 MB; for production, size to your login
volume and watch the dashboard.

**Control machine.** Your laptop or a jump host with `ansible-core`, SSH access to every node as
a user with passwordless sudo. The nodes download Keycloak, PostgreSQL, Grafana and the rest from
upstream during install, unless you install from an offline bundle ([bundle/README.md](bundle/README.md)).

**DNS and certificate.** A name for the service (say `sso.example.com`). Either let the install
generate a private CA (`tls_mode: selfsigned`), or bring a certificate for that name
(`tls_mode: custom`, see the [configuration reference](https://keelinfra.io/docs/keycloak/configuration/)).

**Network.** Open these, and nothing more:

| From | To | Ports |
|---|---|---|
| Users | every node (or the VIP / your load balancer) | 443 |
| Control machine | every node | 22 |
| Every node | every node | 22, 2379, 2380, 5432, 7800, 8008, 8443, 9000, 57800 |
| First node | every node | 9100, 9187 (scrapes) |
| Operators | first node | 3000 (Grafana), 9090 (Prometheus) |
| Operators | every node | 8404 (HAProxy stats, password in the vault) |
| First node | your bucket, SMTP relay, webhook | as configured |

Prometheus (9090) and Grafana (3000) listen on all interfaces. Prometheus has no login, so keep
both reachable only from your operators' network.

**Traffic between the nodes is encrypted.** The install creates a cluster-internal CA on the
first node and gives every node its own certificate from it. etcd (clients and peers), the
Patroni API, PostgreSQL (replication and Keycloak's connections) and the exporters Prometheus
scrapes all use TLS, and etcd and the exporters only answer clients holding a certificate from
that CA. PostgreSQL refuses unencrypted connections from the nodes. Keycloak encrypts its own
cluster traffic (port 7800) with mutual TLS. `./verify` checks every one of these ports on every
node and fails if one answers in plaintext. One port stays plain: 57800, where Keycloak's
cluster checks that the other nodes are alive. It carries those messages only (node names and addresses), no user,
session or database data. The internal CA's key never leaves the first node
(`/etc/keelinfra/tls/internal/ca/`); node certificates are valid for two years, and
`./renew-certs` replaces them (see Day two).

Clusters installed before this have `internal_tls` unset and keep running as they were. etcd
cannot move to TLS in place, so `./install` stops (in preflight, before changing anything) if
`./configure` now asks for TLS on such a cluster. Either set `internal_tls: false` in the cluster
definition and re-run `./configure`, or install a new cluster and move the realms to it.

## 1. Describe the cluster

Copy `examples/ha-3node.yml` and edit it. It is the only file you edit. The production-relevant
blocks:

```yaml
cluster_name: keycloak-prod
nodes:
  - {host: 10.0.0.11, name: kc-node1}
  - {host: 10.0.0.12, name: kc-node2}
  - {host: 10.0.0.13, name: kc-node3}
ssh_user: ubuntu
domain: sso.example.com
vip: ""                      # or a free address on the nodes' L2 segment
keycloak_version: "26.8.1"
tls_mode: custom
tls_cert_file: tls/sso.example.com.crt
tls_key_file: tls/sso.example.com.key

backup_s3:
  endpoint: s3.eu-central-1.amazonaws.com
  region: eu-central-1
  bucket: acme-keycloak-backups
  uri_style: host            # "path" for most self-hosted stores

alerting:
  webhook_url: https://hooks.example.com/keycloak
  email:
    to: oncall@example.com
    from: keycloak-alerts@example.com
    smarthost: smtp.example.com:587
    username: keycloak-alerts@example.com
```

Commit this file to your own infrastructure repository if you like: it holds no secrets.

## 2. Configure

```bash
export KEELINFRA_S3_ACCESS_KEY=...   # only on the first run with backup_s3
export KEELINFRA_S3_SECRET_KEY=...
export KEELINFRA_SMTP_PASSWORD=...   # only if alerting.email.username is set
./configure -c cluster.yml
```

`./configure` checks the definition, the certificate and SSH access to every node, then writes
`inventory/`: the generated inventory, and an ansible-vault holding every password, the backup
encryption passphrase, and the bucket and SMTP credentials. The vault key is
`inventory/.vault_pass`.

**Back up `inventory/` somewhere safe and separate from the cluster.** Backups in both
repositories are encrypted with the passphrase in that vault. Without it, a backup cannot be
restored.

## 3. Install

```bash
./install
```

The playbooks run in order: OS preparation, etcd, PostgreSQL and Patroni, HAProxy, pgBackRest
(including a first full backup to every repository), TLS material, Keycloak, realm
configuration, the VIP if set, and monitoring.

Every install also creates a `demo` realm (user `demo`, password `demo12345`) that the session
drill uses. Change the password or delete the realm before go-live; the session drill needs it
to run.

## 4. Prove it

```bash
./verify                     # health of every component, backups, monitoring
./verify --drill failover    # switch the PostgreSQL leader to a replica, write through it
./verify --drill restore     # restore the latest backup of every repository to a scratch dir
./verify --drill session     # rolling restart of every Keycloak node; sessions must survive
./verify --drill alert       # send a test alert; every configured receiver must accept it
./verify --drill all         # all of the above
```

`./verify` (health) fails if a component is down, if any backup repository has no backup, if any
Prometheus target is not being scraped, if any metric an alert rule or the dashboard depends on
has no data, or if Grafana is not serving the dashboard.

CI runs this whole sequence, install plus `./verify --drill all`, on a three-node cluster with an
S3 bucket and a webhook receiver whenever the roles change.

## Backups

pgBackRest archives every WAL segment continuously and takes scheduled backups:

| Repository | Where | Schedule | Kept |
|---|---|---|---|
| 1 | first node, `/var/lib/pgbackrest` | full Sunday 02:30, differential other days | 2 full backups and what depends on them |
| 2 (optional) | your bucket, under `/<cluster_name>` | full Sunday 04:30, differential other days | `retention_full` full backups (default 4) |

Both are encrypted (AES-256) with the passphrase in the vault. Times are the first node's local
time. `./upgrade` also takes a differential backup to repository 1 before it changes anything.

WAL goes to both repositories as it is written, so either one can restore to any point since its
oldest kept backup. If the bucket is unreachable, archiving fails and PostgreSQL keeps the WAL on
disk and retries; watch the root-filesystem alert during a long bucket outage.

**What is tested:** that each repository holds a backup and that the latest one restores into a
scratch directory (`./verify --drill restore`), on every commit for one node and on three nodes
when the roles change.

**Putting the database back:** `./restore` replaces the cluster's database with a backup, either as
close to now as the archived WAL goes or as it was at a moment you name:

```bash
./restore                                     # newest backup + all archived WAL, repository 1
./restore --time "2026-10-17 09:30:00+00"     # the state at that moment (a deleted realm, a bad change)
./restore --repo 2                            # from the off-site bucket
```

It asks you to type the cluster name, stops Keycloak and Patroni, restores on the first node,
replays WAL up to the target, makes that node the leader and rebuilds the others from it, starts
Keycloak again and takes a full backup. Users cannot log in while it runs. Every node's previous
data directory stays beside the new one (`<data dir>.before-restore-<time>`) until you delete it,
so check the disk has room for a second copy. CI writes a row, drops it, restores to the moment in
between and checks the row is back, on three nodes, whenever the roles change.

`./restore` needs the nodes and the repositories to be there. **Not scripted:** rebuilding after
losing every node, where a fresh install would have to adopt the existing backups.

## Monitoring and alerts

Prometheus scrapes every node every 15 seconds. The rules that page you:

| Alert | Fires when | Severity |
|---|---|---|
| KeycloakDown | a Keycloak node stops answering for 2 minutes | critical |
| PostgresDown | a Patroni member stops answering for 2 minutes | critical |
| NoPostgresLeader | no PostgreSQL leader for 1 minute: writes are failing | critical |
| EtcdNoLeader | an etcd member has no leader: failover is impossible | critical |
| PostgresReplicationLag | a replica is more than 100 MB behind for 5 minutes | warning |
| BackupTooOld | a repository's last backup is older than 26 hours | warning |
| DiskAlmostFull | a root filesystem is below 15% free for 10 minutes | warning |
| ExporterDown | host, database or etcd metrics stop arriving for 5 minutes | warning |
| CertificateExpiringSoon | a certificate on a node expires within 30 days | warning |

Alertmanager sends each alert, and its resolution, to the webhook and/or email in `alerting`,
grouped by alert and node, repeating every 4 hours while it fires. Without `alerting`, alerts
are only visible in Grafana and Alertmanager. Run `./verify --drill alert` after any change to
the receivers.

Grafana is on `http://<first node>:3000`, user `admin`, password `vault_grafana_admin_password`
in the vault. The **keelinfra: Keycloak cluster** dashboard shows nodes up, PostgreSQL leader and
replica lag, hours since the last backup per repository, logins and failed logins per realm, HTTP
traffic and errors, JVM heap, database pool use, and host CPU, memory and disk.

To read a vault value:

```bash
ANSIBLE_VAULT_PASSWORD_FILE=inventory/.vault_pass ansible-vault view inventory/group_vars/all/vault.yml
```

## Day two

- **Upgrades:** `./upgrade --to <version>`, only along a path listed in
  [UPGRADES.md](UPGRADES.md). Every listed path is drilled nightly on one and three nodes.
- **Changing backup or alert settings after install:** edit the definition, re-run
  `./configure` (with the credential variables if they changed) and `./install`. Re-running
  `./install` on a live cluster to change these settings is not covered by CI yet; do it in a
  maintenance window and run `./verify --drill all` afterwards.
- **Certificates:** `./verify` fails, and CertificateExpiringSoon fires, 30 days before any
  certificate on a node expires. The ones the cluster signs itself (every node's internal
  certificate, and the HTTPS certificate with `tls_mode: selfsigned`) are renewed with
  `./renew-certs`: new certificates from the same CAs, loaded by each service without downtime,
  checked port by port. CI renews them on a running three-node cluster. With `tls_mode: custom`,
  replace the files, re-run `./configure` and `./install`.
- **Security fixes upstream:** see the [CVE policy](CVE-POLICY.md).

## Known gaps

Stated plainly, so you can plan around them:

- Certificates are not renewed on a schedule: you run `./renew-certs` when warned. Replacing a
  CA (ten years) is not scripted.
- Ubuntu 24.04, Rocky Linux 9 and AlmaLinux 9 are tested; RHEL 9 is not in CI.
- Monitoring and repository 1 live on the first node. Losing it stops backups and alerting until
  it returns; `backup_s3` keeps the backups safe, nothing yet keeps alerting up.
- Prometheus and Grafana listen on all interfaces; restrict them with your firewall.
- No scripted rebuild after losing every node (see Backups); `./restore` covers a database that
  is wrong, on nodes that are still there.
- Growing a single node into a 3-node cluster means a fresh install plus a realm import.
- Offline bundles exist for Ubuntu 24.04 and Rocky Linux 9.
