#!/usr/bin/env bash

set -euo pipefail

archive="${1:?usage: verify-installer-image.sh ARCHIVE IMAGE_REF}"
image_ref="${2:?usage: verify-installer-image.sh ARCHIVE IMAGE_REF}"
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

printf 'patched installer binary verification passed for %s\n' "${image_ref}"
