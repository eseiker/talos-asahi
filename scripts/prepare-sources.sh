#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/scripts/lib.sh"
load_versions

destination="${1:?usage: prepare-sources.sh DESTINATION}"
mkdir -p "${destination}"

clone_pinned https://github.com/siderolabs/talos.git "${TALOS_SHA}" "${destination}/talos"
clone_pinned https://github.com/siderolabs/pkgs.git "${PKGS_SHA}" "${destination}/pkgs"

apply_patch_checked "${destination}/talos" "${root}/patches/talos-asahi.patch"
case "${KERNEL_FLAVOR}" in
  asahi)
    apply_patch_checked "${destination}/pkgs" "${root}/patches/pkgs-asahi.patch"
    if [[ ! "${ASAHI_KERNEL_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ||
          ! "${ASAHI_KERNEL_SHA}" =~ ^[0-9a-f]{40}$ ||
          ! "${ASAHI_KERNEL_SHA256}" =~ ^[0-9a-f]{64}$ ||
          ! "${ASAHI_KERNEL_SHA512}" =~ ^[0-9a-f]{128}$ ]]; then
      printf 'invalid Asahi kernel pin in versions.env\n' >&2
      exit 1
    fi

    sed_in_place \
      -e "s/ASAHI_KERNEL_VERSION/${ASAHI_KERNEL_VERSION}/" \
      -e "s/ASAHI_KERNEL_SHA256/${ASAHI_KERNEL_SHA256}/" \
      -e "s/ASAHI_KERNEL_SHA512/${ASAHI_KERNEL_SHA512}/" \
      -e "s/ASAHI_KERNEL_SHA/${ASAHI_KERNEL_SHA}/" \
      "${destination}/pkgs/Pkgfile"
    sed_in_place \
      -e '\|kernel/arch/arm64/lib/xor-neon.ko|d' \
      -e '\|kernel/crypto/hkdf.ko|d' \
      -e 's|kernel/crypto/xor.ko|kernel/lib/raid/xor/xor.ko|' \
      -e '\|kernel/drivers/cpufreq/apple-soc-cpufreq.ko|d' \
      -e '\|kernel/drivers/gpio/gpio-macsmc.ko|d' \
      -e '\|kernel/drivers/i2c/busses/i2c-pasemi-core.ko|d' \
      -e '\|kernel/drivers/i2c/busses/i2c-pasemi-platform.ko|d' \
      -e '\|kernel/drivers/mfd/macsmc.ko|d' \
      -e '\|kernel/drivers/nvme/host/nvme-apple.ko|d' \
      -e '\|kernel/drivers/pwm/pwm-apple.ko|d' \
      -e '\|kernel/drivers/soc/apple/apple-mailbox.ko|d' \
      -e '\|kernel/drivers/soc/apple/apple-rtkit.ko|d' \
      -e '\|kernel/drivers/soc/apple/apple-sart.ko|d' \
      -e '\|kernel/drivers/spi/spi-apple.ko|d' \
      -e '\|kernel/drivers/spmi/spmi-apple-controller.ko|d' \
      -e '\|kernel/drivers/watchdog/apple_wdt.ko|d' \
      -e $'/kernel\\/drivers\\/net\\/ethernet\\/stmicro\\/stmmac\\/stmmac-pci\\.ko/a\\\nkernel/drivers/net/ethernet/stmicro/stmmac/stmmac_libpci.ko' \
      "${destination}/talos/hack/modules-arm64.txt"
    ;;
  mainline)
    apply_patch_checked "${destination}/pkgs" "${root}/patches/pkgs-mainline.patch"
    sed_in_place \
      -e '\|kernel/drivers/cpufreq/apple-soc-cpufreq.ko|d' \
      -e '\|kernel/drivers/gpio/gpio-macsmc.ko|d' \
      -e '\|kernel/drivers/i2c/busses/i2c-pasemi-core.ko|d' \
      -e '\|kernel/drivers/i2c/busses/i2c-pasemi-platform.ko|d' \
      -e '\|kernel/drivers/mfd/macsmc.ko|d' \
      -e '\|kernel/drivers/nvmem/apple_nvmem_spmi.ko|d' \
      -e '\|kernel/drivers/nvmem/nvmem-apple-efuses.ko|d' \
      -e '\|kernel/drivers/nvme/host/nvme-apple.ko|d' \
      -e '\|kernel/drivers/power/reset/macsmc-reboot.ko|d' \
      -e '\|kernel/drivers/pwm/pwm-apple.ko|d' \
      -e '\|kernel/drivers/soc/apple/apple-mailbox.ko|d' \
      -e '\|kernel/drivers/soc/apple/apple-rtkit.ko|d' \
      -e '\|kernel/drivers/soc/apple/apple-sart.ko|d' \
      -e '\|kernel/drivers/spi/spi-apple.ko|d' \
      -e '\|kernel/drivers/spmi/spmi-apple-controller.ko|d' \
      -e '\|kernel/drivers/watchdog/apple_wdt.ko|d' \
      "${destination}/talos/hack/modules-arm64.txt"
    ;;
  mainline-4k)
    apply_patch_checked "${destination}/pkgs" "${root}/patches/pkgs-mainline.patch"
    apply_patch_checked "${destination}/pkgs" "${root}/patches/pkgs-mainline-4k.patch"
    sed_in_place \
      -e '\|kernel/drivers/cpufreq/apple-soc-cpufreq.ko|d' \
      -e '\|kernel/drivers/gpio/gpio-macsmc.ko|d' \
      -e '\|kernel/drivers/i2c/busses/i2c-pasemi-core.ko|d' \
      -e '\|kernel/drivers/i2c/busses/i2c-pasemi-platform.ko|d' \
      -e '\|kernel/drivers/mfd/macsmc.ko|d' \
      -e '\|kernel/drivers/nvmem/apple_nvmem_spmi.ko|d' \
      -e '\|kernel/drivers/nvmem/nvmem-apple-efuses.ko|d' \
      -e '\|kernel/drivers/nvme/host/nvme-apple.ko|d' \
      -e '\|kernel/drivers/power/reset/macsmc-reboot.ko|d' \
      -e '\|kernel/drivers/pwm/pwm-apple.ko|d' \
      -e '\|kernel/drivers/soc/apple/apple-mailbox.ko|d' \
      -e '\|kernel/drivers/soc/apple/apple-rtkit.ko|d' \
      -e '\|kernel/drivers/soc/apple/apple-sart.ko|d' \
      -e '\|kernel/drivers/spi/spi-apple.ko|d' \
      -e '\|kernel/drivers/spmi/spmi-apple-controller.ko|d' \
      -e '\|kernel/drivers/watchdog/apple_wdt.ko|d' \
      "${destination}/talos/hack/modules-arm64.txt"
    ;;
  v1.15)
    ;;
esac

printf 'prepared Talos %s and pkgs %s for %s kernel\n' \
  "${TALOS_SHA}" "${PKGS_SHA}" "${KERNEL_FLAVOR}"
