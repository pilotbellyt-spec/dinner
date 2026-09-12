#!/usr/bin/env bash
set -euo pipefail

usage() {
	echo "usage: $0 --image RECOVERY.bin [--partition 3] [--work DIR]"
	exit 1
}

partition=3
while [ $# -gt 0 ]; do
	case "$1" in
		--image) shift; image="$1";;
		--partition) shift; partition="$1";;
		--work) shift; work="$1";;
		*) usage;;
	esac
	shift
done

: "${image:?--image is required}"
if [ -z "${work:-}" ]; then
	work="$(mktemp -d)"
	trap 'rm -rf "$work"' EXIT
fi
mkdir -p "$work"
rootfs="$work/rootfs.img"
system="$work/system.raw.img"
system_check="$work/system-check.raw.img"
patcher="$work/patch-erofs-property"
system_path=/opt/google/vms/android/system.raw.img
property_path=/system/build.prop
rm -f "$system" "$system_check" "$patcher"

for command in cgpt debugfs dump.erofs fsck.erofs cc; do
	command -v "$command" >/dev/null || { echo "$command is required"; exit 1; }
done

start="$(cgpt show -i "$partition" -b "$image")"
sectors="$(cgpt show -i "$partition" -s "$image")"
[ "$start" -gt 0 ] && [ "$sectors" -gt 0 ] || {
	echo "partition $partition is missing from $image"
	exit 1
}

echo "Extracting the recovery image"
dd if="$image" of="$rootfs" bs=1M iflag=skip_bytes,count_bytes conv=sparse \
	skip=$((start * 512)) count=$((sectors * 512)) status=none
debugfs -R "dump -p $system_path $system" "$rootfs" >/dev/null 2>&1
[ -s "$system" ] || { echo "$system_path is missing"; exit 1; }

extent="$(dump.erofs -e --path="$property_path" "$system")"
file_size="$(printf '%s\n' "$extent" | sed -n 's/^Size: *\([0-9][0-9]*\).*/\1/p')"
extent_count="$(printf '%s\n' "$extent" | sed -n 's/^.*\([0-9][0-9]*\) extents found$/\1/p')"
read -r erofs_offset cluster_size < <(
	printf '%s\n' "$extent" |
		sed -n 's/.*: *\([0-9][0-9]*\)\.\. *[0-9][0-9]* | *\([0-9][0-9]*\)$/\1 \2/p'
)
[ "$extent_count" = 1 ] && [ -n "$file_size" ] &&
	[ -n "$erofs_offset" ] && [ -n "$cluster_size" ] || {
	echo "$property_path does not have the expected single compressed extent"
	exit 1
}

cc -O2 -Wall -Wextra -Werror -o "$patcher" \
	"$(dirname "$0")/../tools/patch-erofs-property.c" -Wl,-l:liblz4.so.1
"$patcher" "$system" "$erofs_offset" "$cluster_size" "$file_size" \
	'ro.hwui.use_vulkan=true' 'ro.hwui.use_vulkan=0   '
fsck.erofs "$system" >/dev/null
dump.erofs --cat --path="$property_path" "$system" |
	grep '^ro.hwui.use_vulkan=0   $' >/dev/null

block_size="$(debugfs -R stats "$rootfs" 2>/dev/null |
	sed -n 's/^Block size: *//p')"
[ $((erofs_offset % block_size)) -eq 0 ] &&
	[ $((cluster_size % block_size)) -eq 0 ] || {
	echo "the EROFS extent is not aligned to the ROOT-A block size"
	exit 1
}

first_block=$((erofs_offset / block_size))
block_count=$((cluster_size / block_size))
for ((i = 0; i < block_count; i++)); do
	physical_block="$(debugfs -R "bmap $system_path $((first_block + i))" \
		"$rootfs" 2>/dev/null)"
	[[ "$physical_block" =~ ^[0-9]+$ ]] || {
		echo "could not map $system_path block $((first_block + i))"
		exit 1
	}
	dd if="$system" of="$rootfs" bs="$block_size" \
		skip=$((first_block + i)) seek="$physical_block" count=1 \
		conv=notrunc status=none
done

debugfs -R "dump -p $system_path $system_check" "$rootfs" >/dev/null 2>&1
fsck.erofs "$system_check" >/dev/null
dump.erofs --cat --path="$property_path" "$system_check" |
	grep '^ro.hwui.use_vulkan=0   $' >/dev/null

echo "Writing the patched image"
dd if="$rootfs" of="$image" bs=1M iflag=count_bytes oflag=seek_bytes \
	count=$((sectors * 512)) seek=$((start * 512)) conv=notrunc,sparse status=none
echo "Patched $image"
