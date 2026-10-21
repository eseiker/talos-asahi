#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "${root}/scripts/lib.sh"

assert_image_tag() {
  local expected="$1"
  local image_ref="$2"
  local actual

  actual="$(image_ref_tag "${image_ref}")"
  if [[ "${actual}" != "${expected}" ]]; then
    printf 'expected image tag %s, got %s\n' "${expected}" "${actual}" >&2
    exit 1
  fi
}

assert_image_tag v1.15.0-alpha.0-24-g977b61f \
  ghcr.io/siderolabs/kernel:v1.15.0-alpha.0-24-g977b61f
assert_image_tag v1.15.0-alpha.0-24-g977b61f \
  ghcr.io/siderolabs/kernel:v1.15.0-alpha.0-24-g977b61f@sha256:70520d9878090efa4d08ec8a6c658b575fd982dedc6f1946267cacb582c987c7
assert_image_tag test-tag \
  localhost:5000/example/kernel:test-tag@sha256:0123456789abcdef

sed_test_file="$(mktemp "${TMPDIR:-/tmp}/talos-asahi-sed.XXXXXX")"
trap 'rm -f "${sed_test_file}"' EXIT
printf 'alpha\ngamma\n' >"${sed_test_file}"
sed_in_place \
  -e 's/gamma/delta/' \
  -e $'/alpha/a\\\nbeta' \
  "${sed_test_file}"
if [[ "$(cat "${sed_test_file}")" != $'alpha\nbeta\ndelta' ]]; then
  printf 'portable in-place sed failed\n' >&2
  exit 1
fi

pkgfile_test="$(mktemp "${TMPDIR:-/tmp}/talos-asahi-pkgfile.XXXXXX")"
trap 'rm -f "${sed_test_file}" "${pkgfile_test}"' EXIT
cat >"${pkgfile_test}" <<'PKGFILE'
  # renovate: datasource=git-tags extractVersion=^v(?<version>.*)$ depName=git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
  linux_version: 6.18.57
  linux_ref: old-ref
  linux_sha256: old-sha256
  linux_sha512: old-sha512
PKGFILE
set_asahi_kernel_pin \
  "${pkgfile_test}" \
  7.1.13 \
  0123456789abcdef0123456789abcdef01234567 \
  0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
  0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
if ! grep -Fxq '  linux_version: 7.1.13' "${pkgfile_test}" ||
  ! grep -Fxq '  # Asahi Linux downstream kernel, pinned for reproducible Talos builds.' "${pkgfile_test}" ||
  ! grep -Fxq '  linux_ref: 0123456789abcdef0123456789abcdef01234567' "${pkgfile_test}" ||
  ! grep -Fxq '  linux_sha256: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' "${pkgfile_test}" ||
  ! grep -Fxq '  linux_sha512: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' "${pkgfile_test}"; then
  printf 'Asahi kernel pin was not applied to upstream Pkgfile\n' >&2
  exit 1
fi
if [[ "$(grep -c '^  linux_ref:' "${pkgfile_test}")" -ne 1 ]]; then
  printf 'expected exactly one Asahi kernel ref in Pkgfile\n' >&2
  exit 1
fi
if grep -q '^diff --git a/Pkgfile ' "${root}/patches/pkgs-asahi.patch"; then
  printf 'Asahi patch must not depend on the upstream Linux pin\n' >&2
  exit 1
fi

printf 'library tests passed\n'
