# Security Policy

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub:
[**Report a vulnerability**](https://github.com/keelinfra/keycloak/security/advisories/new)
(Security tab → Report a vulnerability).

Do not open a public issue for security reports.

You will get an acknowledgment within 3 business days. We keep you informed while we validate and fix the issue, coordinate disclosure with you, and credit you in the advisory unless you prefer otherwise.

## Scope

This repository is a distribution: the playbooks, roles, and defaults that deploy Keycloak, PostgreSQL/Patroni, etcd, HAProxy, pgBackRest, Prometheus, and Grafana.

**In scope**

- Insecure defaults shipped by this distribution: TLS configuration, exposed listeners, file permissions, secret handling in inventories and vaults
- Privilege escalation or secret disclosure caused by our playbooks or roles
- Flaws in the install/upgrade/backup/verify tooling that could corrupt or expose data

**Out of scope**

- Vulnerabilities in upstream Keycloak, PostgreSQL, HAProxy, etc. — report those to the upstream project. When a fixed upstream CVE affects deployments made by this distribution, we ship the version bump and document any required operator action in [UPGRADES.md](UPGRADES.md). How we triage upstream CVEs, and what we do and do not commit to doing about them, is in [CVE-POLICY.md](CVE-POLICY.md).

## Supported versions

Security updates are free, for everyone, subscription or not.

- **The distribution** is supported until at least **31 December 2031**. Security fixes land on `main` and in the next release (`vMAJOR.MINOR.PATCH`); until tagged releases begin, the latest commit on `main` is the supported version. Upgrading to the latest release is how you get a fix, and every upgrade path it needs is drilled in CI ([UPGRADES.md](UPGRADES.md)).
- **keelinfra LTS builds of Keycloak** (`kc-<tag>-keel<n>`): the newest build on a branch is supported while upstream keeps tagging that branch. When it stops, the fix is the drilled upgrade to a supported stream, described in [CVE-POLICY.md](CVE-POLICY.md).

When a fix ships we publish a GitHub security advisory saying who is affected and what to do. How this maps to the EU Cyber Resilience Act, including how we report actively exploited vulnerabilities, is in [CRA.md](CRA.md).
