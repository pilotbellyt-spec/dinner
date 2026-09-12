#!/usr/bin/env bash
set -euo pipefail
export PATH="$PATH:/usr/sbin:/sbin"

while [ $# -gt 0 ]; do
	case "$1" in
		--image) shift; image="$1";;
		--size) shift; size="$1";;
		*) echo "unknown arg $1"; exit 1;;
	esac
	shift
done
: "${image:?--image required}" "${size:?--size required (e.g. 64G)}"
command -v cgpt >/dev/null || { echo "cgpt required"; exit 1; }
command -v sgdisk >/dev/null || { echo "sgdisk (gdisk) required"; exit 1; }

old_bytes=$(stat -c%s "$image")
truncate -s "$size" "$image"
new_bytes=$(stat -c%s "$image")
[ "$new_bytes" -gt "$old_bytes" ] || { echo "new size must be larger than current"; exit 1; }
echo "Resized $image"

# Move the backup GPT to the new end of device, then extend STATE (p1).
sgdisk -e "$image" >/dev/null
start=$(cgpt show -i 1 -b "$image")
total_sectors=$(( new_bytes / 512 ))
new_size=$(( total_sectors - start - 48 ))
cgpt add -i 1 -b "$start" -s "$new_size" -t data -l STATE "$image"
cgpt repair "$image" >/dev/null 2>&1 || true
cgpt show -i 1 "$image"
echo "Expanded the data partition. Enable vm_resize to grow the filesystem on the next boot."
