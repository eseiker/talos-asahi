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

printf 'library tests passed\n'
