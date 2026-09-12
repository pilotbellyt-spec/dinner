#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
src="${1:-$here/minigbm}"
pin=34003c9

if [ ! -d "$src" ]; then
	git clone https://chromium.googlesource.com/chromiumos/platform/minigbm "$src"
	git -C "$src" checkout "$pin"
	git -C "$src" apply "$here/patches/minigbm-vmwgfx.patch"
fi

make -C "$src" -j"$(nproc)" DRV_VMWGFX=1
lib="$src/libminigbm.so.1.0.0"
[ -s "$lib" ] || { echo "build produced no library"; exit 1; }
strings "$lib" | grep -q "vmwgfx minigbm inited" || { echo "vmwgfx backend missing from build"; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/usr/lib64"
install -m 0755 "$lib" "$tmp/usr/lib64/libminigbm.so.1.0.0"
out="$here/configs/packages/vm-minigbm.tar.gz"
mkdir -p "$(dirname "$out")"
tar zcf "$out" -C "$tmp" usr --owner=0 --group=0
echo "Wrote $out"
