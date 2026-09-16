#!/usr/bin/env bash

set -euo pipefail

repo_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

image_ref_tag() {
  local image_ref="${1%%@*}"

  printf '%s\n' "${image_ref##*:}"
}

sed_in_place() {
  if [[ "$(uname -s)" == Darwin ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

load_versions() {
  local root
  root="$(repo_root)"

  # shellcheck disable=SC1091
  source "${root}/versions.env"

  RELEASE_TAG="${TALOS_VERSION}-asahi.${BUILD_REVISION}"
  KERNEL_FLAVOR="${KERNEL_FLAVOR:-asahi}"
  EXTERNAL_KERNEL_IMAGE=
  EXTRA_KERNEL_ARGS=

  case "${KERNEL_FLAVOR}" in
    asahi)
      KERNEL_VERSION="${ASAHI_KERNEL_VERSION}"
      KERNEL_IMAGE_TAG="${ASAHI_KERNEL_VERSION}-asahi.${BUILD_REVISION}"
      ARTIFACT_TAG="${RELEASE_TAG}"
      BOOT_UKI="Talos-${TALOS_VERSION}.efi"
      KERNEL_PAGE_SIZE="16k"
      ;;
    mainline)
      KERNEL_VERSION="${MAINLINE_KERNEL_VERSION}"
      KERNEL_IMAGE_TAG="${MAINLINE_KERNEL_VERSION}-mainline.${BUILD_REVISION}"
      ARTIFACT_TAG="${RELEASE_TAG}-mainline"
      BOOT_UKI="Talos-${TALOS_VERSION}-mainline.efi"
      KERNEL_PAGE_SIZE="16k"
      ;;
    mainline-4k)
      KERNEL_VERSION="${MAINLINE_KERNEL_VERSION}"
      KERNEL_IMAGE_TAG="${MAINLINE_KERNEL_VERSION}-mainline-4k.${BUILD_REVISION}"
      ARTIFACT_TAG="${RELEASE_TAG}-mainline-4k"
      BOOT_UKI="Talos-${TALOS_VERSION}-mainline-4k.efi"
      KERNEL_PAGE_SIZE="4k"
      ;;
    v1.15)
      KERNEL_VERSION="${TALOS_1_15_KERNEL_VERSION}"
      KERNEL_IMAGE_TAG="$(image_ref_tag "${TALOS_1_15_KERNEL_IMAGE}")"
      ARTIFACT_TAG="${RELEASE_TAG}-v1.15"
      BOOT_UKI="Talos-${TALOS_VERSION}-v1.15.efi"
      KERNEL_PAGE_SIZE="4k"
      EXTERNAL_KERNEL_IMAGE="${TALOS_1_15_KERNEL_IMAGE}"
      # The upstream v1.15 kernel builds the Apple NVMe controller as a module
      # (CONFIG_NVME_APPLE=m) and never autoloads it, so Talos cannot read the
      # META partition and the node drops to maintenance. Load it from the
      # kernel command line before the boot sequence reads META.
      EXTRA_KERNEL_ARGS="talos.kernel.modules=nvme_apple"
      ;;
    *)
      printf 'unsupported KERNEL_FLAVOR: %s\n' "${KERNEL_FLAVOR}" >&2
      return 1
      ;;
  esac

  PREPARE_UKI="Talos-prepare.efi"
  BOOT_BUNDLE="talos-asahi-${ARTIFACT_TAG}-esp.zip"
  LONGHORN_BOOT_UKI="${BOOT_UKI%.efi}-longhorn.efi"
  LONGHORN_PREPARE_UKI="Talos-prepare-longhorn.efi"
  LONGHORN_BOOT_BUNDLE="talos-asahi-${ARTIFACT_TAG}-longhorn-esp.zip"
  export RELEASE_TAG KERNEL_FLAVOR KERNEL_VERSION KERNEL_IMAGE_TAG KERNEL_PAGE_SIZE
  export ARTIFACT_TAG BOOT_UKI PREPARE_UKI BOOT_BUNDLE
  export LONGHORN_BOOT_UKI LONGHORN_PREPARE_UKI LONGHORN_BOOT_BUNDLE
  export EXTERNAL_KERNEL_IMAGE EXTRA_KERNEL_ARGS
}

make_command() {
  if command -v gmake >/dev/null 2>&1; then
    printf '%s\n' gmake
  else
    printf '%s\n' make
  fi
}

clone_pinned() {
  local url="$1"
  local sha="$2"
  local destination="$3"

  git init -q "${destination}"
  git -C "${destination}" remote add origin "${url}"
  git -C "${destination}" fetch -q --depth=1 origin "${sha}"
  git -C "${destination}" checkout -q --detach FETCH_HEAD

  local actual
  actual="$(git -C "${destination}" rev-parse HEAD)"
  if [[ "${actual}" != "${sha}" ]]; then
    printf 'pin mismatch for %s: expected %s, got %s\n' "${url}" "${sha}" "${actual}" >&2
    return 1
  fi
}

apply_patch_checked() {
  local source_dir="$1"
  local patch_file="$2"

  git -C "${source_dir}" apply --check "${patch_file}"
  git -C "${source_dir}" apply "${patch_file}"
  git -C "${source_dir}" diff --check
}

write_sha256sums() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@"
  else
    shasum -a 256 "$@"
  fi
}

check_sha256sums() {
  local checksum_file="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum --check "${checksum_file}"
  else
    shasum -a 256 --check "${checksum_file}"
  fi
}
