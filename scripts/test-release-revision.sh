#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/release-revision.sh
source "${root}/scripts/release-revision.sh"

assert_revision() {
  local expected="$1"
  local talos_version="$2"
  local current_revision="$3"
  local tags="$4"
  local actual

  actual="$(next_build_revision "${talos_version}" "${current_revision}" <<<"${tags}")"
  if [[ "${actual}" != "${expected}" ]]; then
    printf 'expected revision %s, got %s\n' "${expected}" "${actual}" >&2
    exit 1
  fi
}

assert_revision 1 v1.15.0-alpha.0 1 ''
assert_revision 2 v1.13.10 1 'v1.13.10-asahi.1'
assert_revision 2 v1.14.0 2 'v1.14.0-asahi.1'
assert_revision 4 v1.14.0 2 $'v1.14.0-asahi.1\nv1.14.0-asahi.3'
assert_revision 2 v1.14.0 2 $'v1.13.10-asahi.9\nv1.14.0-asahi.invalid'

if next_build_revision v1.14.0 0 </dev/null; then
  printf 'revision zero should be rejected\n' >&2
  exit 1
fi

printf 'release revision tests passed\n'
