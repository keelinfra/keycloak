# Supported upgrade paths

Every path listed here has been executed end-to-end: install the source version,
create realms/users/sessions, run `./upgrade`, and assert that logged-in sessions
survive — see "What the session drill proves" below for the exact assertions
behind that claim.

**We do not list an upgrade path we have not run.**

Every listed path runs nightly in CI on a clean single-node install
([upgrade matrix](https://github.com/keelinfra/keycloak/actions/workflows/upgrade-matrix.yml)):
install the source version, log in, upgrade, and assert the pre-upgrade session
still refreshes on the target version. Some paths have additionally been drilled
on a 3-node HA cluster — the Notes column says which.

**Don't see your path?**
[Request it](https://github.com/keelinfra/keycloak/issues/new?template=upgrade_path_request.yml).
We drill it in CI first, and list it only if it passes; if it fails, we publish
what broke. Paths *off* a stream with no community artifacts — 26.2 in
particular — are the ones we most want to hear about.

| From | To | Strategy | Sessions survive | Verified on | Notes |
|---|---|---|---|---|---|
| 26.6.0 | 26.6.2 | rolling | ✅ | 2026-08-25 | **3-node HA drilled.** 156/156 probes OK during upgrade — zero downtime ([probe log](https://keelinfra.io/blog/zero-downtime-keycloak-upgrades/)) |
| 26.6.2 | 26.7.0 | stop-start | ✅ | 2026-08-25 | **3-node HA drilled.** ~16s service window measured (staged artifacts, stop → cut over → start); sessions persisted in PostgreSQL across the restart. **Do not stop here** — see "Do not land on 26.7.0–26.7.2" below |
| 26.6.2 | 26.7.5 | stop-start | ✅ | 2026-10-01 | **Single-node CI only** — the 3-node HA drill has not run against this target yet. Same stop-start path as the 26.7.0 row above, which was HA drilled. Listed with target 26.7.3 from 2026-08-31 until 26.7.5 shipped |
| 26.7.0 | 26.7.5 | rolling | ✅ | 2026-10-01 | **Single-node CI only** — the 3-node HA drill has not run yet. This is the way off 26.7.0–26.7.2. Listed with target 26.7.3 from 2026-08-31 until 26.7.5 shipped |
| 26.7.3 | 26.7.5 | rolling | ✅ | 2026-10-01 | **Single-node CI only.** The patch path for installs made with this distribution's 26.7.3 default |
| 26.7.3 | 26.8.0 | stop-start | ✅ | 2026-10-01 | **Single-node CI only.** Minor upgrade — see "26.8.0 on a cluster built with this distribution" below for what the migration touches |
| 26.7.5 | 26.8.0 | stop-start | ✅ | 2026-10-01 | **Single-node CI only.** Same migration as the row above |

## Do not land on 26.7.0–26.7.2

[26.7.3](https://github.com/keycloak/keycloak/releases/tag/26.7.3) (2026-08-31)
fixes 20 CVEs and six weaknesses, and repairs regressions introduced inside the
26.7 stream itself:

| Upstream | What breaks on 26.7.0–26.7.2 |
|---|---|
| [#51523](https://github.com/keycloak/keycloak/issues/51523) | Sustained high CPU on every node after upgrading |
| [#51554](https://github.com/keycloak/keycloak/issues/51554) | Admin API per-request cost grows super-linearly with realm count (since 26.7.1) |
| [#51707](https://github.com/keycloak/keycloak/issues/51707) | Lightweight access tokens resolve every role in every realm on each admin API request |
| [#51920](https://github.com/keycloak/keycloak/issues/51920) | `OFFLINE_CLIENT_SESSION` write conflicts — "Record has changed since last read" |
| [#52038](https://github.com/keycloak/keycloak/issues/52038) | Client session note removals are not persisted with persistent user sessions |
| [#51792](https://github.com/keycloak/keycloak/issues/51792) | Aurora detection logs an ERROR into the PostgreSQL server log on every startup |

The 26.6.2 → 26.7.0 row above records a run we actually did, so it stays. It is
not the version you should be running.

Neither, any longer, is 26.7.3. [26.7.4](https://github.com/keycloak/keycloak/releases/tag/26.7.4)
(2026-09-16) and [26.7.5](https://github.com/keycloak/keycloak/releases/tag/26.7.5)
(2026-09-30) each carry a further security batch, and
[26.8.0](https://github.com/keycloak/keycloak/releases/tag/26.8.0) shipped on
2026-10-01. Upstream supports one release at a time, so 26.7.5 is the last
community artifact on the 26.7 branch — later 26.7 tags will be RHBK-only, as
26.6.5 and later were — and 26.8 is where the next patches land. A cluster on
26.7.x moves to 26.7.5 (rolling) and then to 26.8.0 (stop-start); a new install
starts on 26.8.0, this distribution's default since 2026-10-01.

## 26.8.0 on a cluster built with this distribution

26.8.0 is a minor release, so the path onto it is stop-start. Of the
[upstream migration notes](https://www.keycloak.org/docs/latest/upgrading/index.html#migrating-to-26-8-0),
these are the items that reach a cluster built here:

- **Login failures are stored in the database by default** (`login-failures:v2`).
  Brute-force lockouts now survive restarts and upgrades; expect a little more
  database connection and CPU use. Nothing to configure.
- **`OFFLINE_USER_SESSION` gains a column and rebuilt indexes** in the schema
  migration the first node runs. Above 300,000 rows upstream skips the index
  during migration and builds it in the background after startup
  (`CREATE INDEX CONCURRENTLY` on PostgreSQL): extra database load for a few
  minutes after the first node is up, not a longer service window.
- **The load-balancer route in `AUTH_SESSION_ID` is deprecated.** HAProxy here
  balances `roundrobin` and never relied on it; the startup warning is noise
  until upstream removes the option.
- **jdbc-ping nodes now check the cluster name.** A node reports itself
  unhealthy if another Keycloak deployment with a different cluster name shares
  its database. Stop-start never runs two deployments at once, so this does not
  trigger here; it matters if you blue-green against one database.
- Not used by this distribution, so not affected: `multi-site` (deprecated),
  `clusterless` (to be removed), `stateless` (now supported, still off) and the
  X.509 authenticator change. The Java requirement is unchanged: OpenJDK 21.

## KeelInfra LTS builds

Upstream cuts patch tags on maintenance branches without publishing community
artifacts — fixes on those tags ship only in Red Hat's commercial build. Two
streams are in that state today, and 26.7 joins them with its first tag after
26.7.5 now that 26.8.0 is out:

| Stream | Community artifacts stop at | Tags continue to | Built and published |
|---|---|---|---|
| 26.2 | 26.2.5 | 26.2.16 | `kc-26.2.16-keel1` |
| 26.6 | 26.6.4 | 26.6.7 | `kc-26.6.5-keel1`, `kc-26.6.6-keel1`, `kc-26.6.7-keel1` |

The 26.6 stream matters more than its size suggests: 26.6.4 → 26.6.6 carries
**12 CVE fixes** in 69 commits, and a cluster left on 26.6.4 has no upstream
route to any of them. Details and build evidence:
[VERIFICATION-26.6.6.md](https://github.com/keelinfra/keycloak/blob/main/lts/VERIFICATION-26.6.6.md).
26.6.7, tagged 2026-09-07, backports September security fixes from the batch
the community got as 26.7.4. It is built and published as
[kc-26.6.7-keel1](https://github.com/keelinfra/keycloak/releases/tag/kc-26.6.7-keel1) (2026-10-01);
its CVEs are not sorted in [CVE-POLICY.md](CVE-POLICY.md) yet.

We build the tags ourselves and publish them as
[`kc-<version>-keel<rev>` releases](https://github.com/keelinfra/keycloak/releases)
(see [lts/](lts/)); `./upgrade --dist-url <release url>` installs them.

| From | To | Strategy | Sessions survive | Verified on | Notes |
|---|---|---|---|---|---|
| 26.2.5 | 26.2.16 ([kc-26.2.16-keel1](https://github.com/keelinfra/keycloak/releases/tag/kc-26.2.16-keel1)) | rolling | ✅ | 2026-08-28 | Single-node CI drill, runs nightly in the matrix: install the last community release, upgrade via `--dist-url`, pre-upgrade session refreshes, full session drill passes. The 3-node HA drill has **not** yet run for this path — Infinispan was upgraded within the 26.2 branch (15.0.16), so a multi-node rolling upgrade briefly mixes Infinispan versions; run the HA drill before relying on rolling there. |
| 26.6.4 | 26.6.6 ([kc-26.6.6-keel1](https://github.com/keelinfra/keycloak/releases/tag/kc-26.6.6-keel1)) | rolling | ✅ | 2026-08-31 | Single-node CI drill, runs nightly in the matrix: install the last community release (26.6.4), upgrade via `--dist-url`, pre-upgrade session refreshes, full session drill passes. The 3-node HA drill has **not** yet run for this path — Infinispan was upgraded within the 26.6 branch (16.0.8 → 16.0.14), so a multi-node rolling upgrade briefly mixes Infinispan versions; run the HA drill before relying on rolling there. |
| 26.6.6 ([kc-26.6.6-keel1](https://github.com/keelinfra/keycloak/releases/tag/kc-26.6.6-keel1)) | 26.7.5 | stop-start | ✅ | 2026-10-01 | Single-node CI drill, runs nightly in the matrix: install the LTS build via `keycloak_dist_url`, upgrade to the last community 26.7 release, pre-upgrade session refreshes, full session drill passes. This is the way off the 26.6 stream; 26.7.5 → 26.8.0 in the table above is the next hop. The 3-node HA drill has **not** yet run for this path. |
| 26.6.6 ([kc-26.6.6-keel1](https://github.com/keelinfra/keycloak/releases/tag/kc-26.6.6-keel1)) | 26.6.7 ([kc-26.6.7-keel1](https://github.com/keelinfra/keycloak/releases/tag/kc-26.6.7-keel1)) | rolling | ✅ | 2026-10-01 | Single-node CI drill, runs nightly in the matrix: install the previous LTS build via `keycloak_dist_url`, upgrade to the branch head via `--dist-url`, pre-upgrade session refreshes, full session drill passes. The 3-node HA drill has **not** yet run for this path; the same Infinispan caveat as the 26.6.4 → 26.6.6 row applies. |
| 26.6.7 ([kc-26.6.7-keel1](https://github.com/keelinfra/keycloak/releases/tag/kc-26.6.7-keel1)) | 26.7.5 | stop-start | ✅ | 2026-10-01 | Single-node CI drill, runs nightly in the matrix: install the LTS build via `keycloak_dist_url`, upgrade to the last community 26.7 release, pre-upgrade session refreshes, full session drill passes. The way off the 26.6 branch head; 26.7.5 → 26.8.0 in the table above is the next hop. The 3-node HA drill has **not** yet run for this path. |

### 26.2: the branch head still has a critical unpatched CVE

The 26.2 row moves you to the head of the branch, not off it — and the head is
still exposed to **CVE-2026-18963** (critical, CVSS 9.1, unauthenticated account
takeover via the reset-credentials flow). Upstream's first patched version for
the 26.0–26.4 range is 26.4.15; there is no patched 26.2 release, so no build of
a 26.2 tag — `kc-26.2.16-keel1` included — can carry the fix. The only route to
a fixed version is a minor upgrade off 26.2 (to 26.6.6 or 26.7.3), which we have
not drilled yet. Impact analysis and interim mitigation:
[CVE-POLICY.md](CVE-POLICY.md).

## Strategies

- **rolling** — patch releases within the same `major.minor` stream (e.g. 26.6.0 → 26.6.2).
  Nodes are drained and replaced one at a time. Zero downtime.
- **stop-start** — minor/major upgrades (e.g. 26.6 → 26.7). The cluster is stopped,
  the database is backed up, the first node runs schema migrations, then all nodes
  return on the new version. Sessions are persisted in PostgreSQL and survive the
  restart; users are not logged out. Expect a short (~1–2 min) service window.

## What the session drill proves

`./verify --drill session` opens an online session and an offline session,
rolling-restarts every node, and then asserts that both refresh, that the
restored session carries the **same session id** (a refresh that quietly issues
a new session is a failure, not a pass), and that its username, realm roles and
scopes are unchanged.

What it does **not** cover: client session notes. Upstream
[#52038](https://github.com/keycloak/keycloak/issues/52038) — note removals not
persisted with persistent user sessions — sits below the token surface the drill
inspects, so a cluster can pass this drill and still have that bug. Reaching it
needs a protocol mapper that projects a client session note into the token; that
is not wired up yet.

## Policy

- A pgBackRest backup is always taken immediately before any upgrade.
- `./upgrade` refuses paths that skip more than one minor version unless
  `--force` is given, matching upstream's supported migration policy.
