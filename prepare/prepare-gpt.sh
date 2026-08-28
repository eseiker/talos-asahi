#!/bin/sh

set -eu

export LC_ALL=C
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

EFI_TYPE_GUID=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
LINUX_TYPE_GUID=0FC63DAF-8483-4772-8E79-3D69D8477DE4
META_BYTES=1048576
PENDING_LABEL=TALOS_META_PENDING
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

zero_partition_extent() {
  number="$1"
  first="$(partition_first "$number")"

  log "zero-filling pending META extent at sector $first"
  dd if=/dev/zero of="$disk" bs="$sector_size" seek="$first" \
    count="$meta_sectors" conv=notrunc,fsync status=none
  sync

  expected_hash="$(dd if=/dev/zero bs="$META_BYTES" count=1 status=none | sha256sum | awk '{ print $1 }')"
  actual_hash="$(dd if="$disk" bs="$sector_size" skip="$first" \
    count="$meta_sectors" status=none | sha256sum | awk '{ print $1 }')"
  [ "$actual_hash" = "$expected_hash" ] || fail 'META zero-fill verification failed'
}

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
  zero_partition_extent "$pending_number"

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
sgdisk --verify "$disk"

[ -x "$META_UUID_WRITER" ] || fail "META UUID writer is missing: $META_UUID_WRITER"
meta_first="$(partition_first "$meta_number")"
meta_offset=$((meta_first * sector_size))
if ! uuid_result="$($META_UUID_WRITER "$disk" "$meta_offset")"; then
  fail 'unable to initialize UUIDOverride in META'
fi
log "$uuid_result"

log "GPT and META preparation complete: ESP=$esp_number META=$meta_number"
