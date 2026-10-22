#!/usr/bin/env python3
"""Report what this node's TLS trust stores trust, for ./install and ./verify.

Usage: trust-store.py --bundle FILE [--keytool PATH --java-store FILE]
                      [--distrust SHA256 ...] [--service NAME]

--bundle      the system's PEM bundle (what OpenSSL, Go and Python trust)
--java-store  the JDK's cacerts (what Keycloak trusts for outgoing TLS);
              read with --keytool, so it works for JKS and PKCS12 alike
--distrust    SHA-256 fingerprints (hex, colons optional) that must not be
              trusted
--service     a systemd unit running a JVM: report when it started, so the
              caller can tell whether it loaded the current Java store

Prints one JSON object:
  bundle_count, java_count
  distrusted_in_bundle, distrusted_in_java   fingerprints still trusted
  java_not_in_bundle   aliases the Java store trusts but the system bundle
                       no longer does: a store that missed a removal
  java_store_mtime     Unix time the Java store was last written
  service_started      Unix time the service's main process started, or null
"""

import argparse
import base64
import hashlib
import json
import os
import re
import subprocess

PEM = re.compile(
    r"-----BEGIN CERTIFICATE-----\s*(.+?)\s*-----END CERTIFICATE-----", re.DOTALL
)
ALIAS = re.compile(r"^Alias name: (.+)$", re.MULTILINE)


def fingerprint(b64):
    return hashlib.sha256(base64.b64decode("".join(b64.split()))).hexdigest()


def bundle_fingerprints(path):
    with open(path) as f:
        return {fingerprint(m) for m in PEM.findall(f.read())}


def java_store(keytool, path):
    """alias -> fingerprint for every trusted certificate in a Java store."""
    out = subprocess.run(
        [keytool, "-list", "-rfc", "-keystore", path, "-storepass", "changeit"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    ).stdout
    entries = {}
    # keytool prints "Alias name: x", some fields, then the certificate.
    for block in re.split(r"(?=^Alias name: )", out, flags=re.MULTILINE):
        alias, pem = ALIAS.search(block), PEM.search(block)
        if alias and pem:
            entries[alias.group(1).strip()] = fingerprint(pem.group(1))
    return entries


def service_started(unit):
    try:
        pid = subprocess.run(
            ["systemctl", "show", "-p", "MainPID", "--value", unit],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        ).stdout.strip()
    except FileNotFoundError:  # no systemd: nothing runs it as a unit
        return None
    if not pid.isdigit() or pid == "0":
        return None
    with open("/proc/stat") as f:
        btime = int(next(x for x in f if x.startswith("btime")).split()[1])
    with open("/proc/%s/stat" % pid) as f:
        # Field 22, counted after the command name, which may hold spaces.
        start_ticks = int(f.read().rsplit(")", 1)[1].split()[19])
    return btime + start_ticks / os.sysconf("SC_CLK_TCK")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bundle", required=True)
    ap.add_argument("--keytool")
    ap.add_argument("--java-store")
    ap.add_argument("--distrust", nargs="*", default=[])
    ap.add_argument("--service")
    args = ap.parse_args()

    distrust = {d.replace(":", "").lower() for d in args.distrust}
    bundle = bundle_fingerprints(args.bundle)
    report = {
        "bundle_count": len(bundle),
        "distrusted_in_bundle": sorted(bundle & distrust),
        "java_count": None,
        "distrusted_in_java": [],
        "java_not_in_bundle": [],
        "java_store_mtime": None,
        "service_started": None,
    }
    # No JDK here (yet): nothing else to read.
    have_java = args.keytool and os.path.exists(args.keytool)
    if have_java and args.java_store and os.path.exists(args.java_store):
        java = java_store(args.keytool, args.java_store)
        report["java_count"] = len(java)
        report["distrusted_in_java"] = sorted(set(java.values()) & distrust)
        report["java_not_in_bundle"] = sorted(
            a for a, fp in java.items() if fp not in bundle
        )
        report["java_store_mtime"] = os.stat(args.java_store).st_mtime
    if args.service:
        report["service_started"] = service_started(args.service)
    print(json.dumps(report))


if __name__ == "__main__":
    main()
