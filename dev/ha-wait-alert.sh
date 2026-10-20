#!/usr/bin/env bash
# Wait until the container rig's alert webhook receives a firing ALERT for
# NODE, sent after this script starts. CI runs it after losing the first
# node: the alert must still go out, from the second node's Prometheus and
# Alertmanager.
# Usage: dev/ha-wait-alert.sh KeycloakDown kc-node1 [timeout seconds, default 420]
set -euo pipefail
# shellcheck source=dev/containers/lib.sh
source "$(dirname "$0")/containers/lib.sh"
ALERT="${1:-}" NODE="${2:-}" TIMEOUT="${3:-420}"
[[ -n "$ALERT" && -n "$NODE" ]] || { sed -n '2,6p' "$0"; exit 1; }

log="$HA_STATE_DIR/alerts.log"
skip=$(wc -l < "$log" 2>/dev/null || echo 0)
deadline=$((SECONDS + TIMEOUT))
echo "Waiting up to ${TIMEOUT}s for $ALERT on $NODE to reach the webhook"
# Prints the sending Alertmanager and exits 0 once a matching notification
# is in the log; the sink writes one JSON document per line.
until tail -n "+$((skip + 1))" "$log" 2>/dev/null | python3 -c '
import json, sys
alert, node = sys.argv[1:]
for line in sys.stdin:
    try:
        msg = json.loads(line)
    except ValueError:
        continue
    for a in msg.get("alerts", []):
        labels = a.get("labels", {})
        if a.get("status") == "firing" and labels.get("alertname") == alert and labels.get("instance") == node:
            print("%s on %s reached the webhook, sent by the Alertmanager at %s" % (alert, node, msg.get("externalURL")))
            sys.exit(0)
sys.exit(1)
' "$ALERT" "$NODE"; do
  if ((SECONDS >= deadline)); then
    echo "error: no firing $ALERT for $NODE reached the webhook within ${TIMEOUT}s" >&2
    exit 1
  fi
  sleep 10
done
