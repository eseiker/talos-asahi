#!/bin/sh

set -eu

export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export SOURCE_DATE_EPOCH=0

if [ "$#" -ne 3 ]; then
  printf 'usage: %s SOURCE_UKI PREPARE_UKI TARGET_UKI_FILENAME\n' "$0" >&2
  exit 2
fi

source_uki="$1"
prepare_uki="$2"
target_uki="$3"

[ -s "$source_uki" ] || {
  printf 'source UKI is missing or empty: %s\n' "$source_uki" >&2
  exit 1
}
case "$target_uki" in
  Talos-*.efi) ;;
  *) printf 'invalid target UKI filename: %s\n' "$target_uki" >&2; exit 1 ;;
esac
case "$target_uki" in
  */*|*..*) printf 'unsafe target UKI filename: %s\n' "$target_uki" >&2; exit 1 ;;
esac

work_dir="$(mktemp -d /tmp/talos-asahi-prepare-uki.XXXXXX)"
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

cmdline="talos.platform=metal console=ttyAMA0 console=tty0 nvme_core.io_timeout=4294967295 rdinit=/init talos_asahi.target=${target_uki}"
printf '%s\000' "$cmdline" >"$work_dir/cmdline"

# Keep the source UKI's .osrel section byte-for-byte.  Replacing it with a
# shorter os-release makes GNU objcopy pad the fixed-size PE section with NUL
# bytes.  systemd-boot's UKI discovery rejects that malformed os-release, so
# the prepare image silently disappears from the boot menu.
objcopy --dump-section .osrel="$work_dir/source-osrel" "$source_uki"

cp "$source_uki" "$prepare_uki"
objcopy \
  --update-section .initrd=/prepare-initramfs.zst \
  --update-section .cmdline="$work_dir/cmdline" \
  "$prepare_uki"

objcopy --dump-section .cmdline="$work_dir/verify-cmdline" "$prepare_uki"
objcopy --dump-section .initrd="$work_dir/verify-initrd" "$prepare_uki"
objcopy --dump-section .osrel="$work_dir/verify-osrel" "$prepare_uki"

verify_padded_section() {
  expected="$1"
  actual="$2"
  expected_size="$(wc -c <"$expected" | tr -d ' ')"

  dd if="$actual" bs=1 count="$expected_size" status=none | cmp "$expected" -
  if dd if="$actual" bs=1 skip="$expected_size" status=none | tr -d '\000' | grep -q .; then
    printf 'section %s has unexpected non-zero padding\n' "$actual" >&2
    exit 1
  fi
}

verify_padded_section "$work_dir/cmdline" "$work_dir/verify-cmdline"
verify_padded_section /prepare-initramfs.zst "$work_dir/verify-initrd"
cmp "$work_dir/source-osrel" "$work_dir/verify-osrel"

printf 'created prepare UKI %s for %s\n' "$prepare_uki" "$target_uki"
