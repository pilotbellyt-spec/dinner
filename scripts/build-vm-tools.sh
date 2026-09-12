#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
check_only=false
if [ "${1:-}" = --check-dependencies ]; then
	check_only=true
	shift
fi

source "$here/scripts/dependencies.sh"
need podman podman; need find findutils; need tar tar; need gzip gzip
require_dependencies
$check_only && exit 0

box=ovt-build
ver=12.4.5
src=open-vm-tools-$ver-23787635
url=https://github.com/vmware/open-vm-tools/releases/download/stable-$ver/$src.tar.gz

[ "${1:-}" = --clean ] && podman rm -f "$box" >/dev/null 2>&1 || true
if ! podman container exists "$box" 2>/dev/null; then
	podman run -d --name "$box" debian:bookworm sleep infinity >/dev/null
elif [ "$(podman inspect -f '{{.State.Running}}' "$box")" != true ]; then
	podman start "$box" >/dev/null
fi
if ! podman exec "$box" test -f /tmp/stage/complete 2>/dev/null; then
	podman exec "$box" sh -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
		build-essential autoconf automake libtool pkg-config libglib2.0-dev libdrm-dev \
		libtirpc-dev ca-certificates curl >/dev/null'
	podman exec "$box" sh -c "
set -e
cd /tmp
[ -f $src/.extracted ] || { rm -rf $src; curl -fsSL -o ovt.tar.gz $url; tar xzf ovt.tar.gz; touch $src/.extracted; }
cd $src
./configure --prefix=/usr --libdir=/usr/lib64 --disable-static --disable-tests \
	--disable-docs --without-x --without-gtk3 --without-gtkmm3 --without-icu \
	--without-ssl --without-pam --without-dnet --without-fuse --disable-vgauth \
	--disable-deploypkg --disable-containerinfo --enable-resolutionkms \
	--without-root-privileges --disable-glibc-check >/dev/null
make -j\$(nproc) >/dev/null
rm -rf /tmp/stage && make install DESTDIR=/tmp/stage >/dev/null
touch /tmp/stage/complete
"
fi

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/usr/bin" "$tmp/usr/lib64/open-vm-tools/plugins/vmsvc" \
	 "$tmp/usr/lib64/open-vm-tools/plugins/common" "$tmp/etc/vmware-tools"
get() { podman cp "$box:$1" "$2"; }
get /tmp/stage/usr/bin/vmtoolsd "$tmp/usr/bin/vmtoolsd"
get /tmp/stage/usr/lib64/libvmtools.so.0.0.0 "$tmp/usr/lib64/libvmtools.so.0.0.0"
get /tmp/stage/usr/lib64/libhgfs.so.0.0.0 "$tmp/usr/lib64/libhgfs.so.0.0.0"
get /tmp/stage/usr/lib64/open-vm-tools/plugins/common/libvix.so \
    "$tmp/usr/lib64/open-vm-tools/plugins/common/libvix.so"
for p in resolutionKMS powerOps; do
	get "/tmp/stage/usr/lib64/open-vm-tools/plugins/vmsvc/lib$p.so" \
	    "$tmp/usr/lib64/open-vm-tools/plugins/vmsvc/lib$p.so"
done
get /tmp/stage/etc/vmware-tools "$tmp/etc/vmware-tools-stage"
mv "$tmp/etc/vmware-tools-stage"/* "$tmp/etc/vmware-tools/"
rmdir "$tmp/etc/vmware-tools-stage"
rm -f "$tmp/etc/vmware-tools/tools.conf.example"
rm -rf "$tmp/etc/vmware-tools/scripts"
ln -s libvmtools.so.0.0.0 "$tmp/usr/lib64/libvmtools.so.0"
ln -s libhgfs.so.0.0.0 "$tmp/usr/lib64/libhgfs.so.0"
find "$tmp/usr" "$tmp/etc" -type f -exec chmod 0755 {} +

out="$here/configs/packages/vm-tools.tar.gz"
mkdir -p "$(dirname "$out")"
tar zcf "$out" -C "$tmp" usr etc --owner=0 --group=0
echo "Wrote $out"
