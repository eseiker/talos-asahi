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

partition_last() {
  image="$1"
  number="$2"
  sgdisk --info="$number" "$image" | awk '/^Last sector:/ { print $3; exit }'
}

partition_number_by_name() {
  image="$1"
  wanted="$2"

  sgdisk --print "$image" | awk -v wanted="$wanted" \
    '$1 ~ /^[0-9]+$/ && $NF == wanted { print $1; exit }'
}

assert_standard_layout() {
  image="$1"

  [ "$(partition_name "$image" 1)" = EFI ] || fail 'ESP was not relabeled'
  [ "$(partition_name "$image" 2)" = META ] || fail 'META is not second in physical order'
  [ "$(partition_name "$image" 3)" = STATE ] || fail 'STATE is not third in physical order'
  [ "$(partition_name "$image" 4)" = RecoveryOSContainer ] || \
    fail 'RecoveryOS was not preserved after STATE'
  [ -z "$(partition_number_by_name "$image" EPHEMERAL)" ] || \
    fail 'prepare helper created EPHEMERAL'

  meta_first="$(partition_first "$image" 2)"
  meta_last="$(partition_last "$image" 2)"
  state_first="$(partition_first "$image" 3)"
  state_last="$(partition_last "$image" 3)"
  [ "$((meta_last - meta_first + 1))" -eq 2048 ] || fail 'META size is not 1 MiB'
  [ "$((state_last - state_first + 1))" -eq 204800 ] || fail 'STATE size is not 100 MiB'
  [ "$state_first" -gt "$meta_last" ] || fail 'STATE overlaps META'

  verify_output="$(sgdisk --verify "$image" 2>&1)"
  case "$verify_output" in
    *'Identified 0 problems!'*|*'No problems found.'*) ;;
    *) fail "resulting GPT did not verify: $verify_output" ;;
  esac
}

new_image() {
  image="$1"
  truncate -s 256M "$image"
  sgdisk --clear "$image" >/dev/null
  sgdisk --new=1:2048:18431 --typecode=1:ef00 --change-name=1:ASAHI_ESP "$image" >/dev/null
  sgdisk --new=4:491520:522239 --typecode=4:af0a --change-name=4:RecoveryOSContainer "$image" >/dev/null
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
assert_standard_layout "$standard"
standard_uuid="$(read_meta_uuid "$standard" 2)"
case "$standard_uuid" in
  ????????-????-????-????-????????????) ;;
  *) fail "META UUIDOverride is invalid: $standard_uuid" ;;
esac

meta_first="$(partition_first "$standard" 2)"
sentinel_offset=$((meta_first * 512 + 700 * 1024))
printf 'preserve-existing-meta' | dd of="$standard" bs=1 seek="$sentinel_offset" conv=notrunc status=none
state_first="$(partition_first "$standard" 3)"
state_sentinel_offset=$((state_first * 512 + 1024 * 1024))
printf 'preserve-existing-state' | dd of="$standard" bs=1 seek="$state_sentinel_offset" conv=notrunc status=none
"$helper" "$standard" 1 512 >/dev/null
assert_standard_layout "$standard"
preserved="$(dd if="$standard" bs=1 skip="$sentinel_offset" count=22 status=none)"
[ "$preserved" = preserve-existing-meta ] || fail 'idempotent run erased existing META contents'
preserved_state="$(dd if="$standard" bs=1 skip="$state_sentinel_offset" count=23 status=none)"
[ "$preserved_state" = preserve-existing-state ] || fail 'idempotent run erased existing STATE contents'
[ "$(read_meta_uuid "$standard" 2)" = "$standard_uuid" ] || \
  fail 'idempotent run changed UUIDOverride'

pending="$work_dir/pending.img"
new_image "$pending"
sgdisk --new=2:18432:20479 --typecode=2:8300 --change-name=2:TALOS_META_PENDING "$pending" >/dev/null
printf 'interrupted-data' | dd of="$pending" bs=1 seek=$((18432 * 512)) conv=notrunc status=none
"$helper" "$pending" 1 512 >/dev/null
assert_standard_layout "$pending"
pending_uuid="$(read_meta_uuid "$pending" 2)"
case "$pending_uuid" in
  ????????-????-????-????-????????????) ;;
  *) fail "recovered META UUIDOverride is invalid: $pending_uuid" ;;
esac

pending_state="$work_dir/pending-state.img"
new_image "$pending_state"
sgdisk --new=2:18432:20479 --typecode=2:8300 --change-name=2:META "$pending_state" >/dev/null
sgdisk --new=3:20480:225279 --typecode=3:8300 --change-name=3:TALOS_STATE_PENDING "$pending_state" >/dev/null
printf 'interrupted-state-data' | dd of="$pending_state" bs=1 seek=$((20480 * 512)) conv=notrunc status=none
"$helper" "$pending_state" 1 512 >/dev/null
assert_standard_layout "$pending_state"

unsorted="$work_dir/unsorted.img"
new_image "$unsorted"
sgdisk --new=7:18432:20479 --typecode=7:8300 --change-name=7:META "$unsorted" >/dev/null
"$helper" "$unsorted" 1 512 >/dev/null
assert_standard_layout "$unsorted"

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

wrong_state_size="$work_dir/wrong-state-size.img"
new_image "$wrong_state_size"
sgdisk --new=2:18432:20479 --typecode=2:8300 --change-name=2:META "$wrong_state_size" >/dev/null
sgdisk --new=3:20480:223231 --typecode=3:8300 --change-name=3:STATE "$wrong_state_size" >/dev/null
if "$helper" "$wrong_state_size" 1 512 >/dev/null 2>&1; then
  fail 'helper accepted a STATE partition with the wrong size'
fi

printf 'prepare GPT tests passed\n'
