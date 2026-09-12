#!/usr/bin/env bash
set -euo pipefail

library="$(realpath "${1:?usage: $0 <libvk_swiftshader.so> [api-version]}")"
api_version="${2:-1.3.289}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

file "$library" | grep -q 'ELF 64-bit.*x86-64' || {
	echo "$library is not an x86-64 shared library"
	exit 1
}
readelf -Ws "$library" | grep -q 'vk_icdGetInstanceProcAddr' || {
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
tar zcf "$out" -C "$stage" usr --owner=0 --group=0
echo "Wrote $out"
