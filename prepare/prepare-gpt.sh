#!/bin/sh

set -eu

export LC_ALL=C
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

EFI_TYPE_GUID=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
LINUX_TYPE_GUID=0FC63DAF-8483-4772-8E79-3D69D8477DE4
META_BYTES=1048576
STATE_BYTES=104857600
PENDING_LABEL=TALOS_META_PENDING
STATE_PENDING_LABEL=TALOS_STATE_PENDING
META_UUID_WRITER=/usr/libexec/talos-asahi/meta-uuid

log() {
  printf '[talos-asahi-prepare] %s\n' "$*"
}

fail() {
  log "ERROR: $*" >&2
  exit 1
}

usage() {
  printf 'usage: %s DISK ESP_PARTITION_NUMBER [LOGICAL_SECTOR_SIZE]\n' "$0" >&2
  exit 2
}

[ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage

disk="$1"
esp_number="$2"
sector_size="${3:-}"

[ -r "$disk" ] && [ -w "$disk" ] || fail "disk is not readable and writable: $disk"
case "$esp_number" in
  ''|*[!0-9]*) fail "invalid ESP partition number: $esp_number" ;;
esac

if [ -z "$sector_size" ]; then
  disk_name="$(basename "$disk")"
  sector_size_path="/sys/class/block/$disk_name/queue/logical_block_size"
  if [ -r "$sector_size_path" ]; then
    sector_size="$(cat "$sector_size_path")"
  elif command -v blockdev >/dev/null 2>&1; then
    sector_size="$(blockdev --getss "$disk")"
  else
    fail 'logical sector size was not supplied and cannot be detected'
  fi
fi
case "$sector_size" in
  ''|*[!0-9]*) fail "invalid logical sector size: $sector_size" ;;
esac
[ "$sector_size" -gt 0 ] || fail "logical sector size must be positive"
[ $((META_BYTES % sector_size)) -eq 0 ] || \
  fail "1 MiB is not divisible by logical sector size $sector_size"

meta_sectors=$((META_BYTES / sector_size))
state_sectors=$((STATE_BYTES / sector_size))

partition_numbers() {
  sgdisk --print "$disk" | awk '$1 ~ /^[0-9]+$/ { print $1 }'
}

partition_info() {
  sgdisk --info="$1" "$disk"
}

partition_first() {
  partition_info "$1" | awk '/^First sector:/ { print $3; exit }'
}

partition_last() {
  partition_info "$1" | awk '/^Last sector:/ { print $3; exit }'
}

partition_name() {
  partition_info "$1" | sed -n "s/^Partition name: '\(.*\)'$/\1/p"
}

partition_type() {
  partition_info "$1" | awk '/^Partition GUID code:/ { print toupper($4); exit }'
}

find_partition_by_name() {
  wanted="$1"
  found=''

  for number in $(partition_numbers); do
    if [ "$(partition_name "$number")" = "$wanted" ]; then
      [ -z "$found" ] || fail "multiple partitions are named $wanted"
      found="$number"
    fi
  done

  printf '%s\n' "$found"
}

nearest_partition_after() {
  boundary="$1"
  nearest_number=''
  nearest_start=''

  for number in $(partition_numbers); do
    start="$(partition_first "$number")"
    if [ "$start" -gt "$boundary" ]; then
      if [ -z "$nearest_start" ] || [ "$start" -lt "$nearest_start" ]; then
        nearest_number="$number"
        nearest_start="$start"
      fi
    fi
  done

  printf '%s:%s\n' "$nearest_number" "$nearest_start"
}

first_unused_number() {
  used=" $(partition_numbers | tr '\n' ' ') "
  number=1

  while [ "$number" -le 128 ]; do
    case "$used" in
      *" $number "*) ;;
      *) printf '%s\n' "$number"; return 0 ;;
    esac
    number=$((number + 1))
  done

  fail 'GPT has no unused partition entries'
}

verify_gpt_integrity() {
  verify_output="$(sgdisk --verify "$disk" 2>&1)" || \
    fail "unable to verify GPT: $verify_output"

  case "$verify_output" in
    *'Identified 0 problems!'*|*'No problems found.'*) ;;
    *) fail "GPT verification failed: $verify_output" ;;
  esac
}

sort_partition_table() {
  log 'sorting GPT entries into physical LBA order'
  sgdisk --sort "$disk"
  sync
}

verify_partition_order() {
  previous_last=''

  for number in $(partition_numbers); do
    first="$(partition_first "$number")"
    last="$(partition_last "$number")"

    if [ -n "$previous_last" ] && [ "$first" -le "$previous_last" ]; then
      fail "GPT partition $number is overlapping or out of physical order"
    fi

    previous_last="$last"
  done
}

verify_meta_geometry() {
  number="$1"
  first="$(partition_first "$number")"
  last="$(partition_last "$number")"
  size=$((last - first + 1))

  [ "$size" -eq "$meta_sectors" ] || \
    fail "partition $number is not exactly 1 MiB"
  [ "$first" -gt "$esp_last" ] || \
    fail "partition $number is not physically after the Asahi ESP"

  nearest="$(nearest_partition_after "$esp_last")"
  nearest_number="${nearest%%:*}"
  [ "$nearest_number" = "$number" ] || \
    fail "partition $number is not the first partition after the Asahi ESP"
}

verify_state_geometry() {
  number="$1"
  first="$(partition_first "$number")"
  last="$(partition_last "$number")"
  size=$((last - first + 1))

  [ "$size" -eq "$state_sectors" ] || \
    fail "partition $number is not exactly 100 MiB"
  [ "$first" -gt "$meta_last" ] || \
    fail "partition $number is not physically after META"

  nearest="$(nearest_partition_after "$meta_last")"
  nearest_number="${nearest%%:*}"
  [ "$nearest_number" = "$number" ] || \
    fail "partition $number is not the first partition after META"
}

zero_partition_extent() {
  number="$1"
  byte_count="$2"
  description="$3"
  first="$(partition_first "$number")"
  sectors=$((byte_count / sector_size))

  log "zero-filling pending $description extent at sector $first"
  dd if=/dev/zero of="$disk" bs="$sector_size" seek="$first" \
    count="$sectors" conv=notrunc,fsync status=none
  sync

  expected_hash="$(dd if=/dev/zero bs="$sector_size" count="$sectors" status=none | sha256sum | awk '{ print $1 }')"
  actual_hash="$(dd if="$disk" bs="$sector_size" skip="$first" \
    count="$sectors" status=none | sha256sum | awk '{ print $1 }')"
  [ "$actual_hash" = "$expected_hash" ] || \
    fail "$description zero-fill verification failed"
}

verify_gpt_integrity

esp_type="$(partition_type "$esp_number")"
[ "$esp_type" = "$EFI_TYPE_GUID" ] || \
  fail "partition $esp_number is not an EFI System Partition (type $esp_type)"
esp_last="$(partition_last "$esp_number")"

meta_number="$(find_partition_by_name META)"
pending_number="$(find_partition_by_name "$PENDING_LABEL")"
[ -z "$meta_number" ] || [ -z "$pending_number" ] || \
  fail "both META and $PENDING_LABEL partitions exist"

if [ -n "$meta_number" ]; then
  log "existing META partition $meta_number found; preserving its contents"
  verify_meta_geometry "$meta_number"
  [ "$(partition_type "$meta_number")" = "$LINUX_TYPE_GUID" ] || \
    fail "existing META partition $meta_number has the wrong GPT type"
else
  if [ -z "$pending_number" ]; then
    alignment_sectors="$meta_sectors"
    meta_start=$(( (esp_last + 1 + alignment_sectors - 1) / alignment_sectors * alignment_sectors ))
    meta_end=$((meta_start + meta_sectors - 1))

    nearest="$(nearest_partition_after "$esp_last")"
    next_start="${nearest#*:}"
    if [ -n "$next_start" ]; then
      [ "$meta_end" -lt "$next_start" ] || \
        fail 'there is no free aligned 1 MiB extent immediately after the Asahi ESP'
    else
      last_usable="$(sgdisk --print "$disk" | \
        sed -n 's/.*last usable sector is \([0-9][0-9]*\).*/\1/p')"
      [ -n "$last_usable" ] || fail 'unable to determine the final usable GPT sector'
      [ "$meta_end" -le "$last_usable" ] || \
        fail 'there is no free aligned 1 MiB extent after the Asahi ESP'
    fi

    pending_number="$(first_unused_number)"
    log "creating partition $pending_number as $PENDING_LABEL"
    sgdisk \
      --new="${pending_number}:${meta_start}:${meta_end}" \
      --typecode="${pending_number}:${LINUX_TYPE_GUID}" \
      --change-name="${pending_number}:${PENDING_LABEL}" \
      "$disk"
    sync
  else
    log "recovering interrupted preparation from partition $pending_number"
  fi

  verify_meta_geometry "$pending_number"
  [ "$(partition_type "$pending_number")" = "$LINUX_TYPE_GUID" ] || \
    fail "pending META partition $pending_number has the wrong GPT type"
  zero_partition_extent "$pending_number" "$META_BYTES" META

  log 'committing GPT labels EFI and META'
  sgdisk \
    --change-name="${esp_number}:EFI" \
    --change-name="${pending_number}:META" \
    "$disk"
  sync
  meta_number="$pending_number"
fi

if [ "$(partition_name "$esp_number")" != EFI ]; then
  log 'setting the Asahi ESP GPT label to EFI'
  sgdisk --change-name="${esp_number}:EFI" "$disk"
  sync
fi

[ "$(partition_name "$esp_number")" = EFI ] || fail 'ESP GPT label verification failed'
[ "$(partition_name "$meta_number")" = META ] || fail 'META GPT label verification failed'
verify_meta_geometry "$meta_number"
[ "$(partition_type "$meta_number")" = "$LINUX_TYPE_GUID" ] || \
  fail 'META GPT type verification failed'

# Talos' live GPT allocator expects GPT entry order to match physical LBA
# order. META can otherwise sit before RecoveryOS while using a later GPT
# entry, causing subsequent STATE or EPHEMERAL allocations to overlap it.
sort_partition_table
esp_number="$(find_partition_by_name EFI)"
meta_number="$(find_partition_by_name META)"
[ -n "$esp_number" ] || fail 'EFI partition disappeared after GPT sort'
[ -n "$meta_number" ] || fail 'META partition disappeared after GPT sort'
esp_last="$(partition_last "$esp_number")"
meta_last="$(partition_last "$meta_number")"
verify_meta_geometry "$meta_number"

state_number="$(find_partition_by_name STATE)"
pending_state_number="$(find_partition_by_name "$STATE_PENDING_LABEL")"
[ -z "$state_number" ] || [ -z "$pending_state_number" ] || \
  fail "both STATE and $STATE_PENDING_LABEL partitions exist"

if [ -n "$state_number" ]; then
  log "existing STATE partition $state_number found; preserving its contents"
  verify_state_geometry "$state_number"
  [ "$(partition_type "$state_number")" = "$LINUX_TYPE_GUID" ] || \
    fail "existing STATE partition $state_number has the wrong GPT type"
else
  if [ -z "$pending_state_number" ]; then
    alignment_sectors="$meta_sectors"
    state_start=$(( (meta_last + 1 + alignment_sectors - 1) / alignment_sectors * alignment_sectors ))
    state_end=$((state_start + state_sectors - 1))

    nearest="$(nearest_partition_after "$meta_last")"
    next_start="${nearest#*:}"
    if [ -n "$next_start" ]; then
      [ "$state_end" -lt "$next_start" ] || \
        fail 'there is no free aligned 100 MiB extent immediately after META'
    else
      last_usable="$(sgdisk --print "$disk" | \
        sed -n 's/.*last usable sector is \([0-9][0-9]*\).*/\1/p')"
      [ -n "$last_usable" ] || fail 'unable to determine the final usable GPT sector'
      [ "$state_end" -le "$last_usable" ] || \
        fail 'there is no free aligned 100 MiB extent after META'
    fi

    pending_state_number="$(first_unused_number)"
    log "creating partition $pending_state_number as $STATE_PENDING_LABEL"
    sgdisk \
      --new="${pending_state_number}:${state_start}:${state_end}" \
      --typecode="${pending_state_number}:${LINUX_TYPE_GUID}" \
      --change-name="${pending_state_number}:${STATE_PENDING_LABEL}" \
      "$disk"
    sync
  else
    log "recovering interrupted preparation from partition $pending_state_number"
  fi

  verify_state_geometry "$pending_state_number"
  [ "$(partition_type "$pending_state_number")" = "$LINUX_TYPE_GUID" ] || \
    fail "pending STATE partition $pending_state_number has the wrong GPT type"
  zero_partition_extent "$pending_state_number" "$STATE_BYTES" STATE

  log 'committing GPT label STATE'
  sgdisk --change-name="${pending_state_number}:STATE" "$disk"
  sync
fi

sort_partition_table
esp_number="$(find_partition_by_name EFI)"
meta_number="$(find_partition_by_name META)"
state_number="$(find_partition_by_name STATE)"
[ -n "$esp_number" ] || fail 'EFI partition disappeared after final GPT sort'
[ -n "$meta_number" ] || fail 'META partition disappeared after final GPT sort'
[ -n "$state_number" ] || fail 'STATE partition disappeared after final GPT sort'
esp_last="$(partition_last "$esp_number")"
meta_last="$(partition_last "$meta_number")"
verify_meta_geometry "$meta_number"
verify_state_geometry "$state_number"
[ "$(partition_type "$state_number")" = "$LINUX_TYPE_GUID" ] || \
  fail 'STATE GPT type verification failed'
verify_partition_order
verify_gpt_integrity

[ -x "$META_UUID_WRITER" ] || fail "META UUID writer is missing: $META_UUID_WRITER"
meta_first="$(partition_first "$meta_number")"
meta_offset=$((meta_first * sector_size))
if ! uuid_result="$($META_UUID_WRITER "$disk" "$meta_offset")"; then
  fail 'unable to initialize UUIDOverride in META'
fi
log "$uuid_result"

log "GPT preparation complete: ESP=$esp_number META=$meta_number STATE=$state_number"
