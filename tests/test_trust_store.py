"""Tests for roles/common/files/trust-store.py."""

import contextlib
import io
import json
import os
import pathlib
import runpy
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

from helpers import REPO, load_script, openssl_sha256, self_signed

SCRIPT = "roles/common/files/trust-store.py"
KEYTOOL = shutil.which("keytool")


def plain(fp):
    """openssl's AB:CD:... fingerprint as the script reports it."""
    return fp.replace(":", "").lower()


def write_executable(path, text):
    path = pathlib.Path(path)
    path.write_text(text)
    path.chmod(0o755)
    return str(path)


@unittest.skipUnless(shutil.which("openssl"), "openssl is not installed")
class TrustStoreTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_script(SCRIPT, "trust_store")
        cls.tmp = tempfile.TemporaryDirectory()
        d = pathlib.Path(cls.tmp.name)
        cls.dir = d
        cls.crt = {}
        for name in ("alpha", "beta", "gamma"):
            cls.crt[name], _ = self_signed(d, name, 5)
        cls.fp = {n: openssl_sha256(c) for n, c in cls.crt.items()}
        cls.pem = {n: pathlib.Path(c).read_text() for n, c in cls.crt.items()}
        # A system bundle: comments and blank lines between certificates,
        # the way update-ca-trust and update-ca-certificates write them.
        cls.bundle = str(d / "bundle.pem")
        pathlib.Path(cls.bundle).write_text(
            "# Alpha Root CA\n"
            + cls.pem["alpha"]
            + "\n# Beta Root CA\n\n"
            + cls.pem["beta"]
        )

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_main(self, *argv):
        out = io.StringIO()
        with (
            mock.patch.object(sys, "argv", ["trust-store.py", *argv]),
            contextlib.redirect_stdout(out),
        ):
            self.mod.main()
        return json.loads(out.getvalue())

    def tempdir(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        return pathlib.Path(tmp.name)

    def fake_keytool(self, listing, exit_code=0):
        """A keytool that prints listing and records its arguments."""
        d = self.tempdir()
        (d / "listing").write_text(listing)
        tool = write_executable(
            d / "keytool",
            '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s"\ncat "%s"\nexit %d\n'
            % (d / "args", d / "listing", exit_code),
        )
        return tool, d / "args"

    def listing(self, *entries):
        """keytool -list -rfc output for (alias, pem or None) entries."""
        out = "Keystore type: PKCS12\nKeystore provider: SUN\n\n"
        out += "Your keystore contains %d entries\n\n" % len(entries)
        for alias, pem in entries:
            out += "Alias name: %s\nCreation date: Oct 1, 2026\n" % alias
            out += "Entry type: trustedCertEntry\n\n"
            out += (pem or "") + "\n\n*******************************************\n\n"
        return out

    # fingerprints

    def test_fingerprint_matches_openssl(self):
        body = "".join(self.pem["alpha"].splitlines()[1:-1])
        self.assertEqual(self.mod.fingerprint(body), plain(self.fp["alpha"]))

    def test_fingerprint_ignores_line_breaks_and_spaces(self):
        body = "\n".join(self.pem["beta"].splitlines()[1:-1])
        self.assertEqual(
            self.mod.fingerprint("  " + body + " \n"), plain(self.fp["beta"])
        )

    def test_bundle_fingerprints(self):
        self.assertEqual(
            self.mod.bundle_fingerprints(self.bundle),
            {plain(self.fp["alpha"]), plain(self.fp["beta"])},
        )

    def test_a_certificate_twice_in_the_bundle_counts_once(self):
        path = self.tempdir() / "dup.pem"
        path.write_text(self.pem["alpha"] + self.pem["alpha"])
        self.assertEqual(
            self.mod.bundle_fingerprints(str(path)), {plain(self.fp["alpha"])}
        )

    # the bundle alone

    def test_bundle_only_report(self):
        self.assertEqual(
            self.run_main("--bundle", self.bundle),
            {
                "bundle_count": 2,
                "distrusted_in_bundle": [],
                "java_count": None,
                "distrusted_in_java": [],
                "java_not_in_bundle": [],
                "java_store_mtime": None,
                "service_started": None,
            },
        )

    def test_distrusted_fingerprints_with_colons_and_upper_case(self):
        report = self.run_main(
            "--bundle",
            self.bundle,
            "--distrust",
            self.fp["beta"],  # AB:CD:... as openssl prints it
            plain(self.fp["gamma"]),  # not in the bundle
        )
        self.assertEqual(report["distrusted_in_bundle"], [plain(self.fp["beta"])])

    def test_empty_distrust_list(self):
        # trust_report.yml passes "--distrust" with nothing after it when
        # distrusted_cas is empty.
        report = self.run_main("--bundle", self.bundle, "--distrust")
        self.assertEqual(report["distrusted_in_bundle"], [])
        self.assertEqual(report["bundle_count"], 2)

    def test_bundle_is_required(self):
        with (
            mock.patch.object(sys, "argv", ["trust-store.py"]),
            contextlib.redirect_stderr(io.StringIO()) as err,
            self.assertRaises(SystemExit) as cm,
        ):
            self.mod.main()
        self.assertEqual(cm.exception.code, 2)
        self.assertIn("--bundle", err.getvalue())

    def test_a_missing_bundle_is_an_error(self):
        with self.assertRaises(FileNotFoundError):
            self.run_main("--bundle", str(self.dir / "nope.pem"))

    # the Java store, through a stand-in keytool

    def test_java_store_parsing(self):
        keytool, args = self.fake_keytool(
            self.listing(
                ("alpha", self.pem["alpha"]),
                ("my gamma ca", self.pem["gamma"]),
                ("no-certificate", None),
            )
        )
        self.assertEqual(
            self.mod.java_store(keytool, "/some/cacerts"),
            {"alpha": plain(self.fp["alpha"]), "my gamma ca": plain(self.fp["gamma"])},
        )
        self.assertEqual(
            args.read_text().split("\n")[:-1],
            ["-list", "-rfc", "-keystore", "/some/cacerts", "-storepass", "changeit"],
        )

    def test_keytool_failure_is_an_error(self):
        keytool, _ = self.fake_keytool("", exit_code=1)
        with self.assertRaises(subprocess.CalledProcessError):
            self.mod.java_store(keytool, "/some/cacerts")

    def test_report_with_a_java_store(self):
        keytool, _ = self.fake_keytool(
            self.listing(
                ("alpha", self.pem["alpha"]),
                ("beta", self.pem["beta"]),
                ("gamma", self.pem["gamma"]),
            )
        )
        store = self.tempdir() / "cacerts"
        store.write_bytes(b"store")
        os.utime(str(store), (1700000000, 1700000000))
        report = self.run_main(
            "--bundle",
            self.bundle,
            "--keytool",
            keytool,
            "--java-store",
            str(store),
            "--distrust",
            self.fp["beta"],
            self.fp["gamma"],
        )
        self.assertEqual(report["java_count"], 3)
        self.assertEqual(
            report["distrusted_in_java"],
            sorted([plain(self.fp["beta"]), plain(self.fp["gamma"])]),
        )
        self.assertEqual(report["distrusted_in_bundle"], [plain(self.fp["beta"])])
        self.assertEqual(report["java_not_in_bundle"], ["gamma"])
        self.assertEqual(report["java_store_mtime"], 1700000000)

    def test_no_keytool_yet(self):
        store = self.tempdir() / "cacerts"
        store.write_bytes(b"store")
        for keytool in (None, str(self.dir / "no-jdk" / "keytool")):
            argv = ["--bundle", self.bundle, "--java-store", str(store)]
            if keytool:
                argv += ["--keytool", keytool]
            report = self.run_main(*argv)
            self.assertIsNone(report["java_count"])
            self.assertIsNone(report["java_store_mtime"])
            self.assertEqual(report["java_not_in_bundle"], [])

    def test_no_java_store_yet(self):
        keytool, args = self.fake_keytool(self.listing(("alpha", self.pem["alpha"])))
        for store in (None, str(self.dir / "nope")):
            argv = ["--bundle", self.bundle, "--keytool", keytool]
            if store:
                argv += ["--java-store", store]
            report = self.run_main(*argv)
            self.assertIsNone(report["java_count"])
        self.assertFalse(args.exists(), "keytool must not run")

    # a real keytool

    @unittest.skipUnless(KEYTOOL, "keytool is not installed")
    def test_real_keytool_pkcs12_and_jks(self):
        for storetype in ("PKCS12", "JKS"):
            with self.subTest(storetype=storetype):
                store = self.tempdir() / "cacerts"
                for alias in ("Alpha CA", "gamma"):
                    subprocess.run(
                        [KEYTOOL, "-importcert", "-noprompt", "-alias", alias]
                        + ["-file", self.crt[alias.split()[0].lower()]]
                        + ["-keystore", str(store), "-storetype", storetype]
                        + ["-storepass", "changeit"],
                        check=True,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                    )
                report = self.run_main(
                    "--bundle",
                    self.bundle,
                    "--keytool",
                    KEYTOOL,
                    "--java-store",
                    str(store),
                    "--distrust",
                    self.fp["alpha"],
                )
                self.assertEqual(report["java_count"], 2)
                self.assertEqual(
                    report["distrusted_in_java"], [plain(self.fp["alpha"])]
                )
                self.assertEqual(report["java_not_in_bundle"], ["gamma"])
                self.assertEqual(
                    report["java_store_mtime"], os.stat(str(store)).st_mtime
                )

    # --service

    def fake_systemctl(self, main_pid):
        d = self.tempdir()
        write_executable(
            d / "systemctl",
            '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s"\necho "%s"\n'
            % (d / "args", main_pid),
        )
        return {"PATH": str(d)}, d / "args"

    def test_service_not_running(self):
        for pid in ("0", "", "[not set]"):
            env, args = self.fake_systemctl(pid)
            with mock.patch.dict(os.environ, env):
                self.assertIsNone(self.mod.service_started("keycloak"))
            self.assertEqual(
                args.read_text().split("\n")[:-1],
                ["show", "-p", "MainPID", "--value", "keycloak"],
            )

    def test_no_systemd(self):
        with mock.patch.dict(os.environ, {"PATH": str(self.tempdir())}):
            self.assertIsNone(self.mod.service_started("keycloak"))
            report = self.run_main("--bundle", self.bundle, "--service", "keycloak")
        self.assertIsNone(report["service_started"])

    @unittest.skipUnless(os.path.exists("/proc/stat"), "needs Linux /proc")
    def test_service_start_time(self):
        # A command name with ") " in it: the stat line must be split after
        # the last ")".
        sleep = self.tempdir() / "sl) e e p"
        os.symlink(shutil.which("sleep"), str(sleep))
        before = time.time()
        proc = subprocess.Popen([str(sleep), "30"])
        after = time.time()
        self.addCleanup(proc.wait)
        self.addCleanup(proc.kill)
        with open("/proc/%d/stat" % proc.pid) as f:
            self.assertIn("(sl) e e p)", f.read())
        env, _ = self.fake_systemctl(proc.pid)
        with mock.patch.dict(os.environ, env):
            report = self.run_main("--bundle", self.bundle, "--service", "keycloak")
        # btime has whole seconds and may drift a little from the wall clock.
        started = report["service_started"]
        self.assertIsInstance(started, float)
        self.assertGreater(started, before - 5)
        self.assertLess(started, after + 5)

    def test_runs_as_a_script(self):
        out = io.StringIO()
        with (
            mock.patch.object(sys, "argv", [SCRIPT, "--bundle", self.bundle]),
            contextlib.redirect_stdout(out),
        ):
            runpy.run_path(str(REPO / SCRIPT), run_name="__main__")
        self.assertEqual(json.loads(out.getvalue())["bundle_count"], 2)


if __name__ == "__main__":
    unittest.main()
