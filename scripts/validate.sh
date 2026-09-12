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
KERNEL_FLAVOR=v1.15 "${root}/scripts/prepare-sources.sh" "${validation_root}/v1.15"

asahi_modules="${validation_root}/asahi/talos/hack/modules-arm64.txt"
require_module "${asahi_modules}" kernel/lib/raid/xor/xor.ko
reject_module "${asahi_modules}" kernel/crypto/xor.ko
for module in \
  kernel/drivers/i2c/busses/i2c-pasemi-platform.ko \
  kernel/drivers/mfd/macsmc.ko \
  kernel/drivers/nvme/host/nvme-apple.ko \
  kernel/drivers/pwm/pwm-apple.ko \
  kernel/drivers/soc/apple/apple-mailbox.ko \
  kernel/drivers/soc/apple/apple-rtkit.ko \
  kernel/drivers/soc/apple/apple-sart.ko \
  kernel/drivers/spi/spi-apple.ko \
  kernel/drivers/spmi/spmi-apple-controller.ko \
  kernel/drivers/watchdog/apple_wdt.ko; do
  reject_module "${asahi_modules}" "${module}"
done

for flavor in mainline mainline-4k; do
  mainline_modules="${validation_root}/${flavor}/talos/hack/modules-arm64.txt"
  require_module "${mainline_modules}" kernel/arch/arm64/lib/xor-neon.ko
  require_module "${mainline_modules}" kernel/crypto/hkdf.ko
  require_module "${mainline_modules}" kernel/crypto/xor.ko
  reject_module "${mainline_modules}" kernel/lib/raid/xor/xor.ko
  for module in \
    kernel/drivers/nvmem/apple_nvmem_spmi.ko \
    kernel/drivers/nvmem/nvmem-apple-efuses.ko \
    kernel/drivers/power/reset/macsmc-reboot.ko \
    kernel/drivers/pwm/pwm-apple.ko \
    kernel/drivers/soc/apple/apple-mailbox.ko \
    kernel/drivers/soc/apple/apple-rtkit.ko \
    kernel/drivers/soc/apple/apple-sart.ko \
    kernel/drivers/spi/spi-apple.ko \
    kernel/drivers/spmi/spmi-apple-controller.ko \
    kernel/drivers/watchdog/apple_wdt.ko; do
    reject_module "${mainline_modules}" "${module}"
  done
done

if ! git -C "${validation_root}/v1.15/pkgs" diff --quiet; then
  printf 'v1.15 kernel flavor must use the unmodified pinned pkgs source\n' >&2
  exit 1
fi

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

printf 'Asahi, mainline 16K, mainline 4K, and v1.15 sources, lifecycle, and sd-boot validation passed for %s\n' \
  "${RELEASE_TAG}"
