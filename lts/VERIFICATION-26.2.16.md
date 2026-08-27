# Build verification: upstream tag 26.2.16 (stream head)

Second LTS feasibility check, executed 2026-08-27 — the head of the
RHBK-only maintenance stream at verification time. Method and background:
see [VERIFICATION-26.2.9.md](VERIFICATION-26.2.9.md). This run also
exercised `build-from-tag.sh` end-to-end (clone → patch check → build →
hashes) rather than manual steps.

## Result

**BUILD SUCCESS** via `./build-from-tag.sh 26.2.16` (script exit 0).

```
keycloak-26.2.16.tar.gz  sha256 dbff6ace6d9f95536254c7778f08db88f7ec7fea196e51e7eefb711e10664f64
keycloak-26.2.16.zip     sha256 9a81ed2c128e554ef24c7cf5acd2b19ca0230ce3e2d7345abec16ca7c70849dc
```

(Hashes are for this machine's build; not bit-reproducible across
environments.)

## Smoke test

| Check | Result |
|---|---|
| `kc.sh --version` | `Keycloak 26.2.16` on JVM 21.0.10 |
| `start-dev --health-enabled=true` | started in 15.1 s; log confirms `Keycloak 26.2.16 … powered by Quarkus 3.20.6` |
| `GET :9000/health/ready` | UP (~28 s after launch) |
| OIDC discovery | issuer + endpoints served |
| Password grant, bootstrap admin | access token issued |

## Findings vs 26.2.9

- **No build patch needed.** 26.2.16 was tagged after upstream archived the
  26.0/26.1 release branches, so its `model/infinispan/pom.xml` already
  points at `archive/release/...` proto.lock URLs. The script's conditional
  URL rewrite correctly did nothing. This confirms the URL-rot issue is
  tag-age-dependent: older tags need the patch, newer ones don't.
- **Dependency backports continue on the branch:** Quarkus 3.20.2.2 in
  26.2.9 → 3.20.6 in 26.2.16.

## Remaining next steps for the LTS track

- Wire a self-built tarball into the install/upgrade-matrix CI. The role
  now supports this: set `keycloak_dist_url` to wherever the built tarball
  is hosted (default remains the upstream GitHub release URL). The drill to
  add: install 26.2.5 (last community release) → upgrade to a self-built
  26.2.x → assert the pre-upgrade session survives.
- Tag→CVE mapping against RHBK errata for release notes.
- Artifact naming/branding decision (Apache-2.0 grants no trademark
  rights to the "Keycloak" name).
