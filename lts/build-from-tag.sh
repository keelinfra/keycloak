#!/usr/bin/env bash
# Build a Keycloak server distribution from an upstream git tag.
#
# Why this exists: upstream cuts patch tags on maintenance branches (e.g.
# 26.2.6..26.2.16) that carry backported fixes for the Red Hat build of
# Keycloak, but publishes no community artifacts for them — no GitHub
# release, no tarball, no container image (see upstream discussion #42779).
# Keycloak is Apache-2.0, so building and shipping those tags ourselves is
# permitted; this script makes that build reproducible.
#
# Usage:   ./build-from-tag.sh <tag> [workdir]
# Example: ./build-from-tag.sh 26.2.9
#
# Requirements: JDK 17 or 21, git, ~4 GB disk for sources + Maven repo.
# Output: keycloak-<tag>.tar.gz and .zip under <workdir>/kc-<tag>/quarkus/dist/target/

set -euo pipefail

TAG="${1:?usage: build-from-tag.sh <tag> [workdir]}"
WORKDIR="${2:-$(pwd)/lts-build}"
SRC="$WORKDIR/kc-$TAG"

mkdir -p "$WORKDIR"

if [ ! -d "$SRC/.git" ]; then
  git clone --depth 1 --branch "$TAG" https://github.com/keycloak/keycloak.git "$SRC"
fi

cd "$SRC"
test "$(git describe --tags)" = "$TAG"

# Server distribution only, tests skipped; the same scoped build the upstream
# docs describe for producing the dist ZIP.
./mvnw -pl quarkus/deployment,quarkus/dist -am -DskipTests clean install

DIST_TAR="$SRC/quarkus/dist/target/keycloak-$TAG.tar.gz"
test -f "$DIST_TAR"

echo
echo "Built: $DIST_TAR"
sha256sum "$SRC/quarkus/dist/target/keycloak-$TAG".{tar.gz,zip} 2>/dev/null || sha256sum "$DIST_TAR"
