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
  "${LONGHORN_BOOT_UKI}"
  "${LONGHORN_PREPARE_UKI}"
  installer-arm64.tar
  installer-longhorn-arm64.tar
  loader.conf
  loader-longhorn.conf
  SHA256SUMS
  build.env
  "${BOOT_BUNDLE}"
  "${LONGHORN_BOOT_BUNDLE}"
)

for file in "${required[@]}"; do
  if [[ ! -s "${out_dir}/${file}" ]]; then
    printf 'missing or empty artifact: %s\n' "${out_dir}/${file}" >&2
    exit 1
  fi
done

verify_root="$(mktemp -d "${TMPDIR:-/tmp}/talos-asahi-artifacts.XXXXXX")"
cleanup() {
  rm -rf "${verify_root}"
}
trap cleanup EXIT

verify_bundle() {
  local bundle="$1"
  local final_uki="$2"
  local prepare_uki_source="$3"
  local loader_source="$4"
  local extracted="${verify_root}/${bundle}"
  local bundle_contents expected_contents

  grep -Fxq "default ${PREPARE_UKI}" "${out_dir}/${loader_source}"
  if grep -Eq '(^|[[:space:]])ip=|talos\.config=' "${out_dir}/${loader_source}"; then
    printf '%s contains a machine-specific network or config argument\n' \
      "${loader_source}" >&2
    exit 1
  fi

  bundle_contents="$(unzip -Z1 "${out_dir}/${bundle}" | LC_ALL=C sort)"
  expected_contents="$(printf '%s\n' \
    EFI/BOOT/BOOTAA64.efi \
    "EFI/Linux/${final_uki}" \
    "EFI/Linux/${PREPARE_UKI}" \
    loader/loader.conf | LC_ALL=C sort)"
  if [[ "${bundle_contents}" != "${expected_contents}" ]]; then
    printf 'unexpected contents in %s:\n%s\n' "${bundle}" "${bundle_contents}" >&2
    exit 1
  fi

  if grep -aFq 'm1n1/boot.bin' "${out_dir}/${bundle}"; then
    printf '%s must not contain Asahi-owned m1n1/boot.bin\n' "${bundle}" >&2
    exit 1
  fi

  grep -aFq 'rdinit=/init' "${out_dir}/${prepare_uki_source}"
  grep -aFq "talos_asahi.target=${final_uki}" \
    "${out_dir}/${prepare_uki_source}"

  mkdir -p "${extracted}"
  unzip -q "${out_dir}/${bundle}" -d "${extracted}"
  cmp "${out_dir}/BOOTAA64.efi" "${extracted}/EFI/BOOT/BOOTAA64.efi"
  cmp "${out_dir}/${final_uki}" "${extracted}/EFI/Linux/${final_uki}"
  cmp "${out_dir}/${prepare_uki_source}" \
    "${extracted}/EFI/Linux/${PREPARE_UKI}"
  cmp "${out_dir}/${loader_source}" "${extracted}/loader/loader.conf"
}

verify_bundle \
  "${BOOT_BUNDLE}" "${BOOT_UKI}" "${PREPARE_UKI}" loader.conf
verify_bundle \
  "${LONGHORN_BOOT_BUNDLE}" "${LONGHORN_BOOT_UKI}" \
  "${LONGHORN_PREPARE_UKI}" loader-longhorn.conf

if cmp -s "${out_dir}/${BOOT_UKI}" "${out_dir}/${LONGHORN_BOOT_UKI}"; then
  printf 'standard and Longhorn UKIs are unexpectedly identical\n' >&2
  exit 1
fi

verify_tools_image="${VERIFY_TOOLS_IMAGE:?set VERIFY_TOOLS_IMAGE to inspect the Longhorn UKI}"
docker run --rm \
  --user "$(id -u):$(id -g)" \
  --entrypoint /bin/sh \
  -v "${out_dir}:/out:ro" \
  -v "${verify_root}:/work" \
  "${verify_tools_image}" \
  -ceu "
    cp /out/${LONGHORN_BOOT_UKI} /work/longhorn.efi
    objcopy --dump-section .initrd=/work/longhorn-initramfs.zst \
      /work/longhorn.efi
    zstd --decompress --stdout /work/longhorn-initramfs.zst \
      >/work/longhorn-initramfs
  "
for expected in 'name: iscsi-tools' 'name: util-linux-tools'; do
  if ! grep -aFq "${expected}" "${verify_root}/longhorn-initramfs"; then
    printf 'Longhorn UKI is missing extension metadata: %s\n' "${expected}" >&2
    exit 1
  fi
done

checksum_files="$(awk 'NF { print $2 }' "${out_dir}/SHA256SUMS" | LC_ALL=C sort)"
expected_checksum_files="$(printf '%s\n' \
  "${BOOT_BUNDLE}" "${LONGHORN_BOOT_BUNDLE}" | LC_ALL=C sort)"
if [[ "${checksum_files}" != "${expected_checksum_files}" ]]; then
  printf 'SHA256SUMS must contain exactly both ESP bundle checksums\n' >&2
  exit 1
fi

(
  cd "${out_dir}"
  check_sha256sums SHA256SUMS
)

printf 'artifact verification passed for %s\n' "${ARTIFACT_TAG}"
