#!/usr/bin/env bash

next_build_revision() {
  local talos_version="$1"
  local current_revision="$2"
  local tag revision
  local highest_revision=0
  local tag_prefix="${talos_version}-asahi."

  if [[ ! "${current_revision}" =~ ^[1-9][0-9]*$ ]]; then
    printf 'invalid current build revision: %s\n' "${current_revision}" >&2
    return 1
  fi

  while IFS= read -r tag; do
    if [[ "${tag}" != "${tag_prefix}"* ]]; then
      continue
    fi

    revision="${tag#"${tag_prefix}"}"
    if [[ ! "${revision}" =~ ^[1-9][0-9]*$ ]]; then
      continue
    fi

    if ((revision > highest_revision)); then
      highest_revision="${revision}"
    fi
  done

  if ((highest_revision < current_revision)); then
    printf '%s\n' "${current_revision}"
  else
    printf '%s\n' "$((highest_revision + 1))"
  fi
}
