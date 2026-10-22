"""Shared helpers for the tests of the repository's Python scripts.

The scripts live in non-package directories and have hyphens in their names,
so they are loaded by path. Certificates are made with the openssl command
line tool, and servers listen on 127.0.0.1 only.
"""

import calendar
import importlib.util
import pathlib
import queue
import socket
import ssl
import subprocess
import sys
import threading
import time

REPO = pathlib.Path(__file__).resolve().parent.parent


def load_script(relpath, name):
    """Import the script at REPO/relpath as a module called name."""
    path = REPO / relpath
    spec = importlib.util.spec_from_file_location(name, str(path))
    module = importlib.util.module_from_spec(spec)
    # Leave no __pycache__ next to the scripts under roles/ and playbooks/.
    saved, sys.dont_write_bytecode = sys.dont_write_bytecode, True
    try:
        spec.loader.exec_module(module)
    finally:
        sys.dont_write_bytecode = saved
    return module


def openssl(*args, cwd=None):
    return subprocess.run(
        ["openssl", *args],
        cwd=cwd,
        check=True,
        capture_output=True,
        text=True,
    ).stdout


def self_signed(directory, name, days, cn=None):
    """Write name.crt and name.key in directory; return the two paths."""
    crt = pathlib.Path(directory) / (name + ".crt")
    key = pathlib.Path(directory) / (name + ".key")
    openssl(
        "req",
        "-x509",
        "-newkey",
        "ec",
        "-pkeyopt",
        "ec_paramgen_curve:prime256v1",
        "-nodes",
        "-keyout",
        str(key),
        "-out",
        str(crt),
        "-days",
        str(days),
        "-subj",
        "/CN=" + (cn or name),
    )
    return str(crt), str(key)


def openssl_not_after(crt):
    """Expiry of a PEM certificate as Unix time, as openssl reads it."""
    line = openssl("x509", "-noout", "-enddate", "-in", str(crt)).strip()
    stamp = line.split("=", 1)[1]  # e.g. "Nov 21 20:40:00 2026 GMT"
    return calendar.timegm(time.strptime(stamp, "%b %d %H:%M:%S %Y %Z"))


def openssl_sha256(crt):
    """SHA-256 fingerprint of a PEM certificate, as openssl prints it."""
    line = openssl("x509", "-noout", "-fingerprint", "-sha256", "-in", str(crt))
    return line.strip().split("=", 1)[1]  # "AB:CD:..."


def free_port():
    """A port on 127.0.0.1 that nothing listens on (right now)."""
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def recv_exactly(conn, n):
    data = b""
    while len(data) < n:
        chunk = conn.recv(n - len(data))
        if not chunk:
            break
        data += chunk
    return data


def server_context(crt, key, client_ca=None):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    # No TLS 1.3 session tickets: a client that closes without reading them
    # would make the kernel reset the connection under the server's feet.
    ctx.num_tickets = 0
    ctx.load_cert_chain(crt, key)
    if client_ca:
        ctx.verify_mode = ssl.CERT_REQUIRED
        ctx.load_verify_locations(client_ca)
    return ctx


class TCPServer:
    """Accept connections on 127.0.0.1 in a thread and pass each to handle.

    Whatever handle returns goes to self.results; errors go there too, so a
    test can wait for the server side of a connection to finish.
    """

    def __init__(self, handle):
        self.handle = handle
        self.results = queue.Queue()
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(8)
        self.sock.settimeout(0.1)
        self.port = self.sock.getsockname()[1]
        self.target = "127.0.0.1:%d" % self.port
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def _run(self):
        while not self._stop.is_set():
            try:
                conn, _ = self.sock.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            conn.settimeout(5)
            with conn:
                try:
                    self.results.put(self.handle(conn))
                except Exception as err:  # noqa: BLE001 - handed to the test
                    self.results.put(err)

    def result(self, timeout=5):
        return self.results.get(timeout=timeout)

    def close(self):
        self._stop.set()
        self._thread.join(5)
        self.sock.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
