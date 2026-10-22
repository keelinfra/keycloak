"""Tests for .github/scripts/distro_sbom.py."""

import contextlib
import io
import json
import os
import pathlib
import re
import runpy
import sys
import tempfile
import unittest
from unittest import mock

from helpers import REPO, load_script

try:
    import yaml  # the script needs it
except ImportError:  # pragma: no cover - CI installs it
    yaml = None

SCRIPT = ".github/scripts/distro_sbom.py"

FIXTURE = {
    "examples/production.yml": 'keycloak_version: "26.1.0"\n',
    "roles/etcd/defaults/main.yml": 'etcd_version: "3.5.9"\n',
    "roles/config_cli/defaults/main.yml": 'config_cli_release: "6.4.0"\n',
    "roles/monitoring/defaults/main.yml": (
        "monitoring_releases:\n"
        "  zz_exporter: {repo: acme/zz_exporter, version: '2.0.0'}\n"
        "  aa_exporter: {repo: acme/aa-exporter, version: '1.2.3'}\n"
    ),
    "playbooks/group_vars/all.yml": "postgres_version: 16\n",
    "requirements.yml": (
        "collections:\n"
        "  - {name: community.general, version: '>=9.0.0'}\n"
        "  - {name: ansible.posix, version: '>=1.5.0'}\n"
    ),
}

OS_PACKAGE_SOURCE = [
    {
        "name": "keelinfra:version-source",
        "value": "installed from the OS or vendor package repository at install time",
    }
]


def write_fixture(root):
    for rel, text in FIXTURE.items():
        path = pathlib.Path(root) / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)


@unittest.skipUnless(yaml, "PyYAML is not installed")
class DistroSbomTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_script(SCRIPT, "distro_sbom")

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = pathlib.Path(tmp.name)
        write_fixture(self.root)

    def run_main(self, argv):
        out = io.StringIO()
        with (
            mock.patch.object(sys, "argv", ["distro_sbom.py", *argv]),
            contextlib.redirect_stdout(out),
        ):
            self.mod.main()
        self.assertTrue(out.getvalue().endswith("}\n"))
        return json.loads(out.getvalue())

    def by_name(self, comps):
        return {c["name"]: c for c in comps}

    def test_github_component(self):
        self.assertEqual(
            self.mod.github("etcd-io/etcd", "v3.5.9", "store"),
            {
                "type": "application",
                "name": "etcd",
                "version": "v3.5.9",
                "description": "store",
                "purl": "pkg:github/etcd-io/etcd@v3.5.9",
                "externalReferences": [
                    {
                        "type": "distribution",
                        "url": "https://github.com/etcd-io/etcd/releases/tag/v3.5.9",
                    }
                ],
            },
        )

    def test_os_package_has_no_version(self):
        c = self.mod.os_package("haproxy", "LB")
        self.assertEqual(
            c,
            {
                "type": "application",
                "name": "haproxy",
                "description": "LB",
                "properties": OS_PACKAGE_SOURCE,
            },
        )

    def test_components_in_order(self):
        names = [c["name"] for c in self.mod.components(self.root)]
        self.assertEqual(
            names,
            [
                "keycloak",
                "etcd",
                "keycloak-config-cli",
                # monitoring releases sorted by their key, named after the repo
                "aa-exporter",
                "zz_exporter",
                "postgresql",
                "patroni",
                "haproxy",
                "keepalived",
                "pgbackrest",
                "grafana",
                "community.general",
                "ansible.posix",
            ],
        )

    def test_pinned_versions_come_from_the_role_files(self):
        comps = self.by_name(self.mod.components(self.root))
        # Keycloak tags have no "v"; etcd, the CLI and the exporters do.
        self.assertEqual(comps["keycloak"]["version"], "26.1.0")
        self.assertEqual(
            comps["keycloak"]["purl"], "pkg:github/keycloak/keycloak@26.1.0"
        )
        self.assertEqual(comps["etcd"]["purl"], "pkg:github/etcd-io/etcd@v3.5.9")
        self.assertEqual(
            comps["keycloak-config-cli"]["purl"],
            "pkg:github/adorsys/keycloak-config-cli@v6.4.0",
        )
        exporter = comps["aa-exporter"]
        self.assertEqual(exporter["purl"], "pkg:github/acme/aa-exporter@v1.2.3")
        self.assertEqual(
            exporter["description"],
            "aa_exporter; RHEL family (Debian family uses the OS package)",
        )

    def test_postgres_has_its_major_version_as_a_string(self):
        pg = self.by_name(self.mod.components(self.root))["postgresql"]
        self.assertEqual(pg["version"], "16")
        self.assertEqual(pg["description"], "PostgreSQL 16, from the PGDG repository")
        self.assertEqual(pg["bom-ref"], "postgresql@16")
        self.assertEqual(pg["properties"], OS_PACKAGE_SOURCE)

    def test_unpinned_packages(self):
        comps = self.by_name(self.mod.components(self.root))
        for name in ("patroni", "haproxy", "keepalived", "pgbackrest", "grafana"):
            self.assertNotIn("version", comps[name])
            self.assertEqual(comps[name]["bom-ref"], name + "@unpinned")
            self.assertEqual(comps[name]["properties"], OS_PACKAGE_SOURCE)

    def test_ansible_collections(self):
        col = self.by_name(self.mod.components(self.root))["community.general"]
        self.assertEqual(
            col,
            {
                "type": "library",
                "name": "community.general",
                "description": "Ansible collection, used on the control machine",
                "properties": [
                    {"name": "keelinfra:version-constraint", "value": ">=9.0.0"}
                ],
                "externalReferences": [
                    {
                        "type": "distribution",
                        "url": "https://galaxy.ansible.com/ui/repo/published/community/general",
                    }
                ],
                "bom-ref": "community.general@unpinned",
            },
        )

    def test_a_missing_file_is_an_error(self):
        (self.root / "requirements.yml").unlink()
        with self.assertRaises(FileNotFoundError):
            self.mod.components(self.root)

    def test_a_renamed_variable_is_an_error(self):
        (self.root / "roles/etcd/defaults/main.yml").write_text('etcd_release: "3"\n')
        with self.assertRaises(KeyError):
            self.mod.components(self.root)

    def test_main_writes_a_cyclonedx_bom(self):
        bom = self.run_main(["1.4.0", str(self.root)])
        self.assertEqual(bom["bomFormat"], "CycloneDX")
        self.assertEqual(bom["specVersion"], "1.6")
        self.assertEqual(bom["version"], 1)
        self.assertRegex(
            bom["serialNumber"],
            r"^urn:uuid:[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
        )
        self.assertRegex(
            bom["metadata"]["timestamp"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$"
        )
        me = bom["metadata"]["component"]
        self.assertEqual(me["bom-ref"], "keelinfra-keycloak@1.4.0")
        self.assertEqual(me["version"], "1.4.0")
        self.assertEqual(me["purl"], "pkg:github/keelinfra/keycloak@v1.4.0")
        self.assertEqual(me["licenses"], [{"license": {"id": "Apache-2.0"}}])
        self.assertEqual(bom["components"], self.mod.components(self.root))
        self.assertEqual(
            bom["dependencies"],
            [
                {
                    "ref": "keelinfra-keycloak@1.4.0",
                    "dependsOn": [c["bom-ref"] for c in bom["components"]],
                }
            ],
        )

    def test_each_run_has_a_new_serial_number(self):
        a = self.run_main(["1.0", str(self.root)])
        b = self.run_main(["1.0", str(self.root)])
        self.assertNotEqual(a["serialNumber"], b["serialNumber"])

    def test_repo_root_defaults_to_the_current_directory(self):
        cwd = os.getcwd()
        self.addCleanup(os.chdir, cwd)
        os.chdir(str(self.root))
        bom = self.run_main(["2.0"])
        self.assertEqual(bom["components"][0]["version"], "26.1.0")

    def test_wrong_argument_count_prints_the_usage(self):
        for argv in ([], ["1.0", ".", "extra"]):
            with (
                mock.patch.object(sys, "argv", ["distro_sbom.py", *argv]),
                self.assertRaises(SystemExit) as cm,
            ):
                self.mod.main()
            self.assertEqual(
                cm.exception.code,
                "Usage: distro_sbom.py <release version> [<repo root>]",
            )

    def test_the_real_repository(self):
        # What release.yml runs: catches a role variable renamed or moved.
        comps = self.mod.components(REPO)
        refs = [c["bom-ref"] for c in comps]
        self.assertEqual(len(refs), len(set(refs)), "bom-refs must be unique")
        names = {c["name"] for c in comps}
        for name in ("keycloak", "etcd", "keycloak-config-cli", "postgresql"):
            self.assertIn(name, names)
        for c in comps:
            if c.get("purl", "").startswith("pkg:github/"):
                self.assertRegex(c["version"], r"^v?\d+(\.\d+)+$", c["name"])

    def test_runs_as_a_script(self):
        out = io.StringIO()
        argv = [SCRIPT, "9.9.9", str(self.root)]
        with mock.patch.object(sys, "argv", argv), contextlib.redirect_stdout(out):
            runpy.run_path(str(REPO / SCRIPT), run_name="__main__")
        bom = json.loads(out.getvalue())
        self.assertEqual(bom["metadata"]["component"]["version"], "9.9.9")
        self.assertTrue(re.match(r"^urn:uuid:", bom["serialNumber"]))


if __name__ == "__main__":
    unittest.main()
