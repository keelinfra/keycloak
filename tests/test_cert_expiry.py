"""Tests for playbooks/files/cert-expiry.py."""

import calendar
import contextlib
import datetime
import io
import json
import os
import runpy
import shutil
import ssl
import sys
import tempfile
import time
import types
import unittest
from unittest import mock

from helpers import (
    REPO,
    TCPServer,
    free_port,
    load_script,
    openssl_not_after,
    recv_exactly,
    self_signed,
    server_context,
)

try:
    import cryptography  # the script needs it
except ImportError:  # pragma: no cover - CI installs it
    cryptography = None

SCRIPT = "playbooks/files/cert-expiry.py"
PG_SSL_REQUEST = b"\x00\x00\x00\x08\x04\xd2\x16\x2f"  # length 8, code 80877103


@unittest.skipUnless(cryptography, "cryptography is not installed")
@unittest.skipUnless(shutil.which("openssl"), "openssl is not installed")
class CertExpiryTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_script(SCRIPT, "cert_expiry")
        cls.tmp = tempfile.TemporaryDirectory()
        d = cls.tmp.name
        # Different lifetimes, so each certificate has its own expiry.
        cls.server_crt, cls.server_key = self_signed(d, "server", 40, cn="localhost")
        cls.other_crt, _ = self_signed(d, "other", 90)
        cls.client_crt, cls.client_key = self_signed(d, "client", 20)
        cls.server_expiry = openssl_not_after(cls.server_crt)
        cls.other_expiry = openssl_not_after(cls.other_crt)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_main(self, argv):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.mod.main(list(argv))
        return json.loads(out.getvalue())

    def tls_server(self, client_ca=None, pg_answer=None):
        ctx = server_context(self.server_crt, self.server_key, client_ca)

        def handle(conn):
            seen = {}
            if pg_answer is not None:
                seen["pg_request"] = recv_exactly(conn, 8)
                conn.sendall(pg_answer)
                if pg_answer != b"S":
                    return seen
            with ctx.wrap_socket(conn, server_side=True) as tls:
                seen["client_cert"] = tls.getpeercert()
                with contextlib.suppress(OSError):
                    tls.recv(1)  # until the client closes
            return seen

        server = TCPServer(handle)
        self.addCleanup(server.close)
        return server

    # not_after()

    def test_not_after_reads_pem_text(self):
        with open(self.server_crt) as f:
            self.assertEqual(self.mod.not_after(f.read()), self.server_expiry)

    def test_not_after_reads_der_bytes(self):
        with open(self.other_crt) as f:
            der = ssl.PEM_cert_to_DER_cert(f.read())
        self.assertEqual(self.mod.not_after(der), self.other_expiry)

    @unittest.skipUnless(hasattr(time, "tzset"), "needs time.tzset")
    def test_not_after_with_cryptography_older_than_42(self):
        # EL9 ships cryptography 36: no not_valid_after_utc, but a naive time
        # in UTC, which must not be read in the node's local time zone.
        old = types.SimpleNamespace(
            not_valid_after=datetime.datetime(2030, 1, 2, 3, 4, 5)
        )
        self.addCleanup(time.tzset)
        with (
            mock.patch.dict(os.environ, {"TZ": "XST+05"}),
            mock.patch(
                "cryptography.x509.load_pem_x509_certificate", return_value=old
            ) as load,
        ):
            time.tzset()
            got = self.mod.not_after("PEM")
        load.assert_called_once_with(b"PEM")
        self.assertEqual(got, calendar.timegm((2030, 1, 2, 3, 4, 5)))

    def test_not_after_rejects_what_is_not_a_certificate(self):
        with self.assertRaises(ValueError):
            self.mod.not_after("not a certificate")

    # main() on files

    def test_files_on_disk(self):
        self.assertEqual(
            self.run_main([self.server_crt, self.other_crt]),
            {self.server_crt: self.server_expiry, self.other_crt: self.other_expiry},
        )

    def test_a_missing_file_is_reported_not_fatal(self):
        missing = os.path.join(self.tmp.name, "nope.crt")
        out = self.run_main([missing, self.other_crt])
        self.assertTrue(out[missing].startswith("FileNotFoundError: "), out)
        self.assertEqual(out[self.other_crt], self.other_expiry)

    def test_a_file_that_is_not_a_certificate(self):
        out = self.run_main([self.server_key])
        self.assertTrue(out[self.server_key].startswith("ValueError: "), out)

    def test_no_targets_prints_an_empty_object(self):
        self.assertEqual(self.run_main([]), {})

    # main() on ports

    def test_served_certificate(self):
        server = self.tls_server()
        self.assertEqual(
            self.run_main([server.target]), {server.target: self.server_expiry}
        )
        self.assertEqual(server.result(), {"client_cert": None})

    def test_client_certificate_is_offered(self):
        server = self.tls_server(client_ca=self.client_crt)
        argv = ["--cert", self.client_crt, "--key", self.client_key, server.target]
        self.assertEqual(self.run_main(argv), {server.target: self.server_expiry})
        subject = dict(x[0] for x in server.result()["client_cert"]["subject"])
        self.assertEqual(subject, {"commonName": "client"})

    def test_options_may_follow_the_targets(self):
        server = self.tls_server(client_ca=self.client_crt)
        argv = [server.target, "--key", self.client_key, "--cert", self.client_crt]
        self.assertEqual(self.run_main(argv), {server.target: self.server_expiry})
        self.assertIsNotNone(server.result()["client_cert"])

    def test_cert_without_key_is_not_offered(self):
        server = self.tls_server()
        argv = ["--cert", self.client_crt, server.target]
        self.assertEqual(self.run_main(argv), {server.target: self.server_expiry})
        self.assertEqual(server.result(), {"client_cert": None})

    def test_an_unreadable_client_key_is_reported_per_port(self):
        missing = os.path.join(self.tmp.name, "nope.key")
        target = "127.0.0.1:%d" % free_port()
        out = self.run_main(["--cert", self.client_crt, "--key", missing, target])
        self.assertTrue(out[target].startswith("FileNotFoundError: "), out)

    def test_postgres_ssl_request(self):
        server = self.tls_server(pg_answer=b"S")
        target = server.target + ":pg"
        self.assertEqual(self.run_main([target]), {target: self.server_expiry})
        self.assertEqual(server.result()["pg_request"], PG_SSL_REQUEST)

    def test_postgres_without_ssl(self):
        server = self.tls_server(pg_answer=b"N")
        target = server.target + ":pg"
        self.assertEqual(self.run_main([target]), {target: "PostgreSQL refused SSL"})
        self.assertEqual(server.result()["pg_request"], PG_SSL_REQUEST)

    def test_a_closed_port_is_reported_not_fatal(self):
        server = self.tls_server()
        closed = "127.0.0.1:%d" % free_port()
        out = self.run_main([closed, server.target, self.other_crt])
        self.assertTrue(out[closed].startswith("ConnectionRefusedError: "), out)
        self.assertEqual(out[server.target], self.server_expiry)
        self.assertEqual(out[self.other_crt], self.other_expiry)

    def test_a_plaintext_port_is_reported(self):
        def handle(conn):
            conn.recv(1024)
            conn.sendall(b"HTTP/1.1 400 Bad Request\r\n\r\n")

        server = TCPServer(handle)
        self.addCleanup(server.close)
        out = self.run_main([server.target])
        self.assertTrue(out[server.target].startswith("SSLError: "), out)

    def test_a_target_without_port_is_reported(self):
        self.assertEqual(
            self.run_main(["localhost"]),
            {"localhost": "IndexError: list index out of range"},
        )

    def test_runs_as_a_script(self):
        out = io.StringIO()
        with (
            mock.patch.object(sys, "argv", [SCRIPT, self.other_crt]),
            contextlib.redirect_stdout(out),
        ):
            runpy.run_path(str(REPO / SCRIPT), run_name="__main__")
        self.assertEqual(
            out.getvalue(), '{"%s": %d}\n' % (self.other_crt, self.other_expiry)
        )


if __name__ == "__main__":
    unittest.main()
