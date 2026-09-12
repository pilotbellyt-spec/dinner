#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
mode="${1:-all}"
kver="${KVER:-6.12}"
cd "$here/brunch"

if [ "$mode" = prepare ] || [ "$mode" = all ]; then
	sed "s/^kernels=\".*\"/kernels=\"$kver\"/" prepare_kernels.sh > ./prepare_kernels_vm.sh
	chmod +x ./prepare_kernels_vm.sh
	./prepare_kernels_vm.sh
	rm -f ./prepare_kernels_vm.sh
fi

if [ "$mode" = build ] || [ "$mode" = all ]; then
	[ -d "./kernels/$kver" ] || { echo "no prepared source at brunch/kernels/$kver - run 'prepare' first"; exit 1; }
	./build_kernels.sh "$kver"
	echo "Built the kernel"
fi

if [ "$mode" = package ] || [ "$mode" = all ]; then
	rel="$(cat "./kernels/$kver/out/include/config/kernel.release")"
	stage="$(mktemp -d)"
	trap 'rm -rf "$stage"' EXIT
	make -C "./kernels/$kver" O=out INSTALL_MOD_STRIP=1 \
		INSTALL_MOD_PATH="$stage" modules_install >/dev/null
	rm -f "$stage/lib/modules/$rel/build" "$stage/lib/modules/$rel/source"
	out="$here/configs/packages/kernel-$rel.tar.gz"
	mkdir -p "$(dirname "$out")"
	tar zcf "$out" -C "$stage" lib --owner=0 --group=0
	echo "Wrote $out"
fi
