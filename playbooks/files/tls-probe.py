#!/usr/bin/env python3
"""Check that ports answer in TLS, not in plaintext.

Usage: tls-probe.py HOST:PORT[:pg] ...

Sends a TLS ClientHello (for :pg, PostgreSQL's SSLRequest first) and looks
at the first bytes that come back. A TLS server answers with a handshake or
an alert record, which is enough: a server that wants a client certificate
we do not send still proves the port speaks TLS. Prints one line per port
and exits 1 if any port answered in plaintext or not at all.
"""

import contextlib
import socket
import ssl
import struct
import sys

PG_SSL_REQUEST = struct.pack("!ii", 8, 80877103)


def client_hello():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    out = ssl.MemoryBIO()
    obj = ctx.wrap_bio(ssl.MemoryBIO(), out, server_side=False)
    with contextlib.suppress(ssl.SSLWantReadError):
        obj.do_handshake()
    return out.read()


def probe(host, port, pg):
    with socket.create_connection((host, port), timeout=5) as sock:
        if pg:
            sock.sendall(PG_SSL_REQUEST)
            answer = sock.recv(1)
            if answer != b"S":
                return "plaintext (PostgreSQL refused SSL: %r)" % answer
        sock.sendall(client_hello())
        head = b""
        while len(head) < 3:
            chunk = sock.recv(3 - len(head))
            if not chunk:
                break
            head += chunk
    # TLS record: content type 21 (alert) or 22 (handshake), version 3.x
    if len(head) == 3 and head[0] in (21, 22) and head[1] == 3:
        return None
    return "plaintext or no TLS answer (first bytes %r)" % head


def main(targets):
    bad = 0
    for target in targets:
        parts = target.split(":")
        host, port, pg = parts[0], int(parts[1]), parts[2:] == ["pg"]
        try:
            problem = probe(host, port, pg)
        except OSError as err:
            problem = "no connection (%s)" % err
        if problem:
            bad += 1
            print("FAIL %s:%d %s" % (host, port, problem))
        else:
            print("ok   %s:%d TLS" % (host, port))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
