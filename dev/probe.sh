#!/usr/bin/env bash
# One request per second against a URL, and a report of what came back.
# This is the probe the zero-downtime claim rests on: run it against every
# node's load balancer while ./upgrade runs, then read the tally.
#
# Usage: dev/probe.sh start  --log FILE URL      # loops until FILE.stop appears
#        dev/probe.sh stop   --log FILE
#        dev/probe.sh report --log FILE [--expect-zero] [--max-window SECONDS]
#
# Log lines are "HH:MM:SS <http code> <epoch>"; curl writes 000 for a timeout
# or a refused connection. report prints the tally (count per code), the
# total, the number of non-200 answers and the longest run of consecutive
# non-200 answers in seconds. --expect-zero fails on any non-200 answer;
# --max-window fails when the longest run is longer than SECONDS.
set -euo pipefail

cmd="${1:-}"
[[ $# -gt 0 ]] && shift
LOG="" URL="" EXPECT_ZERO=0 MAX_WINDOW=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --log) LOG="$2"; shift 2 ;;
    --expect-zero) EXPECT_ZERO=1; shift ;;
    --max-window) MAX_WINDOW="$2"; shift 2 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) URL="$1"; shift ;;
  esac
done
[[ -n "$LOG" ]] || { echo "error: --log FILE is required" >&2; exit 2; }

case "$cmd" in
  start)
    [[ -n "$URL" ]] || { echo "error: start needs a URL" >&2; exit 2; }
    rm -f "$LOG.stop"
    : > "$LOG"
    while [[ ! -e "$LOG.stop" ]]; do
      printf '%s %s %s\n' "$(date +%T)" \
        "$(curl -sk -o /dev/null -w '%{http_code}' --max-time 3 "$URL" || true)" \
        "$(date +%s)" >> "$LOG"
      sleep 1
    done
    ;;
  stop)
    touch "$LOG.stop"
    sleep 2 # let the loop finish the request it is on
    ;;
  report)
    [[ -s "$LOG" ]] || { echo "error: $LOG is empty, no probe data" >&2; exit 1; }
    echo "tally (count code):"
    awk '{print $2}' "$LOG" | sort | uniq -c
    awk -v max_window="$MAX_WINDOW" -v expect_zero="$EXPECT_ZERO" '
      function close_run() {
        w = run_end - run_start + 1
        if (w > max) { max = w; max_from = run_start_t; max_to = run_end_t }
        run_start = 0
      }
      { total++ }
      $2 != 200 {
        bad++
        if (!run_start) { run_start = $3; run_start_t = $1 }
        run_end = $3; run_end_t = $1
        next
      }
      run_start { close_run() }
      END {
        if (run_start) close_run()
        printf "total=%d non200=%d longest_non200_window=%ds", total, bad, max
        if (max) printf " (%s..%s)", max_from, max_to
        printf "\n"
        rc = 0
        if (expect_zero && bad) { print "FAIL: expected every answer to be 200"; rc = 1 }
        if (max_window > 0 && max > max_window) { print "FAIL: longest non-200 window exceeds " max_window "s"; rc = 1 }
        exit rc
      }' "$LOG"
    ;;
  *)
    sed -n '2,14p' "$0" >&2
    exit 2
    ;;
esac
