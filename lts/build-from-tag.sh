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
# Output: keycloak-<tag>.tar.gz, .zip and the SBOM keycloak-<tag>.cdx.json under <workdir>/kc-<tag>/quarkus/dist/target/

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

# Old tags hard-code raw.githubusercontent.com branch URLs in the ProtoStream
# schema-compatibility check (model/infinispan/pom.xml, <remoteLockFiles>).
# Upstream later moves release branches under archive/, so those URLs start
# returning 404 and the build fails in keycloak-model-infinispan. Rewrite any
# dead release/... URL to its archive/release/... location instead of skipping
# the check (-DskipProtoLock) — serialization compatibility is a check an LTS
# build wants to keep.
POM="model/infinispan/pom.xml"
if [ -f "$POM" ]; then
  for ref in $(grep -o 'refs/heads/release/[0-9.]*' "$POM" | sort -u); do
    url="https://raw.githubusercontent.com/keycloak/keycloak/$ref/model/infinispan/proto.lock"
    if [ "$(curl -s -o /dev/null -w '%{http_code}' "$url")" = "404" ]; then
      sed -i "s|$ref/model|${ref/release\//archive\/release\/}/model|" "$POM"
      echo "patched dead proto.lock URL: $ref -> ${ref/release\//archive\/release\/}"
    fi
  done
fi

# Server distribution only, tests skipped; the same scoped build the upstream
# docs describe for producing the dist ZIP.
./mvnw -pl quarkus/deployment,quarkus/dist -am -DskipTests clean install

DIST_TAR="$SRC/quarkus/dist/target/keycloak-$TAG.tar.gz"
test -f "$DIST_TAR"

# SBOM (CycloneDX JSON) of what the distribution ships: the dist module's
# runtime dependency tree, from the CycloneDX project's own Maven plugin,
# pinned. Test-scoped dependencies are left out by the plugin's default.
CYCLONEDX_PLUGIN="org.cyclonedx:cyclonedx-maven-plugin:2.9.3"
./mvnw -q -pl quarkus/dist "$CYCLONEDX_PLUGIN:makeBom" \
  -DprojectType=application -DoutputFormat=json -DoutputName="keycloak-$TAG.cdx"
SBOM="$SRC/quarkus/dist/target/keycloak-$TAG.cdx.json"
test -s "$SBOM"

echo
echo "Built: $DIST_TAR"
echo "SBOM:  $SBOM"
sha256sum "$SRC/quarkus/dist/target/keycloak-$TAG".{tar.gz,zip} 2>/dev/null || sha256sum "$DIST_TAR"
