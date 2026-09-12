#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
check_only=false
if [ "${1:-}" = --check-dependencies ]; then
	check_only=true
	shift
fi

source "$repo/scripts/dependencies.sh"
need file file; need readelf binutils; need tar tar; need gzip gzip

if [ "$#" -eq 0 ]; then
	need c++ build-essential
	[ -f /etc/ssl/certs/ca-certificates.crt ] || missing+=(ca-certificates)
	need cmake cmake; need git git; need ninja ninja-build; need python3 python3
	build=true
else
	need realpath coreutils
	build=false
fi
require_dependencies
$check_only && exit 0

stage="$(mktemp -d -p /var/tmp)"
trap 'rm -rf "$stage"' EXIT

if $build; then
	pin=fce27a96526f54c6d31fdccf57629788e3712220
	git init -q "$stage/swiftshader"
	git -C "$stage/swiftshader" fetch --depth 1 \
		https://swiftshader.googlesource.com/SwiftShader "$pin"
	git -C "$stage/swiftshader" checkout --detach FETCH_HEAD
	cmake -S "$stage/swiftshader" -B "$stage/swiftshader/build" -G Ninja \
		-DREACTOR_BACKEND=Subzero -DSWIFTSHADER_BUILD_TESTS=OFF \
		-DSWIFTSHADER_WARNINGS_AS_ERRORS=OFF \
		-DSWIFTSHADER_BUILD_WSI_XCB=OFF -DSWIFTSHADER_BUILD_WSI_WAYLAND=OFF
	cmake --build "$stage/swiftshader/build" --parallel --target vk_swiftshader
	library="$stage/swiftshader/build/libvk_swiftshader.so"
	api_version=1.3.289
else
	library="$(realpath "${1:?usage: $0 [libvk_swiftshader.so [api-version]]}")"
	api_version="${2:-1.3.289}"
fi

file "$library" | grep -q 'ELF 64-bit.*x86-64' || {
	echo "$library is not an x86-64 shared library"
	exit 1
}
readelf -Ws "$library" | grep 'vk_icdGetInstanceProcAddr' >/dev/null || {
	echo "$library is not a Vulkan ICD"
	exit 1
}

mkdir -p "$stage/usr/lib64" "$stage/usr/share/vulkan/icd.d"
install -m 0755 "$library" "$stage/usr/lib64/libvk_swiftshader.so"
cat >"$stage/usr/share/vulkan/icd.d/swiftshader_icd.x86_64.json" <<EOF
{
    "ICD": {
        "api_version": "$api_version",
        "library_path": "/usr/lib64/libvk_swiftshader.so"
    },
    "file_format_version": "1.0.0"
}
EOF

out="$repo/configs/packages/vm-vulkan.tar.gz"
mkdir -p "$(dirname "$out")"
tar zcf "$out" -C "$stage" usr --owner=0 --group=0
echo "Wrote $out"
