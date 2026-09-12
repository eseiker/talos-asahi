#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/scripts/release-policy.sh"

assert_channel() {
  local expected="$1"
  local tag="$2"
  local actual

  actual="$(release_channel "${tag}")"
  if [[ "${actual}" != "${expected}" ]]; then
    printf 'expected %s channel for %s, got %s\n' "${expected}" "${tag}" "${actual}" >&2
    return 1
  fi
}

assert_at_least() {
  if ! stable_release_at_least "$1" "$2"; then
    printf 'expected %s to be at least %s\n' "$1" "$2" >&2
    return 1
  fi
}

assert_older() {
  local status

  if stable_release_at_least "$1" "$2"; then
    printf 'expected %s to be older than %s\n' "$1" "$2" >&2
    return 1
  else
    status=$?
  fi

  if [[ ${status} -ne 1 ]]; then
    printf 'comparison of %s and %s failed with status %d\n' "$1" "$2" "${status}" >&2
    return 1
  fi
}

assert_channel stable v1.14.1-asahi.1
assert_channel prerelease v1.15.0-alpha.0-asahi.1
assert_channel prerelease v1.15.0-beta.2-asahi.3
assert_channel prerelease v1.15.0-rc.1-asahi.1

if release_channel v1.15.0-dev.1-asahi.1 >/dev/null 2>&1; then
  printf 'unsupported prerelease tag was accepted\n' >&2
  exit 1
fi

assert_at_least v1.14.0-asahi.1 v1.13.10-asahi.99
assert_at_least v1.14.1-asahi.1 v1.14.0-asahi.99
assert_at_least v1.14.1-asahi.2 v1.14.1-asahi.1
assert_at_least v1.14.1-asahi.2 v1.14.1-asahi.2
assert_older v1.13.10-asahi.99 v1.14.0-asahi.1
assert_older v1.14.1-asahi.1 v1.14.1-asahi.2

if stable_release_at_least v1.15.0-alpha.0-asahi.1 v1.14.0-asahi.1; then
  printf 'prerelease tag was accepted by stable comparison\n' >&2
  exit 1
else
  status=$?
fi
if [[ ${status} -ne 2 ]]; then
  printf 'invalid stable comparison did not return status 2\n' >&2
  exit 1
fi

printf 'release policy tests passed\n'
