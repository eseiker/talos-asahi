#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_image="local/talos-asahi/prepare-test:validation"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/talos-asahi-prepare-test.XXXXXX")"

cleanup() {
  rm -rf "${test_root}"
}
trap cleanup EXIT

docker buildx build --load \
  --file "${root}/prepare/Dockerfile" \
  --target test \
  --tag "${test_image}" \
  "${root}/prepare"

docker run --rm \
  --user "$(id -u):$(id -g)" \
  --volume "${test_root}:/tests" \
  "${test_image}" /tests
