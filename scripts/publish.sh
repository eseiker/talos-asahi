#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/scripts/lib.sh"
load_versions

TARGET_REPOSITORY="${TARGET_REPOSITORY:?set TARGET_REPOSITORY, for example ghcr.io/owner/talos-asahi}"
OUT_DIR="${OUT_DIR:-${root}/_out}"
PUBLISH_LATEST="${PUBLISH_LATEST:-false}"

# Load the exact build identity before publishing anything.
# shellcheck disable=SC1091
source "${OUT_DIR}/build.env"

# The imager tar retains the patched base installer's repository tag. Loading
# it is intentional here: the newly loaded image includes our custom UKI and
# patched installer binary, and is immediately retagged into the requested
# repository.
docker load --input "${OUT_DIR}/installer-arm64.tar"
loaded_installer="${LOCAL_INSTALLER_BASE_IMAGE}"
installer_ref="${TARGET_REPOSITORY}/installer:${ARTIFACT_TAG}"
docker tag "${loaded_installer}" "${installer_ref}"
docker push "${installer_ref}"

if [[ "${PUBLISH_LATEST}" == "true" && "${KERNEL_FLAVOR}" == "asahi" ]]; then
  docker tag "${loaded_installer}" "${TARGET_REPOSITORY}/installer:latest"
  docker push "${TARGET_REPOSITORY}/installer:latest"
fi

# The Longhorn archive uses the same patched kernel and installer binary, but
# its initramfs also contains the iSCSI and util-linux system extensions.
docker load --input "${OUT_DIR}/installer-longhorn-arm64.tar"
longhorn_installer_ref="${TARGET_REPOSITORY}/installer:${LONGHORN_ARTIFACT_TAG}"
docker tag "${loaded_installer}" "${longhorn_installer_ref}"
docker push "${longhorn_installer_ref}"

# Publish the kernel as a traceable, optional input for later debugging.
kernel_ref="${TARGET_REPOSITORY}/kernel:${KERNEL_IMAGE_TAG}"
docker tag "${LOCAL_KERNEL_IMAGE}" "${kernel_ref}"
docker push "${kernel_ref}"

printf 'published %s\n' "${installer_ref}"
printf 'published %s\n' "${longhorn_installer_ref}"
printf 'published %s\n' "${kernel_ref}"
