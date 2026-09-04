#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/scripts/lib.sh"
load_versions

validation_root="$(mktemp -d "${TMPDIR:-/tmp}/talos-asahi-validate.XXXXXX")"
cleanup() {
  rm -rf "${validation_root}"
}
trap cleanup EXIT

"${root}/scripts/test-prepare.sh"

KERNEL_FLAVOR=asahi "${root}/scripts/prepare-sources.sh" "${validation_root}/asahi"
KERNEL_FLAVOR=mainline "${root}/scripts/prepare-sources.sh" "${validation_root}/mainline"
KERNEL_FLAVOR=mainline-4k "${root}/scripts/prepare-sources.sh" "${validation_root}/mainline-4k"

docker run --rm \
  -v "${validation_root}/asahi/talos:/src" \
  -v talos-asahi-go-mod:/go/pkg/mod \
  -v talos-asahi-go-build:/root/.cache/go-build \
  -w /src golang:1.26 \
  go test \
    ./internal/app/lifecycle \
    ./internal/app/machined/pkg/runtime/v1alpha1/bootloader/sdboot

printf 'Asahi, mainline 16K, and mainline 4K sources, lifecycle, and sd-boot validation passed for %s\n' \
  "${RELEASE_TAG}"
