#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/scripts/lib.sh"
load_versions

out_dir="${1:-${root}/_out}"
required=(
  BOOTAA64.efi
  "${BOOT_UKI}"
  "${PREPARE_UKI}"
  installer-arm64.tar
  installer-longhorn-arm64.tar
  loader.conf
  SHA256SUMS
  build.env
  "${BOOT_BUNDLE}"
)

for file in "${required[@]}"; do
  if [[ ! -s "${out_dir}/${file}" ]]; then
    printf 'missing or empty artifact: %s\n' "${out_dir}/${file}" >&2
    exit 1
  fi
done

grep -Fxq "default ${PREPARE_UKI}" "${out_dir}/loader.conf"
if grep -Eq '(^|[[:space:]])ip=|talos\.config=' "${out_dir}/loader.conf"; then
  printf 'loader.conf contains a machine-specific network or config argument\n' >&2
  exit 1
fi

bundle_contents="$(unzip -Z1 "${out_dir}/${BOOT_BUNDLE}" | LC_ALL=C sort)"
expected_contents="$(printf '%s\n' \
  EFI/BOOT/BOOTAA64.efi \
  "EFI/Linux/${BOOT_UKI}" \
  "EFI/Linux/${PREPARE_UKI}" \
  loader/loader.conf | LC_ALL=C sort)"
if [[ "${bundle_contents}" != "${expected_contents}" ]]; then
  printf 'unexpected boot bundle contents:\n%s\n' "${bundle_contents}" >&2
  exit 1
fi

if grep -aFq 'm1n1/boot.bin' "${out_dir}/${BOOT_BUNDLE}"; then
  printf 'the ESP bundle must not contain Asahi-owned m1n1/boot.bin\n' >&2
  exit 1
fi

grep -aFq 'rdinit=/init' "${out_dir}/${PREPARE_UKI}"
grep -aFq "talos_asahi.target=${BOOT_UKI}" "${out_dir}/${PREPARE_UKI}"

verify_root="$(mktemp -d "${TMPDIR:-/tmp}/talos-asahi-artifacts.XXXXXX")"
cleanup() {
  rm -rf "${verify_root}"
}
trap cleanup EXIT
unzip -q "${out_dir}/${BOOT_BUNDLE}" -d "${verify_root}"
cmp "${out_dir}/BOOTAA64.efi" "${verify_root}/EFI/BOOT/BOOTAA64.efi"
cmp "${out_dir}/${BOOT_UKI}" "${verify_root}/EFI/Linux/${BOOT_UKI}"
cmp "${out_dir}/${PREPARE_UKI}" "${verify_root}/EFI/Linux/${PREPARE_UKI}"
cmp "${out_dir}/loader.conf" "${verify_root}/loader/loader.conf"

if [[ "$(awk 'NF { count++; file=$2 } END { print count ":" file }' "${out_dir}/SHA256SUMS")" != "1:${BOOT_BUNDLE}" ]]; then
  printf 'SHA256SUMS must contain only the boot bundle checksum\n' >&2
  exit 1
fi

(
  cd "${out_dir}"
  check_sha256sums SHA256SUMS
)

printf 'artifact verification passed for %s\n' "${ARTIFACT_TAG}"
