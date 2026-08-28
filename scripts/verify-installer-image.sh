#!/usr/bin/env bash

set -euo pipefail

archive="${1:?usage: verify-installer-image.sh ARCHIVE IMAGE_REF [INITRAMFS_STRING ...]}"
image_ref="${2:?usage: verify-installer-image.sh ARCHIVE IMAGE_REF [INITRAMFS_STRING ...]}"
shift 2
expected_initramfs_strings=("$@")
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/talos-asahi-installer-verify.XXXXXX")"
container_id=""

cleanup() {
  if [[ -n "${container_id}" ]]; then
    docker rm -f "${container_id}" >/dev/null 2>&1 || true
  fi

  rm -rf "${work_dir}"
}
trap cleanup EXIT

docker load --input "${archive}"
if ! docker image inspect "${image_ref}" >/dev/null; then
  printf 'installer archive did not load expected image: %s\n' "${image_ref}" >&2
  exit 1
fi

container_id="$(docker create "${image_ref}")"
docker cp "${container_id}:/bin/installer" "${work_dir}/installer"

if ! grep -aFq 'sd-boot: no valid boot entry found in EFI variables or loader.conf' "${work_dir}/installer"; then
  printf 'installer binary is missing the sd-boot loader.conf fallback patch\n' >&2
  exit 1
fi

if grep -aFq 'sd-boot: no LoaderEntryDefault or LoaderEntrySelected found, cannot continue' "${work_dir}/installer"; then
  printf 'installer binary still contains the unpatched sd-boot failure path\n' >&2
  exit 1
fi

if ((${#expected_initramfs_strings[@]} > 0)); then
  verify_tools_image="${VERIFY_TOOLS_IMAGE:?set VERIFY_TOOLS_IMAGE when checking initramfs strings}"
  docker cp "${container_id}:/usr/install/arm64/vmlinuz.efi" \
    "${work_dir}/vmlinuz.efi"
  chmod 0644 "${work_dir}/vmlinuz.efi"
  docker run --rm \
    --user "$(id -u):$(id -g)" \
    --entrypoint /bin/sh \
    -v "${work_dir}:/work" \
    "${verify_tools_image}" \
    -ceu '
      objcopy --dump-section .initrd=/work/initramfs.zst /work/vmlinuz.efi
      zstd --decompress --stdout /work/initramfs.zst >/work/initramfs
    '

  for expected_string in "${expected_initramfs_strings[@]}"; do
    if ! grep -aFq "${expected_string}" "${work_dir}/initramfs"; then
      printf 'installer initramfs is missing expected extension metadata: %s\n' \
        "${expected_string}" >&2
      exit 1
    fi
  done
fi

printf 'patched installer binary verification passed for %s\n' "${image_ref}"
