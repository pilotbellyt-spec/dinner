#!/usr/bin/env bash
set -euo pipefail
export PATH="$PATH:/usr/sbin:/sbin"

root="$(realpath "${1:?usage: build-vm-mesa.sh <reven-root.img> [out.tar.gz]}")"
here="$(cd "$(dirname "$0")/.." && pwd)"
out="${2:-$here/configs/packages/vm-mesa.tar.gz}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/usr/lib64/dri" "$tmp/usr/share/glvnd/egl_vendor.d"
cd "$tmp/usr/lib64"

libs=(libEGL.so.1.1.0 libGLESv2.so.2.1.0 libGLdispatch.so.0.0.0 libOpenGL.so.0.0.0
      libEGL_mesa.so.0.0.0 libglapi.so.0.0.0 libminigbm.so.1.0.0
      libdrm_radeon.so.1.124.0 libdrm_amdgpu.so.1.124.0 libdrm_nouveau.so.2.124.0)
for f in "${libs[@]}"; do
	debugfs -R "dump /usr/lib64/$f $f" "$root" 2>/dev/null
	[ -s "$f" ] || { echo "missing $f in $root"; exit 1; }
done
# All dri/*.so names are hardlinks to one gallium megadriver: keep one copy.
debugfs -R "dump /usr/lib64/dri/iris_dri.so dri/libgallium_megadriver.so" "$root" 2>/dev/null
[ -s dri/libgallium_megadriver.so ] || { echo "megadriver dump failed"; exit 1; }

ln -s libEGL.so.1.1.0 libEGL.so.1; ln -s libEGL.so.1 libEGL.so
ln -s libGLESv2.so.2.1.0 libGLESv2.so.2; ln -s libGLESv2.so.2 libGLESv2.so
ln -s libGLdispatch.so.0.0.0 libGLdispatch.so.0; ln -s libGLdispatch.so.0 libGLdispatch.so
ln -s libOpenGL.so.0.0.0 libOpenGL.so.0; ln -s libOpenGL.so.0 libOpenGL.so
ln -s libEGL_mesa.so.0.0.0 libEGL_mesa.so.0; ln -s libEGL_mesa.so.0 libEGL_mesa.so
ln -s libglapi.so.0.0.0 libglapi.so.0; ln -s libglapi.so.0 libglapi.so
ln -s libdrm_radeon.so.1.124.0 libdrm_radeon.so.1
ln -s libdrm_amdgpu.so.1.124.0 libdrm_amdgpu.so.1
ln -s libdrm_nouveau.so.2.124.0 libdrm_nouveau.so.2
cd dri
for n in virtio_gpu kms_swrast swrast vmwgfx iris crocus nouveau radeonsi r600 r300; do
	ln -s libgallium_megadriver.so "${n}_dri.so"
done
cd "$tmp"
debugfs -R "dump /usr/share/glvnd/egl_vendor.d/50_mesa.json usr/share/glvnd/egl_vendor.d/50_mesa.json" "$root" 2>/dev/null

# debugfs dump does not preserve permissions; shared libraries must be
# executable or Chrome's dlopen fails with EPERM.
find "$tmp/usr" -type f -exec chmod 0755 {} +
mkdir -p "$(dirname "$out")"
tar zcf "$out" usr --owner=0 --group=0
echo "Wrote $out"
