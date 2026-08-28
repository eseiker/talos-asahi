#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
versions_file="${VERSIONS_FILE:-${root}/versions.env}"

# shellcheck disable=SC1090
source "${versions_file}"

for command in gh curl jq awk sed base64; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    printf 'required command is missing: %s\n' "${command}" >&2
    exit 1
  fi
done

emit_output() {
  local key="$1"
  local value="$2"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "${key}" "${value}" >>"${GITHUB_OUTPUT}"
  fi
}

version_components() {
  local version="${1#v}"

  IFS=. read -r version_major version_minor version_patch <<<"${version}"
  printf '%d %d %d\n' "${version_major}" "${version_minor}" "${version_patch}"
}

version_is_newer() {
  local candidate_major candidate_minor candidate_patch
  local current_major current_minor current_patch

  read -r candidate_major candidate_minor candidate_patch < <(version_components "$1")
  read -r current_major current_minor current_patch < <(version_components "$2")

  if ((candidate_major != current_major)); then
    ((candidate_major > current_major))
  elif ((candidate_minor != current_minor)); then
    ((candidate_minor > current_minor))
  else
    ((candidate_patch > current_patch))
  fi
}

target_version="${TARGET_TALOS_VERSION:-$(gh api repos/siderolabs/talos/releases/latest --jq .tag_name)}"

if [[ ! "${target_version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'refusing non-stable Talos release tag: %s\n' "${target_version}" >&2
  exit 1
fi

emit_output talos_version "${target_version}"

if [[ "${target_version}" == "${TALOS_VERSION}" && "${FORCE_UPDATE:-false}" != "true" ]]; then
  emit_output updated false
  printf 'already tracking latest stable Talos release %s\n' "${TALOS_VERSION}"

  exit 0
fi

if ! version_is_newer "${target_version}" "${TALOS_VERSION}" && [[ "${FORCE_UPDATE:-false}" != "true" ]]; then
  emit_output updated false
  printf 'ignoring Talos release %s because current pin %s is newer\n' \
    "${target_version}" "${TALOS_VERSION}"

  exit 0
fi

talos_sha="$(gh api "repos/siderolabs/talos/commits/${target_version}" --jq .sha)"
talos_makefile="$(gh api "repos/siderolabs/talos/contents/Makefile?ref=${target_version}" --jq .content | base64 --decode)"
pkgs_abbrev="$(sed -n 's/^PKGS ?=.*-g\([0-9a-f][0-9a-f]*\)$/\1/p' <<<"${talos_makefile}")"

if [[ -z "${pkgs_abbrev}" ]]; then
  printf 'failed to extract the Talos pkgs commit from %s Makefile\n' "${target_version}" >&2
  exit 1
fi

pkgs_sha="$(gh api "repos/siderolabs/pkgs/commits/${pkgs_abbrev}" --jq .sha)"
pkgs_pkgfile="$(gh api "repos/siderolabs/pkgs/contents/Pkgfile?ref=${pkgs_sha}" --jq .content | base64 --decode)"
mainline_kernel_version="$(sed -n 's/^[[:space:]]*linux_version:[[:space:]]*\([^[:space:]]*\).*$/\1/p' <<<"${pkgs_pkgfile}" | head -n 1)"

if [[ -z "${mainline_kernel_version}" ]]; then
  printf 'failed to extract linux_version from Talos pkgs %s\n' "${pkgs_sha}" >&2
  exit 1
fi

extensions_catalog="$(
  curl --fail --silent --show-error --location \
    "https://factory.talos.dev/version/${target_version#v}/extensions/official"
)"

extension_image() {
  local extension_name="$1"

  jq --exit-status --raw-output --arg name "${extension_name}" \
    '.[] | select(.name == $name) | .ref + "@" + .digest' \
    <<<"${extensions_catalog}"
}

iscsi_tools_image="$(extension_image siderolabs/iscsi-tools)"
util_linux_tools_image="$(extension_image siderolabs/util-linux-tools)"

temporary_file="$(mktemp "${versions_file}.XXXXXX")"
trap 'rm -f "${temporary_file}"' EXIT

awk \
  -v talos_version="${target_version}" \
  -v talos_sha="${talos_sha}" \
  -v pkgs_sha="${pkgs_sha}" \
  -v mainline_kernel_version="${mainline_kernel_version}" \
  -v iscsi_tools_image="${iscsi_tools_image}" \
  -v util_linux_tools_image="${util_linux_tools_image}" \
  '
    /^TALOS_VERSION=/ { print "TALOS_VERSION=" talos_version; next }
    /^TALOS_SHA=/ { print "TALOS_SHA=" talos_sha; next }
    /^PKGS_SHA=/ { print "PKGS_SHA=" pkgs_sha; next }
    /^MAINLINE_KERNEL_VERSION=/ { print "MAINLINE_KERNEL_VERSION=" mainline_kernel_version; next }
    /^ISCSI_TOOLS_IMAGE=/ { print "ISCSI_TOOLS_IMAGE=" iscsi_tools_image; next }
    /^UTIL_LINUX_TOOLS_IMAGE=/ { print "UTIL_LINUX_TOOLS_IMAGE=" util_linux_tools_image; next }
    /^BUILD_REVISION=/ { print "BUILD_REVISION=1"; next }
    { print }
  ' "${versions_file}" >"${temporary_file}"

mv "${temporary_file}" "${versions_file}"
trap - EXIT

emit_output updated true
emit_output talos_sha "${talos_sha}"
emit_output pkgs_sha "${pkgs_sha}"
emit_output mainline_kernel_version "${mainline_kernel_version}"
emit_output iscsi_tools_image "${iscsi_tools_image}"
emit_output util_linux_tools_image "${util_linux_tools_image}"

printf 'updated pins: Talos %s (%s), pkgs %s, Linux %s, Longhorn extensions %s and %s\n' \
  "${target_version}" "${talos_sha}" "${pkgs_sha}" "${mainline_kernel_version}" \
  "${iscsi_tools_image}" "${util_linux_tools_image}"
