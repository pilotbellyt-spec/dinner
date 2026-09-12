#!/usr/bin/env bash
set -euo pipefail

rootfs="${1:?usage: build-crosvm-policies.sh ROOT-A.img OUTPUT.tar.gz}"
output="$(realpath -m "${2:?output package is required}")"
release="$(debugfs -R 'cat /etc/lsb-release' "$rootfs" 2>/dev/null)"
milestone="$(sed -n 's/^CHROMEOS_RELEASE_CHROME_MILESTONE=//p' <<<"$release")"
build="$(sed -n 's/^CHROMEOS_RELEASE_VERSION=\([0-9]*\)\..*/\1/p' <<<"$release")"
[[ "$milestone" =~ ^[0-9]+$ && "$build" =~ ^[0-9]+$ ]] || {
	echo "could not identify the ChromeOS release in $rootfs" >&2
	exit 1
}
branch="release-R$milestone-$build.B"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/policies" "$work/compiler" "$work/package/usr/share/policy/crosvm"
base=https://chromium.googlesource.com/chromiumos/platform
curl --fail --location --silent --show-error \
	"$base/crosvm/+archive/refs/heads/$branch/jail/seccomp/x86_64.tar.gz" \
	-o "$work/policies.tar.gz"
curl --fail --location --silent --show-error \
	"$base/minijail/+archive/refs/heads/$branch/tools.tar.gz" \
	-o "$work/compiler.tar.gz"
tar -xzf "$work/policies.tar.gz" -C "$work/policies"
tar -xzf "$work/compiler.tar.gz" -C "$work/compiler"

gpu_policy="$work/policies/gpu_common.policy"
grep -q '^madvise:' "$gpu_policy"
if ! grep '^madvise:' "$gpu_policy" | grep -q MADV_HUGEPAGE; then
	sed -i '/^madvise:/s/$/ || arg2 == MADV_HUGEPAGE/' "$gpu_policy"
fi
destination="$work/package/usr/share/policy/crosvm"
for policy in "$work"/policies/*.policy; do
	sed -i "s|/usr/share/policy/crosvm|$work/policies|g" "$policy"
done
for policy in "$work"/policies/*.policy; do
	python3 "$work/compiler/compile_seccomp_policy.py" \
		--arch-json "$work/policies/constants.json" --default-action trap \
		"$policy" "$destination/$(basename "${policy%.policy}").bpf"
done
printf '%s\n' "$milestone $build" >"$destination/release"
mkdir -p "$(dirname "$output")"
tar -czf "$output" -C "$work/package" --owner=0 --group=0 usr
echo "Built $output"
