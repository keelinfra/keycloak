# EU Cyber Resilience Act

The EU Cyber Resilience Act ([Regulation (EU) 2024/2847](https://eur-lex.europa.eu/eli/reg/2024/2847/oj))
sets security rules for software and hardware sold in the EU. Its reporting duties
apply since 11 September 2026; everything else applies from 11 December 2027.
This page says how keelinfra reads it for its own products, what we already do,
and what is still open. It is our reading, not legal advice, and it is no
substitute for your own assessment of the systems you build on top.

## Our role

The CRA's duties fall on the **manufacturer**: whoever places a product on the
EU market. Open-source software published without any commercial activity is
outside the regulation, but charging for technical support beyond cost recovery
counts as commercial activity (recital 15). keelinfra sells subscriptions and
services for what it publishes, so we treat ourselves as the manufacturer of:

| Product | What it is | Identified by |
|---|---|---|
| **The distribution** | The playbooks, roles and tooling in this repository | Release tags `vMAJOR.MINOR.PATCH` |
| **keelinfra LTS builds of Keycloak** | Server distributions we build from upstream maintenance tags ([lts/](lts/)) | Release tags `kc-<upstream tag>-keel<revision>` |

Keycloak, PostgreSQL, Patroni, etcd, HAProxy and the other software the
distribution installs are **components** we integrate. Their own projects make
them; we choose them with care, track their vulnerabilities, and report what we
find in them upstream.

Both products deploy or are an identity management system, which Annex III
lists as an **important product, class I**. For free and open-source products in
Annex III, Article 32(5) allows the manufacturer's own conformity assessment
(internal control) provided the technical documentation is public. We intend to
use that route, so the documentation will live in this repository.

## Reporting, in force since 11 September 2026

If we learn that a vulnerability in one of our products is actively exploited,
or of a severe incident affecting their security, we notify through ENISA's
[Single Reporting Platform](https://portal.cra-srp.enisa.europa.eu) to the CSIRT
designated as coordinator for our main establishment:

- an early warning within **24 hours** of becoming aware;
- a notification within **72 hours**, with the measures users can take;
- a final report within **14 days** of a fix or mitigation being available
  (one month after the notification, for an incident).

We tell affected users at the same time, through a GitHub security advisory on
this repository and by email to subscribers, with what to do.

For a vulnerability in a component, we report it to the project that maintains
it (Article 13(6)), and, if it reaches deployments made with the distribution,
handle it as described in [CVE-POLICY.md](CVE-POLICY.md).

## What we do today

| The CRA asks for | Where it is met |
|---|---|
| A vulnerability disclosure policy and a contact address (Annex I part II) | [SECURITY.md](SECURITY.md): private reports through GitHub, acknowledged within 3 business days |
| Vulnerabilities fixed without delay, with free security updates and a public advisory (Annex I part II) | [SECURITY.md](SECURITY.md); fixes ship on `main` and in the next release, with a GitHub security advisory |
| A stated support period (Article 13(8), Annex II) | [SECURITY.md](SECURITY.md#supported-versions) |
| An SBOM covering at least the top-level dependencies (Annex I part II) | Releases from October 2026 on carry a CycloneDX SBOM: the distribution's lists the components it installs and their versions; an LTS build's lists the libraries inside the Keycloak server |
| Updates whose integrity users can check (Annex I part I) | Every release carries `SHA256SUMS`; from October 2026 on, also signed build-provenance and SBOM attestations: `gh attestation verify <file> --repo keelinfra/keycloak` shows it came unmodified from our release workflow |
| Secure by default (Annex I part I) | TLS to Keycloak and between every node, secrets in ansible-vault, key-only SSH: see [DEPLOYMENT.md](DEPLOYMENT.md) |
| Monitoring and handling vulnerabilities in components (Article 13(5)–(6)) | [CVE-POLICY.md](CVE-POLICY.md): we track upstream releases, sort CVEs by what they reach, and drill the upgrade that fixes them. A daily [workflow](.github/workflows/cra-monitor.yml) checks the SBOM of every release still in its support period against OSV and opens an issue when a vulnerability in it is actively exploited (CISA KEV, ENISA EUVD) |
| Information for users: secure installation, use and upgrade (Annex II) | [DEPLOYMENT.md](DEPLOYMENT.md), [UPGRADES.md](UPGRADES.md), [RUNBOOKS.md](RUNBOOKS.md) |

## Still open before 11 December 2027

- **Written cybersecurity risk assessment** for each product (Article 13(2)).
- **Technical documentation** gathered per Annex VII, public in this repository.
- **Checksums for every download.** The Prometheus components are already
  checked against upstream `sha256sums.txt`; the Keycloak server, etcd and
  keycloak-config-cli downloads are not yet.
- **EU declaration of conformity and CE marking**, once the assessment above is
  done.

Questions about how this applies to your own products: [hello@keelinfra.io](mailto:hello@keelinfra.io?subject=CRA%20question).
