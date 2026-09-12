#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
check_only=false
if [ "${1:-}" = --check-dependencies ]; then
	check_only=true
	shift
fi
mode="${1:-all}"
kver="${KVER:-6.12}"
case "$mode" in
	prepare|build|package|all) ;;
	*) echo "usage: $0 [--check-dependencies] [prepare|build|package|all]" >&2; exit 1;;
esac

source "$here/scripts/dependencies.sh"
need make make
need tar tar
case "$mode" in
	prepare)
		need "${CC:-cc}" build-essential; need curl curl; need git git
		need patch patch; need gzip gzip; need flex flex; need bison bison; need find findutils
		;;
	build)
		need "${CC:-cc}" build-essential; need bc bc; need perl perl
		need python3 python3; need ld binutils
		need find findutils
		;;
	package)
		need strip binutils; need gzip gzip; need depmod kmod
		;;
	all)
		need "${CC:-cc}" build-essential; need curl curl; need git git
		need patch patch; need gzip gzip; need flex flex; need bison bison
		need find findutils; need bc bc; need perl perl; need python3 python3
		need ld binutils; need depmod kmod
		;;
esac
build_config="$here/brunch/kernels/$kver/out/.config"
if [ "$mode" = all ]; then
	build_config="$here/brunch/kernel-patches/flex_configs"
fi
if [ "$mode" = build ] || [ "$mode" = all ]; then
	if grep -q '^CONFIG_OBJTOOL=y' "$build_config" 2>/dev/null; then
		[ -f /usr/include/libelf.h ] || missing+=(libelf-dev)
	fi
	if grep -q '^CONFIG_SYSTEM_TRUSTED_KEYRING=y' "$build_config" 2>/dev/null; then
		[ -f /usr/include/openssl/ssl.h ] || missing+=(libssl-dev)
	fi
fi
config="$here/brunch/kernels/$kver/out/.config"
compression_pattern=
case "$mode" in
	build) compression_pattern='^CONFIG_KERNEL_XZ=y$';;
	package) compression_pattern='^CONFIG_MODULE_COMPRESS_XZ=y$';;
	all)
		config="$here/brunch/kernel-patches/brunch_configs"
		compression_pattern='^CONFIG_(KERNEL|MODULE_COMPRESS)_XZ=y$'
		;;
esac
if [ -n "$compression_pattern" ] && [ -f "$config" ] &&
	grep -Eq "$compression_pattern" "$config"; then
	need xz xz-utils
fi
if { [ "$mode" = build ] || [ "$mode" = all ]; } &&
	[ -f /persist/keys/brunch.priv ] && [ -f /persist/keys/brunch.pem ]; then
	need sbsign sbsigntool
fi
require_dependencies
if [ "$mode" = prepare ] || [ "$mode" = all ]; then
	bash "$here/scripts/check-patches.sh" \
		"$here/brunch/kernel-patches/$kver" \
		"$here/brunch/kernel-patches/chromebook-$kver"
fi
$check_only && exit 0

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
	release_file="./kernels/$kver/out/include/config/kernel.release"
	[ -f "$release_file" ] || { echo "no built kernel at brunch/kernels/$kver - run 'build' first"; exit 1; }
	rel="$(cat "$release_file")"
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
