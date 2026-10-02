#!/usr/bin/env python3
"""Print the upgrade-path matrix for a workflow run, as a GITHUB_OUTPUT line.

Both matrices read .github/upgrade-paths.yml through this script:
    upgrade_paths.py                 every row (nightly, workflow_dispatch)
    upgrade_paths.py --pr-smoke      only the rows marked pr_smoke: true
    upgrade_paths.py --only FROM TO STRATEGY [FROM_DIST_URL] [DIST_URL]
                                     one path given by hand (workflow_dispatch)
"""
import json
import pathlib
import sys

import yaml

HERE = pathlib.Path(__file__).resolve().parent
ROWS = yaml.safe_load((HERE.parent / "upgrade-paths.yml").read_text())["paths"]


def main(argv):
    if argv[:1] == ["--only"]:
        extra = argv[1:]
        if len(extra) < 3 or not all(extra[:3]):
            sys.exit("--only needs FROM TO STRATEGY")
        row = {"from": extra[0], "to": extra[1], "strategy": extra[2]}
        if len(extra) > 3 and extra[3]:
            row["from_dist_url"] = extra[3]
        if len(extra) > 4 and extra[4]:
            row["dist_url"] = extra[4]
        rows = [row]
    elif argv == ["--pr-smoke"]:
        rows = [r for r in ROWS if r.get("pr_smoke")]
    elif not argv:
        rows = ROWS
    else:
        sys.exit(__doc__)
    for r in rows:
        missing = {"from", "to", "strategy"} - set(r)
        if missing:
            sys.exit(f"row {r} lacks {sorted(missing)}")
    print("matrix=" + json.dumps({"include": rows}, separators=(",", ":")))


if __name__ == "__main__":
    main(sys.argv[1:])
