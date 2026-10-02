#!/usr/bin/env bash
# Drill one upgrade path on the 3-node container rig, end to end — what the
# nightly HA matrix runs, and what a developer runs to reproduce a row:
#   install FROM on three nodes, log in, probe every node's load balancer
#   once a second while ./upgrade --to TO runs, read the probes, assert all
#   three nodes run TO and every balancer sees every node UP, refresh the
#   pre-upgrade session, then ./verify with the failover, restore and
#   session drills. Leaves .dev/containers/receipt.md.
#
# Usage: dev/ha-drill.sh --from 26.7.3 --to 26.7.5 --strategy rolling
#            [--from-dist-url URL] [--dist-url URL] [--max-window SECONDS]
#   --from-dist-url / --dist-url: where to download the tarballs from (default
#   upstream's GitHub release). They are cached in .dev/dist-cache/<version>/
#   and served to the nodes from the control container, so each release is
#   downloaded once, not once per node per run.
# Env:  HA_SKIP_BUILD=1  images are already built (CI)
#       HA_MAX_WINDOW    stop-start sanity bound in seconds, default 180
# A rolling path must answer 200 to every probe; a stop-start path reports
# its service window and fails only above the sanity bound. On failure the
# rig stays up for inspection; dev/ha-down.sh removes it.
set -euo pipefail
# shellcheck source=dev/containers/lib.sh
source "$(dirname "$0")/containers/lib.sh"
cd "$HA_ROOT"

FROM="" TO="" STRATEGY="" FROM_URL="" TO_URL="" MAX_WINDOW="${HA_MAX_WINDOW:-180}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)          FROM="$2"; shift 2 ;;
    --to)            TO="$2"; shift 2 ;;
    --strategy)      STRATEGY="$2"; shift 2 ;;
    --from-dist-url) FROM_URL="$2"; shift 2 ;;
    --dist-url)      TO_URL="$2"; shift 2 ;;
    --max-window)    MAX_WINDOW="$2"; shift 2 ;;
    -h|--help)       sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done
for v in "$FROM" "$TO"; do
  [[ "$v" =~ ^26\.[0-9]+\.[0-9]+$ ]] || { echo "error: --from and --to must look like 26.x.y" >&2; exit 1; }
done
[[ "$STRATEGY" == rolling || "$STRATEGY" == stop-start ]] || { echo "error: --strategy must be rolling or stop-start" >&2; exit 1; }
: "${FROM_URL:=https://github.com/keycloak/keycloak/releases/download/$FROM/keycloak-$FROM.tar.gz}"
: "${TO_URL:=https://github.com/keycloak/keycloak/releases/download/$TO/keycloak-$TO.tar.gz}"
ha_require_docker

DIST_CACHE="$HA_ROOT/.dev/dist-cache"
RECEIPT="$HA_STATE_DIR/receipt.md"
TOKEN_URL_PATH="/realms/demo/protocol/openid-connect/token"
PROBE_PATH="/realms/demo/.well-known/openid-configuration"
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RESULT="FAILED before the first phase"
CURRENT="" PHASE_START=0
TIMINGS=() PROBE_REPORTS=() SHA_FROM="" SHA_TO=""

phase_begin() { CURRENT="$1"; PHASE_START=$SECONDS; ha_group "$1"; }
phase_end()   { TIMINGS+=("$CURRENT|$((SECONDS - PHASE_START)) s"); ha_endgroup; CURRENT=""; }

write_receipt() {
  mkdir -p "$HA_STATE_DIR"
  {
    echo "# HA drill receipt: $FROM → $TO ($STRATEGY)"
    echo
    echo "- result: **$RESULT**"
    echo "- started: $STARTED_AT, finished: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ -n "${GITHUB_RUN_ID:-}" ]]; then
      echo "- run: ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/$GITHUB_RUN_ID"
    else
      echo "- run: local ($(hostname))"
    fi
    echo "- host: $(nproc) vCPU, $(awk '/MemTotal/ {printf "%.0f", $2/1048576}' /proc/meminfo 2>/dev/null || echo '?') GB, $(uname -m)"
    echo "- images: node $(docker image inspect -f '{{.Id}}' kc-ha-node:local 2>/dev/null | cut -c8-19), control $(docker image inspect -f '{{.Id}}' kc-ha-control:local 2>/dev/null | cut -c8-19)"
    echo "- FROM tarball: $FROM_URL${SHA_FROM:+ (sha256 $SHA_FROM)}"
    echo "- TO tarball: $TO_URL${SHA_TO:+ (sha256 $SHA_TO)}"
    echo
    echo "## Probes during ./upgrade (one request per second, per load balancer)"
    echo
    if [[ ${#PROBE_REPORTS[@]} -gt 0 ]]; then
      echo '```'
      printf '%s\n' "${PROBE_REPORTS[@]}"
      echo '```'
    else
      echo "(no probe data: the drill did not reach the upgrade)"
    fi
    echo
    echo "## Phases"
    echo
    echo "| phase | time |"
    echo "|---|---|"
    local t
    for t in "${TIMINGS[@]}"; do echo "| ${t%%|*} | ${t##*|} |"; done
    if [[ -n "$CURRENT" ]]; then echo "| $CURRENT | **failed** after $((SECONDS - PHASE_START)) s |"; fi
  } > "$RECEIPT"
}

on_exit() {
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    ha_endgroup
    RESULT="FAILED at phase: ${CURRENT:-?} (exit $rc)"
    echo "FAILED at phase: ${CURRENT:-?} (exit $rc)" >&2
  fi
  write_receipt
  echo "receipt: $RECEIPT"
  exit "$rc"
}
trap on_exit EXIT

# fetch_dist VERSION URL — cache the tarball under .dev/dist-cache, print its sha256
fetch_dist() {
  local version="$1" url="$2" dir="$DIST_CACHE/$1" file
  file="$dir/keycloak-$version.tar.gz"
  mkdir -p "$dir"
  if [[ ! -s "$file" || "$(cat "$dir/.url" 2>/dev/null)" != "$url" ]]; then
    echo "downloading $url" >&2
    curl -fsSL --retry 5 --retry-delay 5 -o "$file.part" "$url"
    mv "$file.part" "$file"
    echo "$url" > "$dir/.url"
  else
    echo "cached: $file" >&2
  fi
  sha256sum "$file" | cut -d' ' -f1
}

node_exec() { local node="$1"; shift; ha_compose exec -T "$node" "$@"; }

# ---------------------------------------------------------------------------
phase_begin "Fetch the $FROM and $TO tarballs into the cache"
SHA_FROM="$(fetch_dist "$FROM" "$FROM_URL")"; echo "keycloak-$FROM.tar.gz sha256 $SHA_FROM"
SHA_TO="$(fetch_dist "$TO" "$TO_URL")";       echo "keycloak-$TO.tar.gz sha256 $SHA_TO"
phase_end

phase_begin "Bring up the rig on $FROM"
HA_NESTED=1 dev/ha-up.sh --version "$FROM" ${HA_SKIP_BUILD:+--no-build}
# serve the cache to the nodes from the control container
ha_compose exec -d -T control python3 -m http.server 8000 --bind 0.0.0.0 -d /dist
for _ in $(seq 1 15); do
  ha_control curl -sf -o /dev/null "http://127.0.0.1:8000/$FROM/keycloak-$FROM.tar.gz" && break
  sleep 1
done
ha_control curl -sf -o /dev/null "http://127.0.0.1:8000/$FROM/keycloak-$FROM.tar.gz"
phase_end

phase_begin "Install $FROM on three nodes"
ha_control ./install -e "keycloak_dist_url=http://$HA_CONTROL_IP:8000/$FROM/keycloak-$FROM.tar.gz"
phase_end

phase_begin "A full backup exists before the upgrade"
backup_info="$(node_exec kc-node1 sudo -u postgres pgbackrest --stanza=main info --output=json)"
grep -q '"type":"full"' <<<"$backup_info" || { echo "error: no full backup in the repository" >&2; exit 1; }
echo "pgbackrest reports a full backup on kc-node1"
phase_end

phase_begin "Log in through kc-node2's load balancer before the upgrade"
REFRESH_TOKEN="$(ha_control sh -c "curl -sk --retry 10 --retry-delay 3 --retry-all-errors \
  -d grant_type=password -d client_id=keelinfra-drill -d username=demo -d password=demo12345 \
  https://${HA_IPS[1]}$TOKEN_URL_PATH | jq -er .refresh_token")"
[[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::add-mask::$REFRESH_TOKEN"
echo "session opened on $FROM (refresh token kept for after the upgrade)"
phase_end

phase_begin "Start a probe against every load balancer"
for i in 0 1 2; do
  ha_compose exec -d -T control dev/probe.sh start \
    --log "/work/.dev/containers/probe-${HA_NODES[$i]}.log" "https://${HA_IPS[$i]}$PROBE_PATH"
done
sleep 4
for node in "${HA_NODES[@]}"; do
  [[ -s "$HA_STATE_DIR/probe-$node.log" ]] || { echo "error: probe for $node is not logging" >&2; exit 1; }
  echo "$node: $(tail -1 "$HA_STATE_DIR/probe-$node.log")"
done
phase_end

phase_begin "./upgrade --to $TO ($STRATEGY)"
ha_control ./upgrade --to "$TO" --dist-url "http://$HA_CONTROL_IP:8000/$TO/keycloak-$TO.tar.gz"
phase_end

phase_begin "Stop the probes and read them"
for node in "${HA_NODES[@]}"; do ha_control dev/probe.sh stop --log "/work/.dev/containers/probe-$node.log"; done
if [[ "$STRATEGY" == rolling ]]; then report_opts=(--expect-zero); else report_opts=(--max-window "$MAX_WINDOW"); fi
probe_rc=0
for node in "${HA_NODES[@]}"; do
  echo "--- $node"
  out="$(ha_control dev/probe.sh report --log "/work/.dev/containers/probe-$node.log" "${report_opts[@]}")" || probe_rc=1
  echo "$out"
  summary="$(grep -E '^(total=|FAIL|error)' <<<"$out" | paste -sd ';' - || true)"
  tally="$(grep -E '^ *[0-9]+ [0-9]{3}$' <<<"$out" | sed 's/^ */    /' || true)"
  PROBE_REPORTS+=("[$node] ${summary:-no report}" "$tally")
done
[[ $probe_rc -eq 0 ]] || { echo "error: probe expectations not met for $STRATEGY" >&2; exit 1; }
phase_end

phase_begin "All three nodes run $TO and every load balancer sees every node UP"
for i in 0 1 2; do
  node="${HA_NODES[$i]}"
  active="$(node_exec "$node" readlink /opt/keycloak/current | tr -d '\r')"
  [[ "$(basename "$active")" == "keycloak-$TO" ]] || { echo "error: $node runs $active" >&2; exit 1; }
  code="$(ha_control curl -sk --retry 10 --retry-delay 3 --retry-all-errors -o /dev/null -w '%{http_code}' "https://${HA_IPS[$i]}:9000/health/ready")"
  [[ "$code" == 200 ]] || { echo "error: $node /health/ready answered $code" >&2; exit 1; }
  echo "$node: $(basename "$active"), ready"
done
for node in "${HA_NODES[@]}"; do
  for attempt in $(seq 1 20); do
    # one "server=status" per line; only an exact UP counts ("UP 1/3" is a
    # server failing its checks on the way down)
    stat="$(node_exec "$node" sh -c 'echo "show stat" | socat stdio /run/haproxy/admin.sock' \
      | awk -F, '$1=="keycloak_https" && $2!="FRONTEND" && $2!="BACKEND" {print $2"="$18}')"
    [[ "$(grep -c '=UP$' <<<"$stat" || true)" -eq 3 ]] && break
    [[ $attempt -lt 20 ]] || { echo "error: $node's load balancer: $(paste -sd ' ' - <<<"$stat")" >&2; exit 1; }
    sleep 3
  done
  echo "$node's load balancer: $(paste -sd ' ' - <<<"$stat")"
done
phase_end

phase_begin "The pre-upgrade session refreshes through kc-node1's load balancer"
ha_compose exec -T -e "REFRESH_TOKEN=$REFRESH_TOKEN" control sh -c "curl -sk --retry 20 --retry-delay 3 --retry-all-errors \
  -d grant_type=refresh_token -d client_id=keelinfra-drill -d refresh_token=\"\$REFRESH_TOKEN\" \
  https://${HA_IPS[0]}$TOKEN_URL_PATH | jq -er .access_token > /dev/null"
echo "session opened on $FROM still refreshes on $TO"
phase_end

phase_begin "./verify (health)"
ha_control ./verify
phase_end
phase_begin "./verify --drill failover"
ha_control ./verify --drill failover
phase_end
phase_begin "./verify --drill restore"
ha_control ./verify --drill restore
phase_end
phase_begin "./verify --drill session"
ha_control ./verify --drill session
phase_end

RESULT="PASS"
echo "✓ $FROM → $TO ($STRATEGY) drilled on three nodes"
