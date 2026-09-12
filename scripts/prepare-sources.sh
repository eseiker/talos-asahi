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

talos_patch="${root}/patches/talos-asahi.patch"
pkgs_asahi_patch="${root}/patches/pkgs-asahi.patch"

case "${TALOS_VERSION}" in
  v1.13.*)
    talos_patch="${root}/patches/talos-asahi-v1.13.patch"
    pkgs_asahi_patch="${root}/patches/pkgs-asahi-v1.13.patch"
    ;;
esac

apply_patch_checked "${destination}/talos" "${talos_patch}"
case "${KERNEL_FLAVOR}" in
  asahi)
    apply_patch_checked "${destination}/pkgs" "${pkgs_asahi_patch}"
    if [[ ! "${ASAHI_KERNEL_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ||
          ! "${ASAHI_KERNEL_SHA}" =~ ^[0-9a-f]{40}$ ||
          ! "${ASAHI_KERNEL_SHA256}" =~ ^[0-9a-f]{64}$ ||
          ! "${ASAHI_KERNEL_SHA512}" =~ ^[0-9a-f]{128}$ ]]; then
      printf 'invalid Asahi kernel pin in versions.env\n' >&2
      exit 1
    fi

    sed -i \
      -e "s/ASAHI_KERNEL_VERSION/${ASAHI_KERNEL_VERSION}/" \
      -e "s/ASAHI_KERNEL_SHA256/${ASAHI_KERNEL_SHA256}/" \
      -e "s/ASAHI_KERNEL_SHA512/${ASAHI_KERNEL_SHA512}/" \
      -e "s/ASAHI_KERNEL_SHA/${ASAHI_KERNEL_SHA}/" \
      "${destination}/pkgs/Pkgfile"
    sed -i \
      -e '\|kernel/arch/arm64/lib/xor-neon.ko|d' \
      -e '\|kernel/crypto/hkdf.ko|d' \
      -e 's|kernel/crypto/xor.ko|kernel/lib/raid/xor/xor.ko|' \
      -e '/kernel\/drivers\/net\/ethernet\/stmicro\/stmmac\/stmmac-pci\.ko/a kernel/drivers/net/ethernet/stmicro/stmmac/stmmac_libpci.ko' \
      "${destination}/talos/hack/modules-arm64.txt"
    ;;
  mainline)
    apply_patch_checked "${destination}/pkgs" "${root}/patches/pkgs-mainline.patch"
    ;;
  mainline-4k)
    apply_patch_checked "${destination}/pkgs" "${root}/patches/pkgs-mainline.patch"
    apply_patch_checked "${destination}/pkgs" "${root}/patches/pkgs-mainline-4k.patch"
    ;;
esac

printf 'prepared Talos %s and pkgs %s for %s kernel\n' \
  "${TALOS_SHA}" "${PKGS_SHA}" "${KERNEL_FLAVOR}"
