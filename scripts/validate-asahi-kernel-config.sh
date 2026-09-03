#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/scripts/lib.sh"

pkgs="${1:?usage: validate-asahi-kernel-config.sh PREPARED_PKGS}"
kernel_root="$(mktemp -d "${TMPDIR:-/tmp}/talos-asahi-kernel-config.XXXXXX")"
cleanup() {
  rm -rf "${kernel_root}"
}
trap cleanup EXIT

pkg_var() {
  sed -n "s/^  $1: //p" "${pkgs}/Pkgfile"
}

linux_ref="$(pkg_var linux_ref)"
linux_sha256="$(pkg_var linux_sha256)"

if [[ ! "${linux_ref}" =~ ^[0-9a-f]{40}$ || ! "${linux_sha256}" =~ ^[0-9a-f]{64}$ ]]; then
  printf 'invalid Asahi kernel ref or checksum in %s\n' "${pkgs}/Pkgfile" >&2
  exit 1
fi

archive="${kernel_root}/linux.tar.gz"
source_dir="${kernel_root}/linux"
mkdir "${source_dir}"

curl --fail --location --silent --show-error \
  "https://github.com/AsahiLinux/linux/archive/${linux_ref}.tar.gz" \
  --output "${archive}"
printf '%s  %s\n' "${linux_sha256}" "${archive}" >"${kernel_root}/SHA256SUMS"
check_sha256sums "${kernel_root}/SHA256SUMS"

tar -xzf "${archive}" --strip-components=1 -C "${source_dir}"
cp "${pkgs}/kernel/build/config-arm64" "${source_dir}/.config"
"${pkgs}/kernel/build/configure-asahi-arm64.sh" "${source_dir}"

printf 'Asahi kernel configuration validation passed for %s\n' "${linux_ref}"
