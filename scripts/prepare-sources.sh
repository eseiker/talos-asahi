#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/scripts/lib.sh"
load_versions

destination="${1:?usage: prepare-sources.sh DESTINATION}"
mkdir -p "${destination}"

clone_pinned https://github.com/siderolabs/talos.git "${TALOS_SHA}" "${destination}/talos"
clone_pinned https://github.com/siderolabs/pkgs.git "${PKGS_SHA}" "${destination}/pkgs"

apply_patch_checked "${destination}/talos" "${root}/patches/talos-asahi.patch"
apply_patch_checked "${destination}/pkgs" "${root}/patches/pkgs-asahi.patch"

printf 'prepared Talos %s and pkgs %s\n' "${TALOS_SHA}" "${PKGS_SHA}"
