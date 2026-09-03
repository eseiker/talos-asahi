#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${root}/scripts/lib.sh"
load_versions

LOCAL_REGISTRY="${LOCAL_REGISTRY:-localhost:5000}"
OUT_DIR="${OUT_DIR:-${root}/_out}"
PROGRESS="${PROGRESS:-plain}"
make_cmd="$(make_command)"
build_root="$(mktemp -d "${TMPDIR:-/tmp}/talos-asahi-build.XXXXXX")"

cleanup() {
  rm -rf "${build_root}"
}
trap cleanup EXIT

mkdir -p "${OUT_DIR}"
"${root}/scripts/prepare-sources.sh" "${build_root}"

kernel_image="${LOCAL_REGISTRY}/talos-asahi/kernel:${KERNEL_IMAGE_TAG}"
installer_base_image="${LOCAL_REGISTRY}/talos-asahi/installer-base:${ARTIFACT_TAG}"
imager_image="local/talos-asahi/imager:${ARTIFACT_TAG}"
prepare_tools_image="local/talos-asahi/prepare-tools:${ARTIFACT_TAG}"
kernel_target_args=(
  "--tag=${kernel_image}"
  "--output=type=docker"
)

if [[ -n "${KERNEL_CACHE_IMAGE:-}" ]]; then
  kernel_target_args+=(
    "--cache-from=type=registry,ref=${KERNEL_CACHE_IMAGE}"
    "--cache-to=type=registry,ref=${KERNEL_CACHE_IMAGE},mode=max,oci-mediatypes=true,image-manifest=true,ignore-error=true"
  )
fi

printf 'building %s kernel image %s\n' "${KERNEL_FLAVOR}" "${kernel_image}"
"${make_cmd}" -C "${build_root}/pkgs" target-kernel \
  PLATFORM=linux/arm64 \
  PROGRESS="${PROGRESS}" \
  TARGET_ARGS="${kernel_target_args[*]}"
docker push "${kernel_image}"

printf 'building patched Talos installer base %s\n' "${installer_base_image}"
"${make_cmd}" -C "${build_root}/talos" target-installer-base \
  PLATFORM=linux/arm64 \
  PROGRESS="${PROGRESS}" \
  TAG="${TALOS_VERSION}" \
  ABBREV_TAG="${TALOS_VERSION}" \
  SHA="${TALOS_SHA:0:8}" \
  PKG_KERNEL="${kernel_image}" \
  PKG_KERNEL_ARM64="${kernel_image}" \
  TARGET_ARGS="--tag=${installer_base_image} --output=type=docker"
docker push "${installer_base_image}"

printf 'building patched Talos imager %s\n' "${imager_image}"
"${make_cmd}" -C "${build_root}/talos" target-imager \
  PLATFORM=linux/arm64 \
  PROGRESS="${PROGRESS}" \
  TAG="${TALOS_VERSION}" \
  ABBREV_TAG="${TALOS_VERSION}" \
  SHA="${TALOS_SHA:0:8}" \
  PKG_KERNEL="${kernel_image}" \
  PKG_KERNEL_ARM64="${kernel_image}" \
  TARGET_ARGS="--tag=${imager_image} --output=type=docker"

printf 'building prepare and installer verification tools\n'
docker buildx build --load \
  --platform linux/arm64 \
  --file "${root}/prepare/Dockerfile" \
  --target tools \
  --tag "${prepare_tools_image}" \
  "${root}/prepare"

printf 'generating generic installer and boot bundle\n'
standard_installer_out="${OUT_DIR}/installer-standard"
longhorn_installer_out="${OUT_DIR}/installer-longhorn"
rm -rf "${standard_installer_out}" "${longhorn_installer_out}"
mkdir -p "${standard_installer_out}" "${longhorn_installer_out}"

docker run --rm --network=host \
  --user "$(id -u):$(id -g)" \
  -v "${standard_installer_out}:/out" \
  "${imager_image}" installer --arch arm64 \
  --base-installer-image "${installer_base_image}" \
  --insecure

mv "${standard_installer_out}/installer-arm64.tar" "${OUT_DIR}/installer-arm64.tar"
rmdir "${standard_installer_out}"

"${root}/scripts/verify-installer-image.sh" \
  "${OUT_DIR}/installer-arm64.tar" "${installer_base_image}"

printf 'generating Longhorn installer with Talos system extensions\n'
docker run --rm --network=host \
  --user "$(id -u):$(id -g)" \
  -v "${longhorn_installer_out}:/out" \
  "${imager_image}" installer --arch arm64 \
  --base-installer-image "${installer_base_image}" \
  --system-extension-image "${ISCSI_TOOLS_IMAGE}" \
  --system-extension-image "${UTIL_LINUX_TOOLS_IMAGE}" \
  --insecure

mv "${longhorn_installer_out}/installer-arm64.tar" \
  "${OUT_DIR}/installer-longhorn-arm64.tar"
rmdir "${longhorn_installer_out}"

VERIFY_TOOLS_IMAGE="${prepare_tools_image}" \
  "${root}/scripts/verify-installer-image.sh" \
  "${OUT_DIR}/installer-longhorn-arm64.tar" "${installer_base_image}" \
  'name: iscsi-tools' \
  'name: util-linux-tools'

generate_metal_uki() {
  local destination="$1"
  shift

  docker run --rm \
    --user "$(id -u):$(id -g)" \
    -v "${OUT_DIR}:/out" \
    "${imager_image}" metal --arch arm64 --output-kind uki "$@"

  docker run --rm \
    --user "$(id -u):$(id -g)" \
    --entrypoint /usr/bin/unzstd \
    -v "${OUT_DIR}:/out" \
    "${imager_image}" \
    -f /out/metal-arm64-uki.efi.zst -o "/out/${destination}"
  rm -f "${OUT_DIR}/metal-arm64-uki.efi.zst"
}

generate_metal_uki "${BOOT_UKI}"
generate_metal_uki "${LONGHORN_BOOT_UKI}" \
  --system-extension-image "${ISCSI_TOOLS_IMAGE}" \
  --system-extension-image "${UTIL_LINUX_TOOLS_IMAGE}"

container_id="$(docker create "${imager_image}")"
docker cp "${container_id}:/usr/install/arm64/systemd-boot.efi" "${OUT_DIR}/BOOTAA64.efi"
docker rm "${container_id}" >/dev/null

printf 'building one-time prepare UKI\n'
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v "${OUT_DIR}:/out" \
  "${prepare_tools_image}" \
  "/out/${BOOT_UKI}" "/out/${PREPARE_UKI}" "${BOOT_UKI}"
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v "${OUT_DIR}:/out" \
  "${prepare_tools_image}" \
  "/out/${LONGHORN_BOOT_UKI}" "/out/${LONGHORN_PREPARE_UKI}" \
  "${LONGHORN_BOOT_UKI}"

printf '# systemd-boot configuration\n\ndefault %s\ntimeout 0\neditor no\n' \
  "${PREPARE_UKI}" >"${OUT_DIR}/loader.conf"
printf '# systemd-boot configuration\n\ndefault %s\ntimeout 0\neditor no\n' \
  "${PREPARE_UKI}" >"${OUT_DIR}/loader-longhorn.conf"

cat >"${OUT_DIR}/build.env" <<EOF
TALOS_VERSION=${TALOS_VERSION}
TALOS_SHA=${TALOS_SHA}
ASAHI_KERNEL_TAG=${ASAHI_KERNEL_TAG}
ASAHI_KERNEL_VERSION=${ASAHI_KERNEL_VERSION}
ASAHI_KERNEL_SHA=${ASAHI_KERNEL_SHA}
ASAHI_KERNEL_SHA256=${ASAHI_KERNEL_SHA256}
ASAHI_KERNEL_SHA512=${ASAHI_KERNEL_SHA512}
MAINLINE_KERNEL_VERSION=${MAINLINE_KERNEL_VERSION}
KERNEL_FLAVOR=${KERNEL_FLAVOR}
KERNEL_VERSION=${KERNEL_VERSION}
KERNEL_PAGE_SIZE=${KERNEL_PAGE_SIZE}
RELEASE_TAG=${RELEASE_TAG}
ARTIFACT_TAG=${ARTIFACT_TAG}
LONGHORN_ARTIFACT_TAG=${ARTIFACT_TAG}-longhorn
ISCSI_TOOLS_IMAGE=${ISCSI_TOOLS_IMAGE}
UTIL_LINUX_TOOLS_IMAGE=${UTIL_LINUX_TOOLS_IMAGE}
BOOT_UKI=${BOOT_UKI}
PREPARE_UKI=${PREPARE_UKI}
BOOT_BUNDLE=${BOOT_BUNDLE}
LONGHORN_BOOT_UKI=${LONGHORN_BOOT_UKI}
LONGHORN_PREPARE_UKI=${LONGHORN_PREPARE_UKI}
LONGHORN_BOOT_BUNDLE=${LONGHORN_BOOT_BUNDLE}
LOCAL_KERNEL_IMAGE=${kernel_image}
LOCAL_INSTALLER_BASE_IMAGE=${installer_base_image}
LOCAL_IMAGER_IMAGE=${imager_image}
EOF

build_esp_bundle() {
  local final_uki="$1"
  local prepare_uki_source="$2"
  local loader_source="$3"
  local bundle="$4"
  local bundle_root="${build_root}/esp-${bundle}"

  mkdir -p \
    "${bundle_root}/EFI/BOOT" \
    "${bundle_root}/EFI/Linux" \
    "${bundle_root}/loader"
  cp "${OUT_DIR}/BOOTAA64.efi" "${bundle_root}/EFI/BOOT/BOOTAA64.efi"
  cp "${OUT_DIR}/${prepare_uki_source}" \
    "${bundle_root}/EFI/Linux/${PREPARE_UKI}"
  cp "${OUT_DIR}/${final_uki}" "${bundle_root}/EFI/Linux/${final_uki}"
  cp "${OUT_DIR}/${loader_source}" "${bundle_root}/loader/loader.conf"
  find "${bundle_root}" -exec touch -t 198001010000 {} +
  rm -f "${OUT_DIR}/${bundle}"
  docker run --rm \
    --user "$(id -u):$(id -g)" \
    --entrypoint /usr/bin/zip \
    --workdir /bundle \
    -v "${bundle_root}:/bundle:ro" \
    -v "${OUT_DIR}:/out" \
    "${prepare_tools_image}" \
    -X -D -q -r "/out/${bundle}" EFI loader
}

build_esp_bundle \
  "${BOOT_UKI}" "${PREPARE_UKI}" loader.conf "${BOOT_BUNDLE}"
build_esp_bundle \
  "${LONGHORN_BOOT_UKI}" "${LONGHORN_PREPARE_UKI}" \
  loader-longhorn.conf "${LONGHORN_BOOT_BUNDLE}"

(
  cd "${OUT_DIR}"
  write_sha256sums "${BOOT_BUNDLE}" "${LONGHORN_BOOT_BUNDLE}" >SHA256SUMS
)

VERIFY_TOOLS_IMAGE="${prepare_tools_image}" \
  "${root}/scripts/verify-artifacts.sh" "${OUT_DIR}"
printf 'build complete: %s\n' "${OUT_DIR}"
