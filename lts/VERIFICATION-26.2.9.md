# Build verification: upstream tag 26.2.9

First feasibility check for the KeelInfra LTS track: prove that an
**unreleased upstream maintenance tag** — one that carries backported fixes
but has no community artifacts — can be built from source and produces a
working server. Executed 2026-08-27.

## Why 26.2.9

Upstream cuts patch tags on maintenance branches for the Red Hat build of
Keycloak but does not release them to the community (no announcement, no
tarball, no image, no Maven artifacts — maintainer statement in upstream
discussion 42779).
Verified empirically the same day:

- Tags `26.2.0` … `26.2.16` exist on `keycloak/keycloak`.
- Published community dist artifacts stop at **26.2.5**
  (`releases/download/26.2.5/keycloak-26.2.5.tar.gz` → HTTP 206;
  `26.2.6`, `26.2.9`, `26.2.16` → HTTP 404).
- So `26.2.6..26.2.16` is the RHBK-only stream. `26.2.9` (2025-09-17) sits
  mid-stream; at verification time the head of the stream was `26.2.16`.

## What is in 26.2.5..26.2.9

99 commits, ~500 files changed. Mix of bug fixes, dependency upgrades
(Quarkus 3.20.2 → 3.20.2.2, Infinispan 15.0.16.Final, MariaDB connector
3.5.3, angus-mail 2.0.4) and security-relevant hardening (unbounded
`login_hint` corrupting the `KC_RESTART` cookie, client policy/scope
configuration validation, admin-role mapping restricted to server admins,
session-store fixes).

**Finding:** commit messages carry **no CVE identifiers**. Mapping a tag to
the CVEs it fixes requires cross-referencing Red Hat's RHBK errata
(RHSA advisories) — that mapping step must be part of any LTS release
process, since customers will ask "which CVEs does this build close?"

## Build

Environment: Ubuntu (kernel 6.18), OpenJDK 21.0.10, 4 vCPU / 15 GB RAM,
Maven via the repo's `mvnw`.

```
git clone --depth 1 --branch 26.2.9 https://github.com/keycloak/keycloak.git
./mvnw -pl quarkus/deployment,quarkus/dist -am -DskipTests clean install
```

**Finding: the tag does not build out of the box.** The ProtoStream
schema-compatibility check (`proto-schema-compatibility-maven-plugin` in
`model/infinispan/pom.xml`) fetches `proto.lock` files from hard-coded
`raw.githubusercontent.com/.../refs/heads/release/26.0/...` URLs at build
time. Upstream has since moved that branch under `archive/release/26.0`, so
the URL returns 404 and the build fails in `keycloak-model-infinispan`.
Fix applied: rewrite the dead URL to its `archive/release/` location
(automated in `build-from-tag.sh`), keeping the compatibility check active
rather than skipping it with `-DskipProtoLock` — serialization
compatibility is precisely the kind of guarantee an LTS build should keep
verifying. Expect more of this drift the older the tag: build-time network
references rot as upstream reorganizes.

With the URL patched: **BUILD SUCCESS** (42 modules; ~4 min total on this
machine including dependency downloads). Artifacts:

```
keycloak-26.2.9.tar.gz  147M  sha256 df731fe7ef7add2ad4268c324e3b57e12678ca46579fba7c4990a4b849c783d0
keycloak-26.2.9.zip     148M  sha256 00f18917b64968b040a2ef219c6a3071a73eba2be8e66e961941aed66eb251d4
```

(Hashes are for this machine's build; the build is not bit-reproducible
across environments and the hashes will differ elsewhere.)

## Smoke test

| Check | Result |
|---|---|
| `kc.sh --version` | `Keycloak 26.2.9` on JVM 21.0.10 |
| `start-dev --health-enabled=true` | started in 11.8 s; log line confirms `Keycloak 26.2.9 … powered by Quarkus 3.20.2.2` — the backported Quarkus upgrade is present in the running server |
| `GET :9000/health/ready` | `{"status": "UP"}` (ready ~20 s after launch) |
| OIDC discovery `realms/master/.well-known/openid-configuration` | issuer + endpoints served |
| Password grant via `admin-cli` for the bootstrap admin | access token issued |

## Conclusions for the LTS track

1. **Feasible.** An unreleased backport tag builds from source with JDK 21
   and runs correctly. The core premise of the LTS model holds.
2. **Two work items surfaced for productization:**
   - a tag→CVE mapping step against RHBK errata for every LTS release note;
   - a patch layer for build-time drift (dead URLs, and likely more on
     older tags), maintained in `build-from-tag.sh`.
3. **Next steps:** build the stream head (26.2.16) the same way; wire the
   built artifact into the existing install/upgrade-matrix CI (install
   26.2.5 → upgrade to self-built 26.2.9+ with the session-survival drill);
   decide artifact naming/branding ("KeelInfra build of Keycloak" — the
   Apache-2.0 grant excludes the Keycloak trademark).
