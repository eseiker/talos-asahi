#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
versions_file="${VERSIONS_FILE:-${root}/versions.env}"

# shellcheck source=versions.env
source "${versions_file}"

for command in gh curl jq awk sed base64 sha256sum sha512sum sort; do
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

version_tag_is_newer() {
  local candidate="$1"
  local current="$2"

  [[ "${candidate}" != "${current}" &&
    "$(printf '%s\n%s\n' "${candidate}" "${current}" | sort -V | tail -n 1)" == "${candidate}" ]]
}

target_version="${TARGET_TALOS_VERSION:-$(gh api repos/siderolabs/talos/releases/latest --jq .tag_name)}"
force_update="${FORCE_UPDATE:-false}"
target_asahi_tag="${TARGET_ASAHI_TAG:-}"

if [[ -z "${target_asahi_tag}" ]]; then
  target_asahi_tag="$(
    gh api --paginate "repos/AsahiLinux/linux/git/matching-refs/tags/asahi-" --jq '.[].ref' |
      sed -nE 's#^refs/tags/(asahi-[0-9]+\.[0-9]+\.[0-9]+-[0-9]+)$#\1#p' |
      sort -V |
      tail -n 1
  )"
fi

if [[ ! "${target_version}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'refusing non-stable Talos release tag: %s\n' "${target_version}" >&2
  exit 1
fi

emit_output talos_version "${target_version}"

talos_updated=false
ignored_talos_version=
if [[ "${target_version}" != "${TALOS_VERSION}" ]]; then
  if version_is_newer "${target_version}" "${TALOS_VERSION}" || [[ "${force_update}" == "true" ]]; then
    talos_updated=true
  else
    ignored_talos_version="${target_version}"
    target_version="${TALOS_VERSION}"
    emit_output talos_version "${target_version}"
  fi
fi

if [[ "${target_version}" == "${TALOS_VERSION}" && "${talos_updated}" == "false" &&
      "${force_update}" != "true" ]]; then
  if [[ -n "${ignored_talos_version}" ]]; then
    printf 'ignoring Talos release %s because current pin %s is newer\n' \
      "${ignored_talos_version}" "${TALOS_VERSION}"
  else
    printf 'already tracking latest stable Talos release %s\n' "${TALOS_VERSION}"
  fi
fi

if [[ ! "${target_asahi_tag}" =~ ^asahi-[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$ ]]; then
  printf 'failed to resolve latest stable Asahi kernel tag\n' >&2
  exit 1
fi

asahi_sha="$(gh api "repos/AsahiLinux/linux/commits/${target_asahi_tag}" --jq .sha)"
asahi_makefile="$(gh api "repos/AsahiLinux/linux/contents/Makefile?ref=${asahi_sha}" --jq .content | base64 --decode)"
asahi_version="$(
  awk '
    /^VERSION = / { major=$3 }
    /^PATCHLEVEL = / { minor=$3 }
    /^SUBLEVEL = / { patch=$3 }
    END {
      if (major ~ /^[0-9]+$/ && minor ~ /^[0-9]+$/ && patch ~ /^[0-9]+$/) {
        printf "%s.%s.%s", major, minor, patch
      }
    }
  ' <<<"${asahi_makefile}"
)"

if [[ ! "${asahi_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ||
      ! "${asahi_sha}" =~ ^[0-9a-f]{40}$ ||
      "${target_asahi_tag}" != "asahi-${asahi_version}-"* ]]; then
  printf 'invalid stable Asahi kernel tag %s\n' "${target_asahi_tag}" >&2
  exit 1
fi

asahi_updated=false
if [[ "${target_asahi_tag}" != "${ASAHI_KERNEL_TAG}" ]]; then
  if version_tag_is_newer "${target_asahi_tag}" "${ASAHI_KERNEL_TAG}" ||
    [[ "${force_update}" == "true" ]]; then
    asahi_updated=true
  else
    printf 'ignoring Asahi kernel %s because current pin %s is newer\n' \
      "${target_asahi_tag}" "${ASAHI_KERNEL_TAG}"
    target_asahi_tag="${ASAHI_KERNEL_TAG}"
    asahi_version="${ASAHI_KERNEL_VERSION}"
    asahi_sha="${ASAHI_KERNEL_SHA}"
  fi
elif [[ "${asahi_sha}" != "${ASAHI_KERNEL_SHA}" ]]; then
  asahi_updated=true
fi

if [[ "${talos_updated}" == "false" && "${asahi_updated}" == "false" &&
      "${force_update}" != "true" ]]; then
  emit_output updated false
  printf 'already tracking Asahi kernel %s (%s)\n' "${ASAHI_KERNEL_TAG}" "${ASAHI_KERNEL_SHA}"

  exit 0
fi

talos_sha="${TALOS_SHA}"
pkgs_sha="${PKGS_SHA}"
mainline_kernel_version="${MAINLINE_KERNEL_VERSION}"
iscsi_tools_image="${ISCSI_TOOLS_IMAGE}"
util_linux_tools_image="${UTIL_LINUX_TOOLS_IMAGE}"

if [[ "${talos_updated}" == "true" || "${force_update}" == "true" ]]; then
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
fi

asahi_sha256="${ASAHI_KERNEL_SHA256}"
asahi_sha512="${ASAHI_KERNEL_SHA512}"
if [[ "${asahi_updated}" == "true" || "${force_update}" == "true" ]]; then
  asahi_archive="$(mktemp "${TMPDIR:-/tmp}/talos-asahi-kernel.XXXXXX.tar.gz")"
  trap 'rm -f "${asahi_archive}"' EXIT
  curl --fail --silent --show-error --location \
    "https://github.com/AsahiLinux/linux/archive/${asahi_sha}.tar.gz" \
    --output "${asahi_archive}"
  asahi_sha256="$(sha256sum "${asahi_archive}" | awk '{ print $1 }')"
  asahi_sha512="$(sha512sum "${asahi_archive}" | awk '{ print $1 }')"
  rm -f "${asahi_archive}"
  trap - EXIT
fi

build_revision=1
if [[ "${talos_updated}" == "false" ]]; then
  build_revision=$((BUILD_REVISION + 1))
fi

temporary_file="$(mktemp "${versions_file}.XXXXXX")"
trap 'rm -f "${temporary_file}"' EXIT

awk \
  -v talos_version="${target_version}" \
  -v talos_sha="${talos_sha}" \
  -v pkgs_sha="${pkgs_sha}" \
  -v asahi_tag="${target_asahi_tag}" \
  -v asahi_version="${asahi_version}" \
  -v asahi_sha="${asahi_sha}" \
  -v asahi_sha256="${asahi_sha256}" \
  -v asahi_sha512="${asahi_sha512}" \
  -v mainline_kernel_version="${mainline_kernel_version}" \
  -v iscsi_tools_image="${iscsi_tools_image}" \
  -v util_linux_tools_image="${util_linux_tools_image}" \
  -v build_revision="${build_revision}" \
  '
    /^TALOS_VERSION=/ { print "TALOS_VERSION=" talos_version; next }
    /^TALOS_SHA=/ { print "TALOS_SHA=" talos_sha; next }
    /^PKGS_SHA=/ { print "PKGS_SHA=" pkgs_sha; next }
    /^ASAHI_KERNEL_TAG=/ { print "ASAHI_KERNEL_TAG=" asahi_tag; next }
    /^ASAHI_KERNEL_VERSION=/ { print "ASAHI_KERNEL_VERSION=" asahi_version; next }
    /^ASAHI_KERNEL_SHA=/ { print "ASAHI_KERNEL_SHA=" asahi_sha; next }
    /^ASAHI_KERNEL_SHA256=/ { print "ASAHI_KERNEL_SHA256=" asahi_sha256; next }
    /^ASAHI_KERNEL_SHA512=/ { print "ASAHI_KERNEL_SHA512=" asahi_sha512; next }
    /^MAINLINE_KERNEL_VERSION=/ { print "MAINLINE_KERNEL_VERSION=" mainline_kernel_version; next }
    /^# Talos v[0-9]+\.[0-9]+\.[0-9]+ system extensions/ {
      print "# Talos " talos_version " system extensions used by the Longhorn installer variants."
      next
    }
    /^ISCSI_TOOLS_IMAGE=/ { print "ISCSI_TOOLS_IMAGE=" iscsi_tools_image; next }
    /^UTIL_LINUX_TOOLS_IMAGE=/ { print "UTIL_LINUX_TOOLS_IMAGE=" util_linux_tools_image; next }
    /^BUILD_REVISION=/ { print "BUILD_REVISION=" build_revision; next }
    { print }
  ' "${versions_file}" >"${temporary_file}"

mv "${temporary_file}" "${versions_file}"
trap - EXIT

emit_output updated true
emit_output talos_sha "${talos_sha}"
emit_output pkgs_sha "${pkgs_sha}"
emit_output asahi_kernel_tag "${target_asahi_tag}"
emit_output asahi_kernel_version "${asahi_version}"
emit_output asahi_kernel_sha "${asahi_sha}"
emit_output mainline_kernel_version "${mainline_kernel_version}"
emit_output iscsi_tools_image "${iscsi_tools_image}"
emit_output util_linux_tools_image "${util_linux_tools_image}"

printf 'updated pins: Talos %s (%s), pkgs %s, Asahi Linux %s (%s), Linux %s, Longhorn extensions %s and %s\n' \
  "${target_version}" "${talos_sha}" "${pkgs_sha}" "${target_asahi_tag}" "${asahi_sha}" "${mainline_kernel_version}" \
  "${iscsi_tools_image}" "${util_linux_tools_image}"
