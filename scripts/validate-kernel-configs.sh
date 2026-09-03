#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/scripts/lib.sh"

asahi_pkgs="${1:?usage: validate-kernel-configs.sh ASAHI_PKGS MAINLINE_PKGS MAINLINE_4K_PKGS}"
mainline_pkgs="${2:?usage: validate-kernel-configs.sh ASAHI_PKGS MAINLINE_PKGS MAINLINE_4K_PKGS}"
mainline_4k_pkgs="${3:?usage: validate-kernel-configs.sh ASAHI_PKGS MAINLINE_PKGS MAINLINE_4K_PKGS}"
kernel_root="$(mktemp -d "${TMPDIR:-/tmp}/talos-asahi-kernel-config.XXXXXX")"
cleanup() {
  rm -rf "${kernel_root}"
}
trap cleanup EXIT

pkg_var() {
  local pkgs="$1"
  local name="$2"

  sed -n "s/^  ${name}: //p" "${pkgs}/Pkgfile"
}

fetch_kernel() {
  local url="$1"
  local sha256="$2"
  local archive="$3"
  local destination="$4"

  if [[ ! "${sha256}" =~ ^[0-9a-f]{64}$ ]]; then
    printf 'invalid kernel checksum for %s\n' "${url}" >&2
    exit 1
  fi

  curl --fail --location --silent --show-error "${url}" --output "${archive}"
  printf '%s  %s\n' "${sha256}" "${archive}" >"${archive}.sha256"
  check_sha256sums "${archive}.sha256"

  mkdir "${destination}"
}

asahi_ref="$(pkg_var "${asahi_pkgs}" linux_ref)"
if [[ ! "${asahi_ref}" =~ ^[0-9a-f]{40}$ ]]; then
  printf 'invalid Asahi kernel ref in %s\n' "${asahi_pkgs}/Pkgfile" >&2
  exit 1
fi

asahi_archive="${kernel_root}/asahi.tar.gz"
asahi_source="${kernel_root}/asahi"
fetch_kernel \
  "https://github.com/AsahiLinux/linux/archive/${asahi_ref}.tar.gz" \
  "$(pkg_var "${asahi_pkgs}" linux_sha256)" \
  "${asahi_archive}" \
  "${asahi_source}"
tar -xzf "${asahi_archive}" --strip-components=1 -C "${asahi_source}"
cp "${asahi_pkgs}/kernel/build/config-arm64" "${asahi_source}/.config"
KERNEL_CONFIG_LD=ld "${asahi_pkgs}/kernel/build/configure-asahi-arm64.sh" "${asahi_source}"

mainline_version="$(pkg_var "${mainline_pkgs}" linux_version)"
if [[ ! "${mainline_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'invalid mainline kernel version in %s\n' "${mainline_pkgs}/Pkgfile" >&2
  exit 1
fi

mainline_archive="${kernel_root}/mainline.tar.xz"
mainline_source="${kernel_root}/mainline"
fetch_kernel \
  "https://cdn.kernel.org/pub/linux/kernel/v${mainline_version%%.*}.x/linux-${mainline_version}.tar.xz" \
  "$(pkg_var "${mainline_pkgs}" linux_sha256)" \
  "${mainline_archive}" \
  "${mainline_source}"
tar -xJf "${mainline_archive}" --strip-components=1 -C "${mainline_source}"

cp "${mainline_pkgs}/kernel/build/config-arm64" "${mainline_source}/.config"
KERNEL_CONFIG_LD=ld "${mainline_pkgs}/kernel/build/configure-mainline-arm64.sh" "${mainline_source}" 16k

cp "${mainline_4k_pkgs}/kernel/build/config-arm64" "${mainline_source}/.config"
KERNEL_CONFIG_LD=ld "${mainline_4k_pkgs}/kernel/build/configure-mainline-arm64.sh" "${mainline_source}" 4k

printf 'Asahi, mainline 16K, and mainline 4K kernel configuration validation passed\n'
