#!/bin/sh

set -eu

export LC_ALL=C
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

work_dir="${1:-/tmp/prepare-gpt-tests}"
helper=/usr/libexec/talos-asahi/prepare-gpt
uuid_helper=/usr/libexec/talos-asahi/meta-uuid
mkdir -p "$work_dir"

fail() {
  printf 'prepare GPT test failed: %s\n' "$*" >&2
  exit 1
}

partition_name() {
  image="$1"
  number="$2"
  sgdisk --info="$number" "$image" | sed -n "s/^Partition name: '\(.*\)'$/\1/p"
}

partition_first() {
  image="$1"
  number="$2"
  sgdisk --info="$number" "$image" | awk '/^First sector:/ { print $3; exit }'
}

new_image() {
  image="$1"
  truncate -s 64M "$image"
  sgdisk --clear "$image" >/dev/null
  sgdisk --new=1:2048:18431 --typecode=1:ef00 --change-name=1:ASAHI_ESP "$image" >/dev/null
  sgdisk --new=4:100352:129023 --typecode=4:af0a --change-name=4:RecoveryOSContainer "$image" >/dev/null
}

read_meta_uuid() {
  image="$1"
  number="$2"
  first="$(partition_first "$image" "$number")"
  "$uuid_helper" "$image" "$((first * 512))" | awk '{ print $3 }'
}

standard="$work_dir/standard.img"
new_image "$standard"
printf 'old-data' | dd of="$standard" bs=1 seek=$((18432 * 512)) conv=notrunc status=none
"$helper" "$standard" 1 512 >/dev/null
[ "$(partition_name "$standard" 1)" = EFI ] || fail 'ESP was not relabeled'
[ "$(partition_name "$standard" 2)" = META ] || fail 'META was not created'
standard_uuid="$(read_meta_uuid "$standard" 2)"
case "$standard_uuid" in
  ????????-????-????-????-????????????) ;;
  *) fail "META UUIDOverride is invalid: $standard_uuid" ;;
esac

meta_first="$(partition_first "$standard" 2)"
sentinel_offset=$((meta_first * 512 + 700 * 1024))
printf 'preserve-existing-meta' | dd of="$standard" bs=1 seek="$sentinel_offset" conv=notrunc status=none
"$helper" "$standard" 1 512 >/dev/null
preserved="$(dd if="$standard" bs=1 skip="$sentinel_offset" count=22 status=none)"
[ "$preserved" = preserve-existing-meta ] || fail 'idempotent run erased existing META contents'
[ "$(read_meta_uuid "$standard" 2)" = "$standard_uuid" ] || \
  fail 'idempotent run changed UUIDOverride'

pending="$work_dir/pending.img"
new_image "$pending"
sgdisk --new=2:18432:20479 --typecode=2:8300 --change-name=2:TALOS_META_PENDING "$pending" >/dev/null
printf 'interrupted-data' | dd of="$pending" bs=1 seek=$((18432 * 512)) conv=notrunc status=none
"$helper" "$pending" 1 512 >/dev/null
[ "$(partition_name "$pending" 2)" = META ] || fail 'pending META was not committed'
pending_uuid="$(read_meta_uuid "$pending" 2)"
case "$pending_uuid" in
  ????????-????-????-????-????????????) ;;
  *) fail "recovered META UUIDOverride is invalid: $pending_uuid" ;;
esac

blocked="$work_dir/blocked.img"
new_image "$blocked"
sgdisk --new=2:18432:22527 --typecode=2:8300 --change-name=2:FOREIGN "$blocked" >/dev/null
if "$helper" "$blocked" 1 512 >/dev/null 2>&1; then
  fail 'helper accepted an occupied post-ESP extent'
fi
[ "$(partition_name "$blocked" 1)" = ASAHI_ESP ] || fail 'failure path modified the ESP label'
[ "$(partition_name "$blocked" 2)" = FOREIGN ] || fail 'failure path modified the foreign partition'

wrong_size="$work_dir/wrong-size.img"
new_image "$wrong_size"
sgdisk --new=2:18432:22527 --typecode=2:8300 --change-name=2:META "$wrong_size" >/dev/null
if "$helper" "$wrong_size" 1 512 >/dev/null 2>&1; then
  fail 'helper accepted a META partition with the wrong size'
fi

printf 'prepare GPT tests passed\n'
