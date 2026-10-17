#!/usr/bin/env python3
"""Write the CycloneDX SBOM of a distribution release to stdout.

The distribution ships playbooks and roles, not binaries: its components are
what those roles download or install on the nodes. Versions come from the
same files the roles read, so the SBOM cannot drift from what gets deployed:

- pinned upstream releases (etcd, the Prometheus exporters on the RHEL
  family, keycloak-config-cli), with the exact version;
- Keycloak, at the version the examples recommend (operators pick their own
  with keycloak_version);
- PostgreSQL at its pinned major version;
- packages taken from the operating system or the vendor repository at
  install time (Patroni, HAProxy, keepalived, pgBackRest, Grafana), which
  have no fixed version in the release;
- the Ansible collections from requirements.yml, with their minimum version.

Usage: distro_sbom.py <release version> [<repo root>]
"""

import datetime
import json
import pathlib
import sys
import uuid

import yaml


def load(root, rel):
    return yaml.safe_load((root / rel).read_text())


def github(owner_repo, version, description):
    name = owner_repo.split("/")[1]
    return {
        "type": "application",
        "name": name,
        "version": version,
        "description": description,
        "purl": f"pkg:github/{owner_repo}@{version}",
        "externalReferences": [
            {
                "type": "distribution",
                "url": f"https://github.com/{owner_repo}/releases/tag/{version}",
            },
        ],
    }


def os_package(name, description):
    return {
        "type": "application",
        "name": name,
        "description": description,
        "properties": [
            {
                "name": "keelinfra:version-source",
                "value": "installed from the OS or vendor package repository at install time",
            }
        ],
    }


def components(root):
    out = []

    kc = load(root, "examples/production.yml")["keycloak_version"]
    out.append(
        github(
            "keycloak/keycloak",
            kc,
            "Keycloak server; version recommended by the examples, set per cluster with keycloak_version",
        )
    )

    etcd = load(root, "roles/etcd/defaults/main.yml")["etcd_version"]
    out.append(
        github(
            "etcd-io/etcd",
            f"v{etcd}",
            "Distributed configuration store used by Patroni",
        )
    )

    cli = load(root, "roles/config_cli/defaults/main.yml")["config_cli_release"]
    out.append(
        github(
            "adorsys/keycloak-config-cli",
            f"v{cli}",
            "Applies realm configuration from YAML",
        )
    )

    releases = load(root, "roles/monitoring/defaults/main.yml")["monitoring_releases"]
    for name, rel in sorted(releases.items()):
        c = github(
            rel["repo"],
            f"v{rel['version']}",
            f"{name}; RHEL family (Debian family uses the OS package)",
        )
        out.append(c)

    pg = load(root, "playbooks/group_vars/all.yml")["postgres_version"]
    postgres = os_package("postgresql", f"PostgreSQL {pg}, from the PGDG repository")
    postgres["version"] = str(pg)
    out.append(postgres)

    for name, desc in [
        ("patroni", "PostgreSQL high-availability manager"),
        ("haproxy", "Load balancer in front of PostgreSQL and Keycloak"),
        ("keepalived", "Virtual IP failover"),
        ("pgbackrest", "PostgreSQL backup and restore"),
        ("grafana", "Dashboards, from the Grafana package repository"),
    ]:
        out.append(os_package(name, desc))

    for col in load(root, "requirements.yml")["collections"]:
        out.append(
            {
                "type": "library",
                "name": col["name"],
                "description": "Ansible collection, used on the control machine",
                "properties": [
                    {"name": "keelinfra:version-constraint", "value": col["version"]}
                ],
                "externalReferences": [
                    {
                        "type": "distribution",
                        "url": "https://galaxy.ansible.com/ui/repo/published/"
                        + col["name"].replace(".", "/"),
                    },
                ],
            }
        )

    for c in out:
        c["bom-ref"] = f"{c['name']}@{c.get('version', 'unpinned')}"
    return out


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__.strip().splitlines()[-1])
    version = sys.argv[1]
    root = pathlib.Path(sys.argv[2] if len(sys.argv) == 3 else ".")
    comps = components(root)
    bom = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.6",
        "serialNumber": f"urn:uuid:{uuid.uuid4()}",
        "version": 1,
        "metadata": {
            "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime(
                "%Y-%m-%dT%H:%M:%SZ"
            ),
            "component": {
                "type": "application",
                "bom-ref": f"keelinfra-keycloak@{version}",
                "name": "keelinfra-keycloak",
                "version": version,
                "description": "Self-hosted Keycloak distribution: playbooks and roles for an HA cluster",
                "licenses": [{"license": {"id": "Apache-2.0"}}],
                "purl": f"pkg:github/keelinfra/keycloak@v{version}",
            },
            "supplier": {"name": "keelinfra", "url": ["https://keelinfra.io"]},
        },
        "components": comps,
        "dependencies": [
            {
                "ref": f"keelinfra-keycloak@{version}",
                "dependsOn": [c["bom-ref"] for c in comps],
            },
        ],
    }
    json.dump(bom, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
