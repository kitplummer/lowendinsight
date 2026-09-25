#!/usr/bin/env bash
# Print the current digest of postgres:17-bookworm, for the FROM line in
# ops/backup/Dockerfile. Bumping that pin is a deliberate act; this only tells
# you what you would be bumping to.
set -euo pipefail
TAG="${1:-17-bookworm}"
TOKEN=$(curl -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/postgres:pull" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")
curl -s -D - -o /dev/null -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json" \
  "https://registry-1.docker.io/v2/library/postgres/manifests/${TAG}" \
  | awk 'tolower($1) == "docker-content-digest:" { print $2 }' | tr -d '\r'
