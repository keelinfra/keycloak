#!/usr/bin/env python3
"""Collect Red Hat build of Keycloak CVE data and map fixes to the 26.2 line.

Output: JSON to stdout with
  - fixed_262: CVEs with an affected_release row naming RHBK 26.2[.x]
  - state_262: package_state rows for the 26.2 line (affected / oos / notaffected)
  - all: compact index of every RHBK CVE seen
Source: Red Hat Security Data API (public, no auth).
"""
import json, sys, time, urllib.request

BASE = "https://access.redhat.com/hydra/rest/securitydata"

def get(url):
    for attempt in range(3):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "curl/8.6.0"})
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.load(r)
        except Exception as e:
            if attempt == 2:
                print(f"FAIL {url}: {e}", file=sys.stderr)
                return None
            time.sleep(2)

# 1. enumerate all RHBK CVEs since the 26.2 era began
cves = []
page = 1
while True:
    batch = get(f"{BASE}/cve.json?product=Red%20Hat%20build%20of%20Keycloak&per_page=100&page={page}&after=2025-04-01")
    if not batch:
        break
    cves.extend(batch)
    if len(batch) < 100:
        break
    page += 1
print(f"index: {len(cves)} CVEs", file=sys.stderr)

fixed_262, state_262, index = [], [], []
for i, c in enumerate(cves):
    cve_id = c.get("CVE")
    d = get(f"{BASE}/cve/{cve_id}.json")
    if not d:
        continue
    sev = d.get("threat_severity")
    score = (d.get("cvss3") or {}).get("cvss3_base_score")
    desc = (d.get("bugzilla") or {}).get("description") or ""
    index.append({"cve": cve_id, "severity": sev, "cvss3": score,
                  "public": (d.get("public_date") or "")[:10], "desc": desc})
    for r in d.get("affected_release", []):
        pn = r.get("product_name", "")
        if pn.startswith("Red Hat build of Keycloak 26.2"):
            fixed_262.append({"cve": cve_id, "severity": sev, "cvss3": score,
                              "product": pn, "package": r.get("package"),
                              "advisory": r.get("advisory"),
                              "date": (r.get("release_date") or "")[:10],
                              "desc": desc})
    for s in d.get("package_state", []):
        pn = s.get("product_name", "")
        if "Keycloak 26.2" in pn or pn == "Red Hat build of Keycloak":
            state_262.append({"cve": cve_id, "severity": sev, "cvss3": score,
                              "product": pn, "state": s.get("fix_state"),
                              "public": (d.get("public_date") or "")[:10],
                              "desc": desc})
    if (i + 1) % 25 == 0:
        print(f"  detail {i+1}/{len(cves)}", file=sys.stderr)

json.dump({"fixed_262": fixed_262, "state_262": state_262, "all": index},
          sys.stdout, indent=1)
