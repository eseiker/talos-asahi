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

require_module() {
  local module_list="$1"
  local module="$2"

  if ! grep -Fxq "${module}" "${module_list}"; then
    printf 'required module %s is missing from %s\n' "${module}" "${module_list}" >&2
    return 1
  fi
}

reject_module() {
  local module_list="$1"
  local module="$2"

  if grep -Fxq "${module}" "${module_list}"; then
    printf 'unexpected module %s is present in %s\n' "${module}" "${module_list}" >&2
    return 1
  fi
}

"${root}/scripts/test-prepare.sh"

KERNEL_FLAVOR=asahi "${root}/scripts/prepare-sources.sh" "${validation_root}/asahi"
KERNEL_FLAVOR=mainline "${root}/scripts/prepare-sources.sh" "${validation_root}/mainline"
KERNEL_FLAVOR=mainline-4k "${root}/scripts/prepare-sources.sh" "${validation_root}/mainline-4k"

asahi_modules="${validation_root}/asahi/talos/hack/modules-arm64.txt"
require_module "${asahi_modules}" kernel/lib/raid/xor/xor.ko
reject_module "${asahi_modules}" kernel/crypto/xor.ko

for flavor in mainline mainline-4k; do
  mainline_modules="${validation_root}/${flavor}/talos/hack/modules-arm64.txt"
  require_module "${mainline_modules}" kernel/arch/arm64/lib/xor-neon.ko
  require_module "${mainline_modules}" kernel/crypto/hkdf.ko
  require_module "${mainline_modules}" kernel/crypto/xor.ko
  reject_module "${mainline_modules}" kernel/lib/raid/xor/xor.ko
done

"${root}/scripts/validate-kernel-configs.sh" \
  "${validation_root}/asahi/pkgs" \
  "${validation_root}/mainline/pkgs" \
  "${validation_root}/mainline-4k/pkgs"

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
