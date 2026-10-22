"""Tests for dev/containers/webhook-sink.py, run as the rig runs it."""

import http.client
import pathlib
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest

from helpers import REPO, free_port

SCRIPT = REPO / "dev/containers/webhook-sink.py"


class WebhookSinkTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.log = pathlib.Path(tmp.name) / "alerts.log"
        self.port = free_port()
        self.proc = subprocess.Popen(
            [sys.executable, str(SCRIPT), str(self.port), str(self.log)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.addCleanup(self.stop)
        deadline = time.time() + 10
        while True:
            try:
                socket.create_connection(("127.0.0.1", self.port), timeout=1).close()
                break
            except OSError:
                if self.proc.poll() is not None or time.time() > deadline:
                    self.fail("webhook-sink did not start: %r" % (self.stop(),))
                time.sleep(0.05)

    def stop(self):
        if self.proc.stdout.closed:
            return b"", b""
        if self.proc.poll() is None:
            # SIGINT, not SIGKILL: lets a coverage run save its data.
            self.proc.send_signal(signal.SIGINT)
            try:
                self.proc.wait(5)
            except subprocess.TimeoutExpired:  # pragma: no cover
                self.proc.kill()
        out, err = self.proc.communicate()
        self.proc.stdout.close()
        self.proc.stderr.close()
        return out, err

    def request(self, method, body=None, headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            conn.request(method, "/", body=body, headers=headers or {})
            resp = conn.getresponse()
            return resp.status, resp.getheader("Content-Length"), resp.read()
        finally:
            conn.close()

    def test_appends_one_line_per_post(self):
        first = b'{"status": "firing",\n "alerts": [{"labels": {"a": "1"}}]}\n'
        second = b'{"status": "resolved"}'
        self.assertEqual(self.request("POST", first), (200, "0", b""))
        self.assertEqual(self.request("POST", second), (200, "0", b""))
        self.assertEqual(
            self.log.read_bytes(),
            b'{"status": "firing",  "alerts": [{"labels": {"a": "1"}}]} \n'
            b'{"status": "resolved"}\n',
        )

    def test_a_post_without_body_logs_an_empty_line(self):
        self.assertEqual(self.request("POST"), (200, "0", b""))
        self.assertEqual(self.log.read_bytes(), b"\n")

    def test_keeps_what_the_log_already_holds(self):
        self.log.write_bytes(b"earlier\n")
        self.request("POST", b"later")
        self.assertEqual(self.log.read_bytes(), b"earlier\nlater\n")

    def test_only_post_is_answered(self):
        status, _, _ = self.request("GET")
        self.assertEqual(status, 501)
        self.assertFalse(self.log.exists())

    def test_no_access_log(self):
        self.request("POST", b"{}")
        self.request("GET")
        _, err = self.stop()
        lines = [x for x in err.decode().splitlines() if "POST" in x or "GET" in x]
        self.assertEqual(lines, [], "requests must not be logged on stderr")


if __name__ == "__main__":
    unittest.main()
