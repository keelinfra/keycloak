# Build verification: upstream tags 26.6.5 and 26.6.6 (26.6 stream)

Third LTS build run, executed 2026-08-31, and the first on the 26.6 branch —
which became a second RHBK-only stream once upstream moved on to 26.7. Method
and background: see [VERIFICATION-26.2.9.md](VERIFICATION-26.2.9.md). Unlike the
26.2 runs, both tags here were built by the `lts release` workflow on a clean
runner rather than on a workstation, so the hashes below come from CI.

## Why 26.6.5 and 26.6.6

Same shape as `26.2.6..26.2.16`. Checked empirically on 2026-08-31:

| Tag | Upstream release | `keycloak-<tag>.tar.gz` |
|---|---|---|
| 26.6.3 | published | HTTP 206 |
| 26.6.4 | published | HTTP 206 |
| 26.6.5 | none | HTTP 404 |
| 26.6.6 | none | HTTP 404 |
| 26.6.7 | tag does not exist | — |

Community artifacts stop at **26.6.4**; 26.6.6 is the head of the stream.

## What is in 26.6.4..26.6.6

69 commits across 300 files, carrying **12 CVE fixes**:

```
CVE-2026-14614  CVE-2026-15571  CVE-2026-15572  CVE-2026-15573
CVE-2026-16071  CVE-2026-16100  CVE-2026-16102  CVE-2026-16442
CVE-2026-16443  CVE-2026-17048  CVE-2026-18963  CVE-2026-45292
```

Representative fixes, by commit subject:

- Admin REST API leaks vault-resolved rotated client secrets (CVE-2026-17048)
- Fine-grained admin permissions bypass in client scope assignment (CVE-2026-14614)
- Fine-grained admin permissions bypass via the role groups endpoint
- FGAP v2 parent-group children endpoint bypasses the per-child view filter
- `RoleMappingDeleteResource` allows unassigning any role
- WebAuthn authenticator attachment policy is bypassed when the client omits
  the attachment field
- JWE request object signature bypass
- `LDAP_ENTRY_DN` not validated against the configured `usersDn` in
  `searchLDAPByAttributes`
- Rotated client secret stays valid after the feature is disabled
- Updates on the `realm-management` client are no longer allowed
- Cookie-based SSO re-auth resets the brute-force counter; CIBA bypasses
  brute-force protection entirely
- URI normalization in `PathMatcher` to stop authorization bypass via mutated
  paths

A cluster sitting on 26.6.4 is exposed to all of the above with no community
route to a fix. That is the case this stream exists to answer.

## Result

**BUILD SUCCESS** for both tags via the `lts release` workflow — 7m42s for
26.6.5, 7m40s for 26.6.6, each running `build-from-tag.sh` end to end (clone →
patch check → build → hashes) and smoke-testing before publishing.

Published as [`kc-26.6.5-keel1`](https://github.com/keelinfra/keycloak/releases/tag/kc-26.6.5-keel1)
and [`kc-26.6.6-keel1`](https://github.com/keelinfra/keycloak/releases/tag/kc-26.6.6-keel1):

```
cb686a9416833d97a13f73faad4daf15f92b4169ea33c745e36271ccde456a92  keycloak-26.6.5.tar.gz
5af9ed301a88d99e1b320135b8819c85f47e01ec6af83f636d01aee3d1bd77c8  keycloak-26.6.5.zip
4a4271311972fb33af8303e53f1ff5819619c9b2502fd350d7a7206c00203e7d  keycloak-26.6.6.tar.gz
9ba6fc64272f8b6380a60152c7962e1ff18acb6d991f96a55404c31ddd27753f  keycloak-26.6.6.zip
```

(Hashes are for these CI builds; the build is not bit-reproducible across
environments.)

## Smoke test

Run by the workflow against the freshly built tarball, on temurin JDK 21:

| Check | 26.6.5 | 26.6.6 |
|---|---|---|
| `kc.sh --version` matches the tag | ✅ | ✅ |
| `start-dev --health-enabled=true` | started in 12.994 s | started in 13.337 s |
| Quarkus version in the startup banner | 3.33.2.1 | 3.33.3.1 |
| `GET :9000/health/ready` | UP | UP |
| OIDC discovery on `master` | served | served |

The banner versions match `quarkus.version` in each tag's `pom.xml`, which
confirms the dependency backports are present in the running server rather than
only in the source tree.

## Findings

- **No build patch needed.** Neither tag triggered the conditional proto.lock
  URL rewrite in `build-from-tag.sh` — as with 26.2.16, these tags are recent
  enough that `model/infinispan/pom.xml` already points at live URLs. The
  rewrite stays for older tags.
- **Dependency backports continue on the branch**, as they did on 26.2:
  Quarkus 3.33.2.1 in 26.6.5 → 3.33.3.1 in 26.6.6.
- **Infinispan moves inside the branch**, which matters for upgrade strategy:
  16.0.8 in 26.6.4 → 16.0.12 in 26.6.5 → 16.0.14 in 26.6.6. A multi-node
  rolling upgrade therefore briefly mixes Infinispan versions, exactly as on
  the 26.2 stream. The HA drill has to run before rolling is claimed for a
  3-node cluster on this path.
- **Two builds, one upgrade path.** 26.6.5 is published for anyone who needs
  that exact version, but the upgrade matrix only drills 26.6.4 → 26.6.6:
  26.6.6 contains everything in 26.6.5, so a path stopping at 26.6.5 would land
  users short of the stream head with no benefit.

## Remaining next steps

- The 3-node HA drill for 26.6.4 → 26.6.6, which CI cannot cover.
- Tag→CVE mapping against RHBK errata for release notes — now more valuable
  than it was on 26.2, since this stream has 12 CVEs in two tags.
- Artifact naming/branding decision (Apache-2.0 grants no trademark rights to
  the "Keycloak" name) — still open, and now spanning two streams.
