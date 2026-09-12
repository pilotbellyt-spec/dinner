#!/usr/bin/env bash
set -euo pipefail

rammus_root="${1:?usage: build-recovery-drivers.sh RAMMUS_ROOT.img REVEN.bin OUTPUT_DIR}"
reven="${2:?Reven recovery image is required}"
output="$(realpath -m "${3:?output directory is required}")"
scripts="$(cd "$(dirname "$0")" && pwd)"

release="$(debugfs -R 'cat /etc/lsb-release' "$rammus_root" 2>/dev/null)"
grep -q '^CHROMEOS_RELEASE_BOARD=rammus\($\|-\)' <<<"$release" || {
	echo "--rammus must be a Rammus recovery image" >&2
	exit 1
}
start="$(cgpt show -i 3 -b "$reven")"
sectors="$(cgpt show -i 3 -s "$reven")"
[[ "$start" =~ ^[0-9]+$ && "$sectors" =~ ^[0-9]+$ ]] &&
	[ "$start" -gt 0 ] && [ "$sectors" -gt 0 ] || {
	echo "Reven recovery has no root partition" >&2
	exit 1
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
echo "Extracting Reven drivers"
dd if="$reven" of="$work/rootfs.img" bs=1M iflag=skip_bytes,count_bytes \
	skip=$((start * 512)) count=$((sectors * 512)) conv=sparse status=none
release="$(debugfs -R 'cat /etc/lsb-release' "$work/rootfs.img" 2>/dev/null)"
grep -q '^CHROMEOS_RELEASE_BOARD=reven\($\|-\)' <<<"$release" || {
	echo "--reven must be a Reven recovery image" >&2
	exit 1
}
mkdir -p "$output"
bash "$scripts/build-vm-mesa.sh" "$work/rootfs.img" "$output/vm-mesa.tar.gz"
