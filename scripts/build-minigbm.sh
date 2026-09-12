#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
check_only=false
if [ "${1:-}" = --check-dependencies ]; then
	check_only=true
	shift
fi
src="${1:-$here/minigbm}"
pin=34003c9
patch="$here/patches/minigbm-vmwgfx.patch"

source "$here/scripts/dependencies.sh"
need "${CC:-cc}" build-essential; need git git; need make make
need nproc coreutils; need pkg-config pkg-config; need strings binutils
need tar tar; need gzip gzip
if [ ! -f /usr/include/libdrm/drm.h ] ||
	{ command -v pkg-config >/dev/null && ! pkg-config --exists libdrm; }; then
	missing+=(libdrm-dev)
fi
require_dependencies
bash "$here/scripts/check-patches.sh" "$patch"

if [ -d "$src" ] &&
	! git -C "$src" apply --reverse --check "$patch" >/dev/null 2>&1 &&
	! git -C "$src" apply --check "$patch" >/dev/null 2>&1; then
	echo "$patch does not apply cleanly to $src" >&2
	exit 1
fi
$check_only && exit 0

if [ ! -d "$src" ]; then
	git clone https://chromium.googlesource.com/chromiumos/platform/minigbm "$src"
	git -C "$src" checkout "$pin"
fi
if ! git -C "$src" apply --reverse --check "$patch" >/dev/null 2>&1; then
	git -C "$src" apply "$patch"
fi

make -C "$src" -j"$(nproc)" DRV_VMWGFX=1
lib="$src/libminigbm.so.1.0.0"
[ -s "$lib" ] || { echo "build produced no library"; exit 1; }
strings "$lib" | grep "vmwgfx minigbm inited" >/dev/null || { echo "vmwgfx backend missing from build"; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/usr/lib64"
install -m 0755 "$lib" "$tmp/usr/lib64/libminigbm.so.1.0.0"
out="$here/configs/packages/vm-minigbm.tar.gz"
mkdir -p "$(dirname "$out")"
tar zcf "$out" -C "$tmp" usr --owner=0 --group=0
echo "Wrote $out"
