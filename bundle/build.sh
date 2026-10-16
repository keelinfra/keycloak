#!/usr/bin/env bash
# keelinfra/keycloak — build an offline bundle: everything ./install and
# ./upgrade download, in one tarball, for nodes with no internet access.
#
# Usage: bundle/build.sh --version 26.8.1 [--arch amd64|arm64] [--dist-url <url>] [--out <dir>]
#
# Runs on any machine with Docker and internet access. The apt packages are
# resolved inside an ubuntu:24.04 container of the target architecture, so
# the bundle matches the nodes, not the machine that builds it (arm64 on an
# amd64 host needs qemu binfmt, e.g. docker run --privileged tonistiigi/binfmt --install arm64).
#
# Result: <out>/keelinfra-keycloak-offline-<version>-ubuntu24.04-<arch>.tar.gz
# Use it with: ./configure -c cluster.yml --offline <bundle>   (see bundle/README.md)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

VERSION="" ARCH="" DIST_URL="" OUT="$ROOT/.dev/bundle"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)  VERSION="$2"; shift 2 ;;
    --arch)     ARCH="$2"; shift 2 ;;
    --dist-url) DIST_URL="$2"; shift 2 ;;
    --out)      OUT="$2"; shift 2 ;;
    -h|--help)  sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done
[[ "$VERSION" =~ ^26\.[0-9]+\.[0-9]+$ ]] || { echo "error: --version 26.x.y is required" >&2; exit 1; }
if [[ -z "$ARCH" ]]; then
  case "$(uname -m)" in
    x86_64|amd64)  ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) echo "error: cannot map $(uname -m) to amd64/arm64; pass --arch" >&2; exit 1 ;;
  esac
fi
[[ "$ARCH" == amd64 || "$ARCH" == arm64 ]] || { echo "error: --arch must be amd64 or arm64" >&2; exit 1; }
DIST_URL="${DIST_URL:-https://github.com/keycloak/keycloak/releases/download/$VERSION/keycloak-$VERSION.tar.gz}"
command -v docker >/dev/null || { echo "error: docker not found" >&2; exit 1; }

NAME="keelinfra-keycloak-offline-$VERSION-ubuntu24.04-$ARCH"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
WORK="$OUT/$NAME"
rm -rf "$WORK"
mkdir -p "$WORK"

echo "### apt packages (ubuntu 24.04, $ARCH)"
docker run --rm --platform "linux/$ARCH" \
  -v "$ROOT:/src:ro" -v "$WORK:/out" \
  ubuntu:24.04 bash /src/bundle/inside-apt.sh

echo "### release artifacts and Ansible collections"
docker run --rm \
  -v "$ROOT:/src:ro" -v "$WORK:/out" \
  -e VERSION="$VERSION" -e ARCH="$ARCH" -e DIST_URL="$DIST_URL" \
  ubuntu:24.04 bash /src/bundle/inside-fetch.sh

echo "### tarball"
# The containers ran as root; hand the tree back to the caller.
docker run --rm -v "$WORK:/out" ubuntu:24.04 chown -R "$(id -u):$(id -g)" /out
tar -C "$OUT" -czf "$OUT/$NAME.tar.gz" "$NAME"
rm -rf "$WORK"
if command -v sha256sum >/dev/null; then sum=(sha256sum); else sum=(shasum -a 256); fi
(cd "$OUT" && "${sum[@]}" "$NAME.tar.gz" > "$NAME.tar.gz.sha256")

echo
echo "✓ $OUT/$NAME.tar.gz ($(du -h "$OUT/$NAME.tar.gz" | cut -f1))"
echo "  Next, on the control node: ./configure -c <cluster.yml> --offline $NAME.tar.gz"
