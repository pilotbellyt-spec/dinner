#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
image="$here/images/chromeos.img"
disk=virtio
gpu=virtio
display=none
ram=8G
cpus=6
timeout=0
detach=0
xres=1920
yres=1080
extra=()

while [ $# -gt 0 ]; do
	case "$1" in
		--image) shift; image="$1";;
		--disk) shift; disk="$1";;
		--gpu) shift; gpu="$1";;
		--display) shift; display="$1";;
		--ram) shift; ram="$1";;
		--cpus) shift; cpus="$1";;
		--timeout) shift; timeout="$1";;
		--detach) detach=1;;
		--res) shift; xres="${1%x*}"; yres="${1#*x}";;
		--) shift; extra+=("$@"); break;;
		*) echo "unknown arg $1"; exit 1;;
	esac
	shift
done
[ -f "$image" ] || { echo "image not found: $image"; exit 1; }

run_dir="$here/runs/$(date +%Y%m%d-%H%M%S)-$disk-$gpu"
mkdir -p "$run_dir"

ovmf_code=/usr/share/edk2/ovmf/OVMF_CODE.fd
ovmf_vars_tpl=/usr/share/edk2/ovmf/OVMF_VARS.fd
[ -f "$ovmf_code" ] || { echo "OVMF not found: $ovmf_code"; exit 1; }
cp "$ovmf_vars_tpl" "$run_dir/OVMF_VARS.fd"

cmd=(qemu-system-x86_64
	-name crosvm
	-machine "q35,accel=kvm"
	-cpu host
	-smp "$cpus" -m "$ram"
	-drive "if=pflash,format=raw,readonly=on,file=$ovmf_code"
	-drive "if=pflash,format=raw,file=$run_dir/OVMF_VARS.fd"
	-drive "id=d0,if=none,format=raw,cache=unsafe,file=$image"
	-device qemu-xhci -device usb-tablet -device usb-kbd -device usb-mouse
	-netdev "user,id=n0" -device "virtio-net-pci,netdev=n0"
	-device virtio-rng-pci
	-serial "file:$run_dir/serial.log"
	-rtc base=utc
)

case "$disk" in
	virtio) cmd+=(-device "virtio-blk-pci,drive=d0");;
	ahci)   cmd+=(-device "ide-hd,drive=d0");;
	nvme)   cmd+=(-device "nvme,drive=d0,serial=crosvm01");;
	scsi)   cmd+=(-device "virtio-scsi-pci,id=scsi0" -device "scsi-hd,drive=d0,bus=scsi0.0");;
	*) echo "bad --disk"; exit 1;;
esac

case "$gpu" in
	virtio) cmd+=(-device "virtio-vga,xres=${xres},yres=${yres}");;
	virgl)  cmd+=(-device "virtio-vga-gl,xres=${xres},yres=${yres}"); [ "$display" = none ] && display=gtk;;
	std)    cmd+=(-device VGA);;
	qxl)    cmd+=(-device qxl-vga);;
	none)   ;;
	*) echo "bad --gpu"; exit 1;;
esac

case "$display" in
	none) cmd+=(-display none);;
	gtk)  if [ "$gpu" = virgl ]; then cmd+=(-display "gtk,gl=on,show-cursor=on"); else cmd+=(-display "gtk,show-cursor=on"); fi;;
	sdl)  export SDL_VIDEODRIVER=x11
	      if [ "$gpu" = virgl ]; then cmd+=(-display "sdl,gl=on,show-cursor=on"); else cmd+=(-display "sdl,show-cursor=on"); fi;;
	*) echo "bad --display"; exit 1;;
esac

# Select NVIDIA's EGL and GBM libraries when virgl uses an NVIDIA host GPU.
if [ "$gpu" = virgl ] && [ -f /usr/share/glvnd/egl_vendor.d/10_nvidia.json ]; then
	export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/10_nvidia.json
	export __EGL_EXTERNAL_PLATFORM_CONFIG_DIRS=/usr/share/egl/egl_external_platform.d
	export GBM_BACKENDS_PATH=/usr/lib64/gbm
fi

cmd+=(-audiodev "pipewire,id=audio0" -device ich9-intel-hda -device "hda-duplex,audiodev=audio0")

cmd+=("${extra[@]}")

echo "run dir: $run_dir"
if [ "$detach" = 1 ]; then
	setsid nohup "${cmd[@]}" > "$run_dir/qemu-stdout.log" 2>&1 &
	echo "$!" > "$run_dir/qemu.pid"
	echo "QEMU started. Stop with: kill \$(cat $run_dir/qemu.pid)"
elif [ "$timeout" -gt 0 ]; then
	timeout --foreground "$timeout" "${cmd[@]}" || true
	echo "QEMU exited. Logs in $run_dir"
else
	"${cmd[@]}"
	echo "QEMU exited. Logs in $run_dir"
fi
