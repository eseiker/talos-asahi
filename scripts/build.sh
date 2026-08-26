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

kernel_image="${LOCAL_REGISTRY}/talos-asahi/kernel:${ASAHI_KERNEL_VERSION}-asahi.${BUILD_REVISION}"
imager_image="local/talos-asahi/imager:${RELEASE_TAG}"
boot_uki="Talos-${TALOS_VERSION}~${BUILD_REVISION}.efi"

printf 'building Asahi kernel image %s\n' "${kernel_image}"
"${make_cmd}" -C "${build_root}/pkgs" target-kernel \
  PLATFORM=linux/arm64 \
  PROGRESS="${PROGRESS}" \
  TARGET_ARGS="--tag=${kernel_image} --output=type=docker"
docker push "${kernel_image}"

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

printf 'generating generic installer and boot bundle\n'
docker run --rm --network=host \
  --user "$(id -u):$(id -g)" \
  -v "${OUT_DIR}:/out" \
  "${imager_image}" installer --arch arm64

docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v "${OUT_DIR}:/out" \
  "${imager_image}" metal --arch arm64 --output-kind uki

docker run --rm \
  --user "$(id -u):$(id -g)" \
  --entrypoint /usr/bin/unzstd \
  -v "${OUT_DIR}:/out" \
  "${imager_image}" \
  -f /out/metal-arm64-uki.efi.zst -o "/out/${boot_uki}"
rm -f "${OUT_DIR}/metal-arm64-uki.efi.zst"

container_id="$(docker create "${imager_image}")"
docker cp "${container_id}:/usr/install/arm64/systemd-boot.efi" "${OUT_DIR}/BOOTAA64.EFI"
docker rm "${container_id}" >/dev/null

printf '# systemd-boot configuration\n\ndefault %s*\ntimeout 5\neditor no\n' \
  "${boot_uki%.efi}" >"${OUT_DIR}/loader.conf"

cat >"${OUT_DIR}/build.env" <<EOF
TALOS_VERSION=${TALOS_VERSION}
TALOS_SHA=${TALOS_SHA}
ASAHI_KERNEL_VERSION=${ASAHI_KERNEL_VERSION}
ASAHI_KERNEL_SHA=${ASAHI_KERNEL_SHA}
RELEASE_TAG=${RELEASE_TAG}
BOOT_UKI=${boot_uki}
LOCAL_KERNEL_IMAGE=${kernel_image}
LOCAL_IMAGER_IMAGE=${imager_image}
EOF

boot_bundle="talos-asahi-${RELEASE_TAG}-boot.tar.gz"
tar -C "${OUT_DIR}" -czf "${OUT_DIR}/${boot_bundle}" \
  BOOTAA64.EFI "${boot_uki}" loader.conf build.env

(
  cd "${OUT_DIR}"
  write_sha256sums \
    BOOTAA64.EFI \
    "${boot_uki}" \
    installer-arm64.tar \
    loader.conf \
    build.env \
    "${boot_bundle}" >SHA256SUMS
)

"${root}/scripts/verify-artifacts.sh" "${OUT_DIR}"
printf 'build complete: %s\n' "${OUT_DIR}"
