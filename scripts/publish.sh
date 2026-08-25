#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/scripts/lib.sh"
load_versions

TARGET_REPOSITORY="${TARGET_REPOSITORY:?set TARGET_REPOSITORY, for example ghcr.io/owner/talos-asahi}"
OUT_DIR="${OUT_DIR:-${root}/_out}"
PUBLISH_LATEST="${PUBLISH_LATEST:-false}"

# The imager tar retains the base installer's original repository tag. Loading
# it is intentional here: the newly loaded image includes our custom UKI and
# installer binary, and is immediately retagged into the requested repository.
docker load --input "${OUT_DIR}/installer-arm64.tar"
loaded_installer="ghcr.io/siderolabs/installer-base:${TALOS_VERSION}"
installer_ref="${TARGET_REPOSITORY}/installer:${RELEASE_TAG}"
docker tag "${loaded_installer}" "${installer_ref}"
docker push "${installer_ref}"

if [[ "${PUBLISH_LATEST}" == "true" ]]; then
  docker tag "${loaded_installer}" "${TARGET_REPOSITORY}/installer:latest"
  docker push "${TARGET_REPOSITORY}/installer:latest"
fi

# Publish the kernel as a traceable, optional input for later debugging.
# shellcheck disable=SC1090
source "${OUT_DIR}/build.env"
kernel_ref="${TARGET_REPOSITORY}/kernel:${ASAHI_KERNEL_VERSION}-asahi.${BUILD_REVISION}"
docker tag "${LOCAL_KERNEL_IMAGE}" "${kernel_ref}"
docker push "${kernel_ref}"

printf 'published %s\n' "${installer_ref}"
