# Supported upgrade paths

Every path listed here has been executed end-to-end by our verification suite:
install the source version on a 3-node HA cluster, create realms/users/sessions,
run `./upgrade`, and assert that logged-in sessions survive and data is intact.

**We do not list an upgrade path we have not run.**

Every listed path also runs nightly in CI on a clean single-node install
([upgrade matrix](https://github.com/keelinfra/keycloak/actions/workflows/upgrade-matrix.yml)):
install the source version, log in, upgrade, and assert the pre-upgrade session
still refreshes on the target version.

| From | To | Strategy | Sessions survive | Verified on | Notes |
|---|---|---|---|---|---|
| 26.6.0 | 26.6.2 | rolling | ✅ | 2026-08-25 | 156/156 probes OK during upgrade — zero downtime ([probe log](https://keelinfra.io/blog/zero-downtime-keycloak-upgrades/)) |
| 26.6.2 | 26.7.0 | stop-start | ✅ | 2026-08-25 | ~16s service window measured (staged artifacts, stop → cut over → start); sessions persisted in PostgreSQL across the restart |

## KeelInfra LTS builds

Upstream cuts patch tags on maintenance branches (e.g. `26.2.6..26.2.16`)
without publishing community artifacts — fixes on those tags ship only in
Red Hat's commercial build. We build the tags ourselves and publish them as
[`kc-<version>-keel<rev>` releases](https://github.com/keelinfra/keycloak/releases)
(see [lts/](lts/)); `./upgrade --dist-url <release url>` installs them.

| From | To | Strategy | Sessions survive | Verified on | Notes |
|---|---|---|---|---|---|
| 26.2.5 | 26.2.16 ([kc-26.2.16-keel1](https://github.com/keelinfra/keycloak/releases/tag/kc-26.2.16-keel1)) | rolling | ✅ | 2026-08-28 | Single-node CI drill, runs nightly in the matrix: install the last community release, upgrade via `--dist-url`, pre-upgrade session refreshes, full session drill passes. The 3-node HA drill has **not** yet run for this path — Infinispan was upgraded within the 26.2 branch (15.0.16), so a multi-node rolling upgrade briefly mixes Infinispan versions; run the HA drill before relying on rolling there. |

## Strategies

- **rolling** — patch releases within the same `major.minor` stream (e.g. 26.6.0 → 26.6.2).
  Nodes are drained and replaced one at a time. Zero downtime.
- **stop-start** — minor/major upgrades (e.g. 26.6 → 26.7). The cluster is stopped,
  the database is backed up, the first node runs schema migrations, then all nodes
  return on the new version. Sessions are persisted in PostgreSQL and survive the
  restart; users are not logged out. Expect a short (~1–2 min) service window.

## Policy

- A pgBackRest backup is always taken immediately before any upgrade.
- `./upgrade` refuses paths that skip more than one minor version unless
  `--force` is given, matching upstream's supported migration policy.
