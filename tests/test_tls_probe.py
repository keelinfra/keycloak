"""Tests for playbooks/files/tls-probe.py."""

import contextlib
import io
import runpy
import shutil
import socket
import sys
import tempfile
import time
import unittest
from unittest import mock

from helpers import (
    REPO,
    TCPServer,
    free_port,
    load_script,
    recv_exactly,
    self_signed,
    server_context,
)

SCRIPT = "playbooks/files/tls-probe.py"
PG_SSL_REQUEST = b"\x00\x00\x00\x08\x04\xd2\x16\x2f"  # length 8, code 80877103
TLS_ALERT = b"\x15\x03\x03\x00\x02\x02\x28"  # fatal handshake_failure


def read_hello(conn):
    """Read the client's whole first TLS record and return it.

    All of it: closing with unread data would reset the connection.
    """
    head = recv_exactly(conn, 5)
    return head + recv_exactly(conn, int.from_bytes(head[3:5], "big"))


class TLSProbeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_script(SCRIPT, "tls_probe")

    def run_main(self, targets):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = self.mod.main(targets)
        return code, out.getvalue().splitlines()

    def server(self, handle):
        server = TCPServer(handle)
        self.addCleanup(server.close)
        return server

    def answering(self, *chunks, pg_answer=None):
        """A server that answers the ClientHello with the given bytes."""

        def handle(conn):
            if pg_answer is not None:
                request = recv_exactly(conn, 8)
                conn.sendall(pg_answer)
                if pg_answer != b"S":
                    return request
            hello = read_hello(conn)
            conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            for chunk in chunks:
                conn.sendall(chunk)
                time.sleep(0.05)
            return hello

        return self.server(handle)

    def test_client_hello_is_a_tls_handshake_record(self):
        hello = self.mod.client_hello()
        self.assertEqual(hello[0], 22, "handshake record")
        self.assertEqual(hello[1], 3, "TLS major version")
        self.assertEqual(hello[5], 1, "ClientHello message")
        self.assertEqual(len(hello) - 5, int.from_bytes(hello[3:5], "big"))

    def test_a_handshake_answer_is_tls(self):
        server = self.answering(b"\x16\x03\x03\x00\x7a")
        self.assertEqual(
            self.run_main([server.target]), (0, ["ok   %s TLS" % server.target])
        )
        self.assertEqual(server.result()[:2], b"\x16\x03", "a ClientHello was sent")

    def test_an_alert_answer_is_tls(self):
        # e.g. a port that wants a client certificate, or no common cipher
        server = self.answering(TLS_ALERT)
        self.assertEqual(
            self.run_main([server.target]), (0, ["ok   %s TLS" % server.target])
        )

    def test_an_answer_split_over_several_packets(self):
        server = self.answering(b"\x16", b"\x03", b"\x01")
        self.assertEqual(
            self.run_main([server.target]), (0, ["ok   %s TLS" % server.target])
        )

    @unittest.skipUnless(shutil.which("openssl"), "openssl is not installed")
    def test_a_real_tls_server(self):
        with tempfile.TemporaryDirectory() as d:
            ctx = server_context(*self_signed(d, "server", 2))

        def handle(conn):
            with contextlib.suppress(OSError):  # the probe hangs up mid-handshake
                ctx.wrap_socket(conn, server_side=True)

        server = self.server(handle)
        self.assertEqual(
            self.run_main([server.target]), (0, ["ok   %s TLS" % server.target])
        )

    def test_a_plaintext_answer_fails(self):
        server = self.answering(b"HTTP/1.1 400 Bad Request\r\n\r\n")
        self.assertEqual(
            self.run_main([server.target]),
            (
                1,
                [
                    "FAIL %s plaintext or no TLS answer (first bytes b'HTT')"
                    % server.target
                ],
            ),
        )

    def test_ssl_2_or_other_versions_fail(self):
        server = self.answering(b"\x16\x02\x00")
        code, lines = self.run_main([server.target])
        self.assertEqual(code, 1)
        self.assertIn("plaintext or no TLS answer", lines[0])

    def test_a_port_that_hangs_up_fails(self):
        server = self.answering()
        self.assertEqual(
            self.run_main([server.target]),
            (
                1,
                [
                    "FAIL %s plaintext or no TLS answer (first bytes b'')"
                    % server.target
                ],
            ),
        )

    def test_a_short_answer_fails(self):
        server = self.answering(b"\x15\x03")
        self.assertEqual(
            self.run_main([server.target]),
            (
                1,
                [
                    r"FAIL %s plaintext or no TLS answer (first bytes b'\x15\x03')"
                    % server.target
                ],
            ),
        )

    def test_a_closed_port_fails(self):
        target = "127.0.0.1:%d" % free_port()
        code, lines = self.run_main([target])
        self.assertEqual(code, 1)
        self.assertRegex(lines[0], r"^FAIL %s no connection \(.*refused" % target)

    def test_postgres_with_ssl(self):
        server = self.answering(TLS_ALERT, pg_answer=b"S")
        target = server.target + ":pg"
        self.assertEqual(self.run_main([target]), (0, ["ok   %s TLS" % server.target]))
        self.assertEqual(server.result()[:2], b"\x16\x03")

    def test_postgres_without_ssl(self):
        server = self.answering(pg_answer=b"N")
        target = server.target + ":pg"
        self.assertEqual(
            self.run_main([target]),
            (1, ["FAIL %s plaintext (PostgreSQL refused SSL: b'N')" % server.target]),
        )
        self.assertEqual(server.result(), PG_SSL_REQUEST)

    def test_a_non_pg_suffix_is_plain_tls(self):
        server = self.answering(TLS_ALERT)
        self.assertEqual(
            self.run_main([server.target + ":other"]),
            (0, ["ok   %s TLS" % server.target]),
        )
        self.assertEqual(server.result()[:2], b"\x16\x03", "no SSLRequest first")

    def test_one_line_per_port_and_failure_if_any_fails(self):
        good = self.answering(TLS_ALERT)
        bad = self.answering(b"SSH-2.0-OpenSSH\r\n")
        code, lines = self.run_main([good.target, bad.target])
        self.assertEqual(code, 1)
        self.assertEqual(lines[0], "ok   %s TLS" % good.target)
        self.assertTrue(lines[1].startswith("FAIL %s plaintext" % bad.target))

    def test_no_targets_pass(self):
        self.assertEqual(self.run_main([]), (0, []))

    def test_runs_as_a_script_with_the_exit_code(self):
        target = "127.0.0.1:%d" % free_port()
        out = io.StringIO()
        with (
            mock.patch.object(sys, "argv", [SCRIPT, target]),
            contextlib.redirect_stdout(out),
            self.assertRaises(SystemExit) as cm,
        ):
            runpy.run_path(str(REPO / SCRIPT), run_name="__main__")
        self.assertEqual(cm.exception.code, 1)
        self.assertTrue(out.getvalue().startswith("FAIL %s no connection" % target))


if __name__ == "__main__":
    unittest.main()
