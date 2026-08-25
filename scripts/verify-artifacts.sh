#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/scripts/lib.sh"
load_versions

out_dir="${1:-${root}/dist}"
required=(
  BOOTAA64.EFI
  "Talos-${TALOS_VERSION}.efi"
  installer-arm64.tar
  loader.conf
  SHA256SUMS
  build.env
)

for file in "${required[@]}"; do
  if [[ ! -s "${out_dir}/${file}" ]]; then
    printf 'missing or empty artifact: %s\n' "${out_dir}/${file}" >&2
    exit 1
  fi
done

grep -Fxq "default Talos-${TALOS_VERSION}*" "${out_dir}/loader.conf"
if grep -Eq '(^|[[:space:]])ip=|talos\.config=' "${out_dir}/loader.conf"; then
  printf 'loader.conf contains a machine-specific network or config argument\n' >&2
  exit 1
fi

(
  cd "${out_dir}"
  check_sha256sums SHA256SUMS
)

printf 'artifact verification passed for %s\n' "${RELEASE_TAG}"
