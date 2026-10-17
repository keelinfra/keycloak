# Runbooks

What to do when an alert fires. One section per alert, in the order you are likely to need them;
each alert's notification links to its section here. Every section has the same shape: what is
broken for your users, what to check, what to do, and when to stop and get help.

Commands run on a node over SSH unless they start with `./`, which run from the control machine
in this repository. `<cluster>` is `cluster_name` from your cluster definition. On Rocky Linux and
RHEL the PostgreSQL data directory is `/var/lib/pgsql/17/patroni`; on Ubuntu it is
`/var/lib/postgresql/17/patroni`.

## First three commands

Whatever fired, start here. Together they show which layer is broken.

```bash
./verify                                                    # every component, from the control machine
sudo patronictl -c /etc/patroni/config.yml list             # PostgreSQL: who leads, who lags
/usr/local/bin/etcdctl endpoint health --cluster            # etcd: is there a quorum
```

The layers depend on each other from the bottom up: etcd holds the leader lock, Patroni runs
PostgreSQL and needs etcd to elect a leader, HAProxy sends database traffic to that leader, and
Keycloak talks to the database through HAProxy. Fix the lowest broken layer first; the ones above
it often recover on their own.

Two rules hold in every runbook below:

- **Never start PostgreSQL by hand** (`pg_ctl`, `systemctl start postgresql`). Patroni owns it.
  A PostgreSQL started outside Patroni can become a second leader and split your data.
- **Never delete files under the data directory or `pg_wal`** to free space. Free space elsewhere
  or grow the disk (see [DiskAlmostFull](#diskalmostfull)).

## NoPostgresLeader

**Severity:** critical. **Impact:** every write fails: logins that create sessions, admin
changes, token refreshes. Keycloak may still serve some cached reads.

**Check**

1. `/usr/local/bin/etcdctl endpoint health --cluster`. Patroni cannot elect a leader without an
   etcd quorum (2 of 3 members). If etcd is unhealthy, go to [EtcdNoLeader](#etcdnoleader) first.
2. `sudo patronictl -c /etc/patroni/config.yml list`. Look at the State column. `stopped` or
   missing members mean Patroni is down there: `sudo systemctl status patroni` and
   `sudo journalctl -u patroni -n 200` on that node.

**Fix**

- etcd back to quorum: Patroni elects a leader by itself within about 30 seconds. Watch
  `patronictl list`.
- Patroni stopped on every node: `sudo systemctl start patroni` on each node. The member with
  the most recent data takes the lead.
- A leader exists but the alert still fires: the metric comes from the first node's Prometheus;
  check [ExporterDown](#exporterdown).

**Get help** if no leader appears within 5 minutes of etcd being healthy and Patroni running on
every node, or if `patronictl list` shows two leaders.

## EtcdNoLeader

**Severity:** critical. **Impact:** none yet for users, but PostgreSQL cannot fail over. If the
PostgreSQL leader dies now, writes stop until etcd recovers.

**Check**

1. On each node: `sudo systemctl status etcd` and `sudo journalctl -u etcd -n 200`.
2. From any node:
   `sudo -i etcdctl endpoint status -w table` (root's shell already points etcdctl at every node,
   with the client certificate).
   It shows which members answer and who leads.
3. Look for the usual causes in the journal: a member that cannot reach the others (network or a
   host firewall on TCP 2379 and 2380), a full disk under `/var/lib/etcd`, or "apply request took
   too long" (a disk too slow for etcd).

**Fix**

- A stopped member: `sudo systemctl start etcd`. One member down leaves a quorum of two; the
  alert clears when it rejoins.
- Network: restore TCP 2379 and 2380 between the nodes. `./preflight` lists host firewalls.
- Disk: free space (see [DiskAlmostFull](#diskalmostfull)), then restart etcd.

**Get help** if two members stay down, or a member's data directory is damaged ("member has
already been bootstrapped", checksum or WAL errors). Replacing an etcd member means removing it
from the cluster and re-adding it with an empty data directory; do not improvise it on a
production cluster.

## PostgresDown

**Severity:** critical. **Impact:** if the node was a replica, none: HAProxy only sends traffic
to the leader. If it was the leader, writes stop for about 30 seconds until Patroni promotes a
replica, then carry on.

**Check**

1. `sudo patronictl -c /etc/patroni/config.yml list`: is there still a leader?
2. On the alerting node: `sudo systemctl status patroni` and `sudo journalctl -u patroni -n 200`.

**Fix**

- Patroni stopped: `sudo systemctl start patroni`. A former leader rejoins as a replica and
  rewinds itself (`pg_rewind`) if it had diverged.
- A replica that will not start or keeps failing to rewind: rebuild it from the leader with
  `sudo patronictl -c /etc/patroni/config.yml reinit <cluster> <node name>`. It copies the
  whole database over the network; expect load on the leader.
- The machine is gone (dead disk, will not boot): put a new one at the same address and run
  `./replace-node <node name>`. Not for the first node.

**Get help** if the node was the leader and no replica was promoted (that is
[NoPostgresLeader](#nopostgresleader)), or if `reinit` fails.

`./verify --drill failover` rehearses a planned leader switch on a healthy cluster. Run it
after any of the above to prove failover works again.

## KeycloakDown

**Severity:** critical. **Impact:** with one node down, none: HAProxy on every node stops
sending traffic to it within seconds, and sessions live in the database, so users stay logged
in. With every node down, nobody can log in.

**Check**

1. On the alerting node: `sudo systemctl status keycloak` and `sudo journalctl -u keycloak -n 300`.
2. `curl -sk https://127.0.0.1:9000/health/ready`: Keycloak's own view, including its database
   connection.
3. If every node is down at once, the database is the likely cause: check
   [NoPostgresLeader](#nopostgresleader).
4. `sudo dmesg -T | grep -i -E 'killed process|out of memory'`: the kernel kills the JVM when
   the node runs out of memory.

**Fix**

- `sudo systemctl restart keycloak` on that node. Restart nodes one at a time and wait for
  `/health/ready` before the next.
- Database errors in the log: fix the database first; Keycloak reconnects by itself.
- Out of memory: give the node more memory, or stop other programs on it.

**Get help** if Keycloak fails to start with a schema or migration error, or keeps restarting
after the database is healthy. Do not run `kc.sh` with other options by hand on a production
node.

`./verify --drill session` restarts every node in turn and checks that a login survives.

## PostgresReplicationLag

**Severity:** warning. **Impact:** none yet. A replica far behind is not a safe failover target:
Patroni will not promote a replica more than 1 MB behind, so a failover may have to wait.

**Check**

1. `sudo patronictl -c /etc/patroni/config.yml list`: the Lag column, per replica.
2. On the lagging replica: disk I/O and space (`iostat -x 5`, `df -h`), and
   `sudo journalctl -u patroni -n 200`.
3. Network between the leader and that replica.

**Fix**

- A short burst after a large import or a backup usually clears by itself; the alert waits five
  minutes before firing.
- A replica that stays behind or stops replaying: `sudo patronictl -c /etc/patroni/config.yml reinit <cluster> <node name>`.

**Get help** if every replica lags at once: that usually points at the leader (disk or load),
not at the replicas.

## BackupTooOld

**Severity:** warning. **Impact:** none yet, but the newest restorable backup in that repository
is more than 26 hours old. Repository 1 is on the first node; repository 2 is your bucket.

**Check**

On the first node:

```bash
sudo -u postgres pgbackrest --stanza=main info          # every backup, per repository
sudo -u postgres pgbackrest --stanza=main check         # WAL archiving works end to end
ls -lt /var/log/pgbackrest/ | head                      # the latest logs
```

Common causes: the first node was down at the scheduled time (02:30 for repository 1, 04:30 for
repository 2, the node's local time), the bucket is unreachable or its credentials changed, or the
disk under `/var/lib/pgbackrest` is full.

**Fix**

- Take the backup now, on the first node:
  `sudo -u postgres pgbackrest --stanza=main --repo=1 --type=diff backup` (`--repo=2` for the
  bucket).
- Bucket credentials changed: re-run `./configure` with `KEELINFRA_S3_ACCESS_KEY` and
  `KEELINFRA_S3_SECRET_KEY` set, then `./install`.
- Then `./verify --drill restore` restores the latest backup of each repository into a scratch
  directory, so you know the new backup is usable.

**Get help** if `check` fails on archiving: while WAL cannot be archived, PostgreSQL keeps it on
disk, and the disk will fill.

## DiskAlmostFull

**Severity:** warning. **Impact:** none yet. When the root filesystem fills, PostgreSQL stops
accepting writes and etcd stops, which takes the cluster down.

**Check**

```bash
df -h /
sudo du -xh --max-depth=2 /var/lib | sort -h | tail -15
sudo journalctl --disk-usage
```

The usual suspects, in order:

1. **`pg_wal` growing** under the PostgreSQL data directory: WAL archiving is failing, often
   because the bucket is unreachable. `sudo -u postgres pgbackrest --stanza=main check` says
   why. Fix archiving and PostgreSQL removes the old WAL itself.
2. **`/var/lib/pgbackrest`** on the first node: repository 1 keeps 2 full backups and what
   depends on them. Growth tracks database size.
3. **The systemd journal**: `sudo journalctl --vacuum-size=500M`.

**Fix** by freeing space in those places or growing the disk. Never delete files under the
data directory, `pg_wal` or `/var/lib/etcd` by hand.

**Get help** if `pg_wal` keeps growing after archiving works again.

## ExporterDown

**Severity:** warning. **Impact:** none for users; you are blind to part of the cluster, and
alerts that depend on the missing metrics cannot fire.

**Check** which job the alert names:

| Job | Unit on the node | Port |
|---|---|---|
| node | `prometheus-node-exporter` | 9100 |
| postgres | `prometheus-postgres-exporter` | 9187 |
| etcd | `etcd` itself | 2379 |

`sudo systemctl status <unit>` on the node in the alert, then from the first node
`sudo curl -s --cacert /etc/keelinfra/tls/internal/ca.crt --cert /etc/keelinfra/tls/internal/node.crt --key /etc/keelinfra/tls/internal/node.key https://<node>:<port>/metrics | head`
(use `http://` and no certificate options on a cluster with `internal_tls: false`).

**Fix**

- A stopped exporter: `sudo systemctl restart <unit>`.
- The etcd job: etcd itself is not answering on that node; follow [EtcdNoLeader](#etcdnoleader).
- Answers locally but not from the first node: a firewall between the nodes.

## CertificateExpiringSoon

**Severity:** warning. **Impact:** none yet. When the certificate expires: an internal one stops
the nodes talking to each other (etcd, replication, failover), the HTTPS one stops users logging
in.

**Check** which file the alert names, and `./verify`, which prints every certificate's expiry on
every node and whether each port already serves the one on disk.

**Fix**

- `/etc/keelinfra/tls/internal/node.crt`, or `/etc/keelinfra/tls/server.crt` with
  `tls_mode: selfsigned`: run `./renew-certs`. It signs new certificates from the cluster's own
  CAs, valid two years, and has each service load them without a restart. Keycloak picks up a new
  HTTPS certificate within the hour; to switch at once, restart it one node at a time.
- `/etc/keelinfra/tls/server.crt` with `tls_mode: custom`: your certificate. Replace the files
  `tls_cert_file` and `tls_key_file` point to, then `./configure` and `./install`.
- A `ca.crt`: the CA itself (valid ten years). `./renew-certs` does not replace a CA; get help.

If `./verify` reports a port that still serves the old certificate after `./renew-certs`, restart
that service on that node (`sudo systemctl restart etcd`, `patroni`, or the exporter).

**Get help** for an expiring CA, or if a certificate has already expired and the nodes no longer
reach each other.

## Not covered yet

Stated plainly so you can plan around them:

- **Losing the first node for good.** It holds Prometheus, Alertmanager, Grafana and backup
  repository 1. The database fails over, but alerting and local backups stop until the node
  returns; `backup_s3` keeps the backups safe.
- **Replacing the first node, or moving a node to a new address.** `./replace-node` puts a new
  machine in place of the second or third node at the same address (DEPLOYMENT.md, Day two).
- **Replacing a CA.** The internal CA and, with `tls_mode: selfsigned`, the HTTPS CA last ten
  years; replacing one in a running cluster is not scripted.

Subscription customers get help with any of the above, and with every runbook's "get help" case:
https://keelinfra.io/keycloak/pricing/
