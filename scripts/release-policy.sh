#!/usr/bin/env bash

release_channel() {
  local tag="$1"

  if [[ "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-asahi\.[0-9]+$ ]]; then
    printf '%s\n' stable
  elif [[ "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-(alpha|beta|rc)\.[0-9]+-asahi\.[0-9]+$ ]]; then
    printf '%s\n' prerelease
  else
    printf 'unsupported Talos Asahi release tag: %s\n' "${tag}" >&2
    return 1
  fi
}

stable_release_key() {
  local tag="$1"

  if [[ ! "${tag}" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)-asahi\.([0-9]+)$ ]]; then
    return 1
  fi

  printf '%010d%010d%010d%010d\n' \
    "$((10#${BASH_REMATCH[1]}))" \
    "$((10#${BASH_REMATCH[2]}))" \
    "$((10#${BASH_REMATCH[3]}))" \
    "$((10#${BASH_REMATCH[4]}))"
}

stable_release_at_least() {
  local candidate_key current_key

  candidate_key="$(stable_release_key "$1")" || return 2
  current_key="$(stable_release_key "$2")" || return 2

  [[ "${candidate_key}" == "${current_key}" || "${candidate_key}" > "${current_key}" ]]
}
