#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<EOF
Usage: $0 --target qemu|vmware --rammus RAMMUS.bin --reven REVEN.bin --output IMAGE.img [--size GB]

Builds a ChromeOS VM image.
The default size is 32 GB.
EOF
	exit "${1:-1}"
}

target=
recovery=
reven=
output=
size=32
while [ $# -gt 0 ]; do
	case "$1" in
		--target) shift; target="${1:-}";;
		--rammus) shift; recovery="${1:-}";;
		--reven) shift; reven="${1:-}";;
		--output) shift; output="${1:-}";;
		--size) shift; size="${1:-}";;
		-h|--help) usage 0;;
		*) echo "unknown argument: $1"; usage;;
	esac
	shift
done

case "$target" in
	qemu|vmware) ;;
	*) echo "--target must be qemu or vmware"; usage;;
esac
[ -n "$recovery" ] || { echo "--rammus is required"; usage; }
[ -n "$reven" ] || { echo "--reven is required"; usage; }
[ -n "$output" ] || { echo "--output is required"; usage; }
[[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -ge 14 ] || {
	echo "--size must be an integer of at least 14"
	exit 1
}

for command in podman debugfs realpath; do
	command -v "$command" >/dev/null || { echo "$command is required"; exit 1; }
done

repo="$(cd "$(dirname "$0")/.." && pwd)"
recovery="$(realpath "$recovery")"
reven="$(realpath "$reven")"
output="$(realpath -m "$output")"
[ -f "$recovery" ] || { echo "recovery image not found: $recovery"; exit 1; }
[ -f "$reven" ] || { echo "recovery image not found: $reven"; exit 1; }
[ ! "$recovery" -ef "$reven" ] || { echo "supply separate Rammus and Reven images"; exit 1; }
if [ "$recovery" -ef "$output" ] || [ "$reven" -ef "$output" ]; then
	echo "--output cannot overwrite a recovery image"
	exit 1
fi
[[ "$output" = *.img ]] || { echo "--output must end in .img"; exit 1; }

baseline="$repo/baseline/r151"
brunch="$repo/brunch"
kernel="$brunch/kernels/6.12/out/arch/x86/boot/bzImage"
kernel_release_file="$brunch/kernels/6.12/out/include/config/kernel.release"
if [ ! -f "$baseline/chromeos-install.sh" ] || [ ! -f "$baseline/rootc.img" ]; then
	command -v wget >/dev/null || {
		echo "ERROR: The following dependencies are not installed: wget" >&2
		exit 1
	}
	mkdir -p "$baseline"
	wget -qO- \
		"https://github.com/sebanc/brunch/releases/download/r151-stable-20260823/brunch_r151_stable_20260823.tar.gz" |
		tar -xz -C "$baseline"
fi
[ -f "$kernel" ] && [ -f "$kernel_release_file" ] || {
	echo "build the VM kernel with scripts/build-vm-kernel.sh all"
	exit 1
}

kernel_release="$(cat "$kernel_release_file")"
if [ ! -f "$repo/configs/packages/vm-vulkan.tar.gz" ]; then
	bash "$repo/scripts/build-vm-vulkan.sh"
fi
if [ ! -f "$repo/configs/packages/kernel-$kernel_release.tar.gz" ]; then
	bash "$repo/scripts/build-vm-kernel.sh" package
fi
packages=(
	"$repo/configs/packages/kernel-$kernel_release.tar.gz"
	"$repo/configs/packages/vm-vulkan.tar.gz"
)
settings="$repo/configs/settings-qemu.cfg"
if [ "$target" = vmware ]; then
	if [ ! -f "$repo/configs/packages/vm-minigbm.tar.gz" ]; then
		bash "$repo/scripts/build-minigbm.sh"
	fi
	if [ ! -f "$repo/configs/packages/vm-tools.tar.gz" ]; then
		bash "$repo/scripts/build-vm-tools.sh"
	fi
	packages+=(
		"$repo/configs/packages/vm-minigbm.tar.gz"
		"$repo/configs/packages/vm-tools.tar.gz"
	)
	settings="$repo/configs/settings-vmware.cfg"
fi
for package in "${packages[@]}"; do
	[ -f "$package" ] || { echo "required package not found: $package"; exit 1; }
done
[ -f "$settings" ] || { echo "settings file not found: $settings"; exit 1; }

output_dir="$(dirname "$output")"
mkdir -p "$output_dir"
work="$(mktemp -d -p "$output_dir" .crosvm-image.XXXXXX)"
trap 'rm -rf "$work"' EXIT
framework="$work/framework"
mkdir -p "$framework"
for file in chromeos-install.sh efi_legacy.img efi_secure.img rootc.img; do
	cp --reflink=auto --sparse=auto "$baseline/$file" "$framework/$file"
done

echo "Preparing Brunch"
for patch in "$brunch"/brunch-patches/*.sh; do
	name="$(basename "$patch")"
	debugfs -w -R "rm /patches/$name" "$framework/rootc.img" >/dev/null 2>&1 || true
	debugfs -w -R "write $patch /patches/$name" "$framework/rootc.img" >/dev/null 2>&1
	debugfs -w -R "sif /patches/$name mode 0100755" "$framework/rootc.img" >/dev/null 2>&1
done
for package in "${packages[@]}"; do
	name="$(basename "$package")"
	debugfs -w -R "rm /packages/$name" "$framework/rootc.img" >/dev/null 2>&1 || true
	debugfs -w -R "write $package /packages/$name" "$framework/rootc.img" >/dev/null 2>&1
done

kernel_target="$(debugfs -R 'stat /kernel' "$framework/rootc.img" 2>/dev/null |
	sed -n 's/.*Fast link dest: "\(.*\)".*/\1/p')"
[ -n "$kernel_target" ] || { echo "could not resolve /kernel in rootc.img"; exit 1; }
debugfs -w -R "rm /$kernel_target" "$framework/rootc.img" >/dev/null 2>&1 || true
debugfs -w -R "write $kernel /$kernel_target" "$framework/rootc.img" >/dev/null 2>&1
debugfs -w -R "sif /$kernel_target mode 0100644" "$framework/rootc.img" >/dev/null 2>&1
cp --reflink=auto --sparse=auto "$recovery" "$work/recovery.bin"
cp "$settings" "$work/settings.cfg"

builder=localhost/crosvm-image-builder:r151
podman build --quiet --tag "$builder" \
	--file "$repo/containers/Containerfile.image-builder" "$repo/containers" >/dev/null

output_name="$(basename "$output")"
echo "Building the $target image"
podman run --rm --privileged --security-opt label=disable \
	--entrypoint /bin/bash \
	-e CROSVM_OUTPUT="$output_name" -e CROSVM_SIZE="$size" -e CROSVM_TARGET="$target" \
	-v "$repo:/repo:ro" -v "$reven:/reven.bin:ro" -v "$work:/work" -v "$output_dir:/output" \
	"$builder" -euo pipefail -c '
		/repo/scripts/patch-arcvm-image.sh --image /work/recovery.bin --work /work/arcvm
		bash /repo/scripts/build-recovery-drivers.sh /work/arcvm/rootfs.img /reven.bin /work/packages
		debugfs -w -R "rm /packages/vm-mesa.tar.gz" /work/framework/rootc.img >/dev/null 2>&1 || true
		debugfs -w -R "write /work/packages/vm-mesa.tar.gz /packages/vm-mesa.tar.gz" /work/framework/rootc.img
		debugfs -R "dump /packages/vm-mesa.tar.gz /work/vm-mesa-check.tar.gz" /work/framework/rootc.img
		cmp /work/packages/vm-mesa.tar.gz /work/vm-mesa-check.tar.gz
		bash /repo/scripts/build-crosvm-policies.sh /work/arcvm/rootfs.img /work/vm-crosvm.tar.gz
		debugfs -w -R "rm /packages/vm-crosvm.tar.gz" /work/framework/rootc.img >/dev/null 2>&1 || true
		debugfs -w -R "write /work/vm-crosvm.tar.gz /packages/vm-crosvm.tar.gz" /work/framework/rootc.img
		debugfs -R "dump /packages/vm-crosvm.tar.gz /work/vm-crosvm-check.tar.gz" /work/framework/rootc.img
		cmp /work/vm-crosvm.tar.gz /work/vm-crosvm-check.tar.gz
		rm -f "/output/$CROSVM_OUTPUT"
		unshare -m bash -c "umount /proc; exec /work/framework/chromeos-install.sh \
			-src /work/recovery.bin -dst /output/$CROSVM_OUTPUT -s $CROSVM_SIZE -l"
		source_start=$(cgpt show -i 8 -b /work/recovery.bin)
		target_start=$(cgpt show -i 8 -b "/output/$CROSVM_OUTPUT")
		oem_sectors=$(cgpt show -i 8 -s /work/recovery.bin)
		dd if=/work/recovery.bin of="/output/$CROSVM_OUTPUT" bs=1M \
			iflag=skip_bytes,count_bytes oflag=seek_bytes conv=notrunc \
			skip=$((source_start * 512)) seek=$((target_start * 512)) \
			count=$((oem_sectors * 512)) status=none
		efi_offset=$(( $(cgpt show -i 12 -b "/output/$CROSVM_OUTPUT") * 512 ))
		mcopy -o -i "/output/$CROSVM_OUTPUT@@$efi_offset" \
			/work/settings.cfg ::efi/boot/settings.cfg
		if [ "$CROSVM_TARGET" = vmware ]; then
			/repo/scripts/convert-image.sh "/output/$CROSVM_OUTPUT" \
				"/output/${CROSVM_OUTPUT%.img}"
		fi
	'

echo "Built $output"
if [ "$target" = vmware ]; then
	echo "Built ${output%.img}.vmdk"
	echo "Built ${output%.img}.vmx"
fi
