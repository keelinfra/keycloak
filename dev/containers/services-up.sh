#!/usr/bin/env bash
# Runs inside the control container; dev/ha-up.sh and dev/vm-up.sh start it
# with the address the nodes reach it at. Brings up the two outside services
# a production cluster talks to, so the rig exercises them too:
#   - an S3 bucket for the off-site backup copy: moto on 127.0.0.1:5000,
#     behind a TLS listener on :9000 (pgBackRest only speaks https to S3),
#     with a certificate from the rig's own CA in <state dir>/s3/ — the
#     way a self-hosted store usually serves it
#   - an alert webhook on :9095 that appends every POST to
#     <state dir>/alerts.log
# Both are test stand-ins: in-memory, unauthenticated, gone on restart.
set -euo pipefail
control_ip="${1:?usage: services-up.sh <control ip> [state dir]}"
state="${2:-/work/.dev/containers}"   # dev/vm-up.sh passes /work/.dev/vm
mkdir -p "$state/s3"
cd "$state/s3"

if [[ ! -f server.pem ]]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=kc-ha rig S3 CA" \
    -keyout ca.key -out ca.crt 2>/dev/null
  openssl req -newkey rsa:2048 -nodes -subj "/CN=kc-s3" -keyout server.key -out server.csr 2>/dev/null
  printf 'subjectAltName=DNS:kc-s3,IP:%s\n' "$control_ip" > server.ext
  openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 3650 \
    -extfile server.ext -out server.crt 2>/dev/null
  cat server.crt server.key > server.pem
fi

up() { curl -fsS -o /dev/null --max-time 2 "$@" 2>/dev/null; }

up http://127.0.0.1:5000/ || \
  setsid /opt/s3/bin/moto_server -H 127.0.0.1 -p 5000 >moto.log 2>&1 < /dev/null &
up --cacert ca.crt https://kc-s3:9000/ || \
  setsid socat openssl-listen:9000,reuseaddr,fork,cert=server.pem,verify=0 tcp:127.0.0.1:5000 \
    >socat.log 2>&1 < /dev/null &
up -X POST -d '{}' http://127.0.0.1:9095/ || \
  setsid python3 /work/dev/containers/webhook-sink.py 9095 "$state/alerts.log" >/dev/null 2>&1 < /dev/null &

for _ in $(seq 1 30); do
  if up --cacert ca.crt -X PUT https://kc-s3:9000/kc-backups && up -X POST -d '{}' http://127.0.0.1:9095/; then
    echo "S3 bucket kc-backups and alert webhook ready"
    exit 0
  fi
  sleep 1
done
echo "error: the rig's S3 or webhook stand-in did not come up" >&2
tail -n 20 moto.log socat.log >&2 || true
exit 1
