#!/usr/bin/env bash
# keelinfra/keycloak — unpack an offline bundle for ./configure and ./upgrade.
# Usage: bundle/unpack.sh <bundle.tar.gz> <dest-dir>
# Checks every file against the bundle's SHA256SUMS, then replaces <dest-dir>
# with the bundle's contents. Nothing in <dest-dir> changes if a check fails.
set -euo pipefail
BUNDLE="${1:?usage: bundle/unpack.sh <bundle.tar.gz> <dest-dir>}"
DEST="${2:?usage: bundle/unpack.sh <bundle.tar.gz> <dest-dir>}"
[[ -f "$BUNDLE" ]] || { echo "error: offline bundle not found: $BUNDLE" >&2; exit 1; }

# The control node may be a Mac, which has shasum but no sha256sum.
if command -v sha256sum >/dev/null; then sum=(sha256sum); else sum=(shasum -a 256); fi

# A .sha256 file next to the bundle (written by bundle/build.sh) is checked first.
if [[ -f "$BUNDLE.sha256" ]]; then
  (cd "$(dirname "$BUNDLE")" && "${sum[@]}" -c --quiet "$(basename "$BUNDLE").sha256") \
    || { echo "error: $BUNDLE does not match $BUNDLE.sha256" >&2; exit 1; }
fi

mkdir -p "$(dirname "$DEST")"
STAGE="$(mktemp -d "$(dirname "$DEST")/.offline-unpack.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
tar -xzf "$BUNDLE" -C "$STAGE"
TOP="$(find "$STAGE" -mindepth 1 -maxdepth 1 -type d | head -n1)"
[[ -n "$TOP" && -f "$TOP/bundle.yml" && -f "$TOP/SHA256SUMS" ]] \
  || { echo "error: $BUNDLE is not a keelinfra offline bundle (no bundle.yml)" >&2; exit 1; }
(cd "$TOP" && "${sum[@]}" -c --quiet SHA256SUMS) \
  || { echo "error: $BUNDLE is damaged: files do not match its SHA256SUMS" >&2; exit 1; }

rm -rf "$DEST"
mv "$TOP" "$DEST"
echo "offline bundle: $(sed -n 's/^keycloak_version: *"\{0,1\}\([^"]*\)"\{0,1\}/Keycloak \1/p' "$DEST/bundle.yml"), $(sed -n 's/^os: *//p' "$DEST/bundle.yml") $(sed -n 's/^arch: *//p' "$DEST/bundle.yml")"
