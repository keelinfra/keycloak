#!/usr/bin/env python3
"""Print when certificates expire, on disk and as served.

Usage: cert-expiry.py [--cert FILE --key FILE] TARGET ...

A TARGET is a path to a PEM certificate, or HOST:PORT[:pg] for a port to
connect to (for :pg, PostgreSQL's SSLRequest first). The client certificate,
when given, is offered to ports that require one (etcd, the exporters). The
served certificate is read without verifying it: the point is which
certificate a service holds, not whether to trust it.

Prints one JSON object: TARGET -> expiry as Unix time, or an error string.
"""
import datetime
import json
import os
import socket
import ssl
import struct
import sys

PG_SSL_REQUEST = struct.pack("!ii", 8, 80877103)


def not_after(cert):
    from cryptography import x509
    loaded = (x509.load_der_x509_certificate(cert) if isinstance(cert, bytes)
              else x509.load_pem_x509_certificate(cert.encode()))
    when = getattr(loaded, "not_valid_after_utc", None)
    if when is None:
        when = loaded.not_valid_after.replace(tzinfo=datetime.timezone.utc)
    return int(when.timestamp())


def served(target, cert, key):
    parts = target.split(":")
    host, port, pg = parts[0], int(parts[1]), parts[2:] == ["pg"]
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    if cert and key:
        ctx.load_cert_chain(cert, key)
    with socket.create_connection((host, port), timeout=5) as sock:
        if pg:
            sock.sendall(PG_SSL_REQUEST)
            if sock.recv(1) != b"S":
                return "PostgreSQL refused SSL"
        with ctx.wrap_socket(sock) as tls:
            return not_after(tls.getpeercert(binary_form=True))


def main(argv):
    cert = key = None
    targets = []
    while argv:
        arg = argv.pop(0)
        if arg == "--cert":
            cert = argv.pop(0)
        elif arg == "--key":
            key = argv.pop(0)
        else:
            targets.append(arg)
    out = {}
    for target in targets:
        try:
            if os.path.sep in target:
                with open(target) as f:
                    out[target] = not_after(f.read())
            else:
                out[target] = served(target, cert, key)
        except Exception as err:  # reported per target, never fatal
            out[target] = "%s: %s" % (type(err).__name__, err)
    print(json.dumps(out))


if __name__ == "__main__":
    main(sys.argv[1:])
