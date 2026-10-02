# 3-node container rig

A three-node Keycloak HA cluster in Docker, for running the playbooks the
way the product documents them — `./configure`, `./install`, `./upgrade`,
`./verify` — without three VMs. The same rig runs in CI
(`.github/workflows/ha-smoke.yml`).

It is test infrastructure, not a deployment target. The product is a
VM/bare-metal distribution; read "What the rig is not" before drawing
conclusions from it.

## Layout

| container       | address        | role |
|-----------------|----------------|------|
| `kc-node1..3`   | 172.28.0.11–13 | cluster nodes: Ubuntu 24.04, systemd as PID 1, sshd |
| `kc-ha-control` | 172.28.0.2     | the operator's machine: ansible-core and the collections, repo mounted at `/work` |

Node images contain what the Ubuntu 24.04 cloud image ships and the roles
rely on (python3-apt, python3-cryptography, cron, sudo, openssh-server, ...).
Nothing the roles install themselves is pre-baked: every run is a clean
install. Images are tagged `kc-ha-node:local` and `kc-ha-control:local`,
built locally or inside the CI job, and never pushed to a registry.

## Use

```sh
dev/ha-up.sh                      # build images, start, ./configure
dev/ha-exec.sh ./install
dev/ha-exec.sh ./verify --drill all
dev/ha-exec.sh ./upgrade --to 26.8.0
dev/ha-exec.sh bash               # a shell on the control node
dev/ha-logs.sh                    # journals etc. → .dev/containers/artifacts/
dev/ha-down.sh

dev/ha-drill.sh --from 26.7.3 --to 26.7.5 --strategy rolling   # one matrix row, end to end
```

`dev/ha-drill.sh` is what the nightly HA matrix runs (`.github/workflows/ha-matrix.yml`):
it brings the rig up on FROM, logs in, starts `dev/probe.sh` against every
node's load balancer, runs `./upgrade --to TO`, reads the probes (a rolling
path must answer 200 to every one), checks all three nodes and every
balancer, refreshes the pre-upgrade session, runs every `./verify` drill and
leaves `.dev/containers/receipt.md`. Tarballs land in `.dev/dist-cache/` and
are served to the nodes from the control container, so a release is
downloaded once.

`dev/ha-up.sh --version 26.7.5` installs another version; the cluster
definition it writes is `.dev/containers/cluster.yml`. A node is reached
with `docker exec -it kc-node2 bash`. Keycloak answers on every node's
HAProxy (`https://172.28.0.11/`, self-signed, host name `sso.ha.local`) and
on its own port 8443. On macOS the bridge addresses are not routable from
the host; go through `dev/ha-exec.sh curl ...` or `docker exec`.

Requirements: Docker Engine 24+ or Docker Desktop with the Compose v2
plugin, and about 10 GB of memory for the three nodes. Keycloak and
PostgreSQL are deployed with the same sizing as on VMs — raise Docker
Desktop's memory limit rather than shrinking the thing under test. arm64
works (Apple silicon).

## How it works

- Nodes run `privileged`, with systemd as PID 1 and a private cgroup
  namespace (`HA_CGROUP_MODE=host` switches to the host's, should your
  Docker need it). `/run` and `/run/lock` are tmpfs; `/dev/shm` is 1 GB for
  PostgreSQL's dynamic shared memory.
- Every node has a fixed address on the `kc-ha` bridge (`HA_PREFIX`
  replaces the `172.28.0` prefix if it collides with something). That
  address is the node's `host` in cluster.yml, exactly as with VMs: etcd,
  Patroni, HAProxy, JGroups and the TLS SANs bind to it.
- `dev/ha-up.sh` generates an ssh key in `.dev/containers/`, installs it for
  `ubuntu` on every node and runs `./configure` from the control container.
  Ansible then reaches the nodes over ssh — the production path, not the
  Docker connection plugin — so the pgBackRest ssh mesh and host-key handling
  are exercised too.
- `roles/common` detects a container (`keelinfra_container_mode`) and leaves
  hostname, kernel parameters and chrony to the container host. Everything
  else runs unchanged.

## What the rig is not

- Not a VM. The nodes share the host kernel: no kernel parameters, no
  chrony, no keepalived VIP (`vip: ""`). A sysctl, firewall or boot-time
  problem only shows up on the single-node VM smoke or on real machines.
- Not a performance reference. Install durations and stop-start windows
  measured here describe the rig on its host, not a production topology.
- Not a deployment option. Privileged systemd containers are a test harness.

## Caveats

- Do not `docker restart` a node mid-drill: Docker regenerates `/etc/hosts`
  on restart and drops the block `roles/common` wrote. The fixed
  `extra_hosts` entries survive, so names still resolve, but the next play
  will report a change.
- `./configure` runs as root inside the control container, so `inventory/`
  and `.dev/containers/` are root-owned on Linux hosts. `dev/ha-down.sh`
  removes them from inside the container for that reason.
- Recreating the nodes changes their ssh host keys; `dev/ha-up.sh` clears
  the control container's `known_hosts` before configuring.
- `inventory/` belongs to one cluster at a time. `dev/ha-up.sh` refuses to
  overwrite one it did not render (a Multipass cluster from `dev/up.sh`,
  say); `--force` re-renders it anyway.
