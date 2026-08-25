#!/usr/bin/env bash

set -euo pipefail

repo_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

load_versions() {
  local root
  root="$(repo_root)"

  # shellcheck disable=SC1091
  source "${root}/versions.env"

  RELEASE_TAG="${TALOS_VERSION}-asahi.${BUILD_REVISION}"
  export RELEASE_TAG
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
