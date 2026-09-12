# Brunch support for QEMU and VMware guests.

vm_mesa=0
vm_resize=0
vm_nosuspend=0
vm_tools=0
for option in ${1//,/ }
do
	if [ "$option" = "vm_mesa" ]; then vm_mesa=1; fi
	if [ "$option" = "vm_resize" ]; then vm_resize=1; fi
	if [ "$option" = "vm_nosuspend" ]; then vm_nosuspend=1; fi
	if [ "$option" = "vm_tools" ]; then vm_tools=1; fi
done

ret=0

if [ "$vm_resize" -eq 1 ]; then
	state_dev="$(grep ' /roota ' /proc/mounts | cut -d' ' -f1 | sed 's@3$@1@')"
	if [ -b "$state_dev" ]; then
		echo "brunch: $0 resizing stateful filesystem on $state_dev" > /dev/kmsg
		e2fsck -y -f "$state_dev" > /dev/kmsg 2>&1
		resize2fs -f "$state_dev" > /dev/kmsg 2>&1 || ret=1
	else
		echo "brunch: $0 could not identify the stateful device" > /dev/kmsg
		ret=1
	fi
fi

if [ "$vm_mesa" -eq 1 ]; then
	rm -rf /roota/usr/share/policy/crosvm || ret=1
	if [ -f /rootc/packages/vm-crosvm.tar.gz ]; then
		tar zxf /rootc/packages/vm-crosvm.tar.gz -C /roota || ret=1
	else
		echo "brunch: $0 missing vm-crosvm.tar.gz" > /dev/kmsg
		ret=1
	fi
	cat >/roota/etc/init/brunch-vm-crosvm-cleanup.conf <<'CROSVM_CLEANUP' || ret=1
description "Configure release-matched crosvm GPU policies"
start on starting vm_concierge
task
script
  config=/usr/local/vms/etc/arcvm_dev.conf
  policy=/usr/share/policy/crosvm
  milestone=$(sed -n 's/^CHROMEOS_RELEASE_CHROME_MILESTONE=//p' /etc/lsb-release)
  build=$(sed -n 's/^CHROMEOS_RELEASE_VERSION=\([0-9]*\)\..*/\1/p' /etc/lsb-release)
  if [ -f "$config" ]; then
    sed -i '\|^--seccomp-policy-dir=/usr/share/policy/crosvm$|d' "$config"
  fi
  [ "$(cat "$policy/release")" = "$milestone $build" ] || exit 1
  mkdir -p /usr/local/vms/etc
  echo "--seccomp-policy-dir=$policy" >>"$config"
end script
CROSVM_CLEANUP

	if [ -f /rootc/packages/vm-vulkan.tar.gz ]; then
		tar zxf /rootc/packages/vm-vulkan.tar.gz -C /roota || ret=1
	else
		echo "brunch: $0 missing vm-vulkan.tar.gz" > /dev/kmsg
		ret=1
	fi

	if [ -f /rootc/packages/vm-mesa.tar.gz ]; then
		tar zxf /rootc/packages/vm-mesa.tar.gz -C /roota || ret=1
	else
		echo "brunch: $0 missing vm-mesa.tar.gz" > /dev/kmsg
		ret=1
	fi

	if [ -f /rootc/packages/vm-minigbm.tar.gz ]; then
		tar zxf /rootc/packages/vm-minigbm.tar.gz -C /roota || ret=1
		if [ -f /roota/etc/chrome_dev.conf ] && ! grep -q disable-gpu-sandbox /roota/etc/chrome_dev.conf; then
			echo '--disable-gpu-sandbox' >> /roota/etc/chrome_dev.conf || ret=1
		fi
	fi

	sed -i -e '/^native_gpu_memory_buffers$/d' \
		-e '/^video_capture_use_gpu_memory_buffer$/d' \
		-e '/^drm_atomic$/d' /roota/etc/ui_use_flags.txt || ret=1
fi

if [ "$vm_tools" -eq 1 ]; then
	if [ -f /rootc/packages/vm-tools.tar.gz ]; then
		tar zxf /rootc/packages/vm-tools.tar.gz -C /roota || ret=1
		cat >/roota/etc/init/vmtoolsd.conf <<'VMTOOLS' || ret=1
description "VMware guest tools"
start on started boot-services
stop on stopping boot-services
respawn
respawn limit 5 30
exec /usr/bin/vmtoolsd
VMTOOLS
	else
		echo "brunch: $0 missing vm-tools.tar.gz" > /dev/kmsg
		ret=1
	fi
fi

if [ "$vm_mesa" -eq 1 ] || [ "$vm_tools" -eq 1 ]; then
	cat >/roota/usr/sbin/brunch-vm-relabel <<'RELABEL'
#!/bin/sh
mount -o remount,rw / 2>/dev/null || true
for path in /usr/lib64/dri /usr/lib64/vm-vulkan \
            /usr/lib64/libEGL* /usr/lib64/libGLES* /usr/lib64/libGLdispatch* \
            /usr/lib64/libOpenGL* /usr/lib64/libglapi* /usr/lib64/libdrm_* \
            /usr/lib64/libminigbm* /usr/lib64/libgbm* \
            /usr/lib64/libvulkan* /usr/lib64/libvk_swiftshader.so \
            /usr/lib64/libLLVM* /usr/lib64/libSPIRV-Tools* \
            /usr/lib64/libstdc++* /usr/lib64/libffi* \
            /usr/lib64/libxshmfence* /usr/lib64/libdisplay-info* \
            /usr/lib64/libvmtools* /usr/lib64/libhgfs* \
            /usr/lib64/open-vm-tools /usr/bin/vmtoolsd \
            /etc/vmware-tools /usr/share/glvnd /usr/share/vulkan \
            /usr/share/policy/crosvm; do
  [ -e "$path" ] && chcon -R u:object_r:cros_system_file:s0 "$path" 2>/dev/null || true
done
for path in /etc/init/brunch-vm-crosvm-cleanup.conf /etc/init/vmtoolsd.conf; do
  [ -e "$path" ] && chcon u:object_r:cros_conf_file:s0 "$path" 2>/dev/null || true
done
mount -o remount,ro / 2>/dev/null || true
exit 0
RELABEL
	chmod 0755 /roota/usr/sbin/brunch-vm-relabel || ret=1
	if [ -f /roota/usr/share/cros/init/ui-pre-start ] && \
	   ! grep -q brunch-vm-relabel /roota/usr/share/cros/init/ui-pre-start; then
		sed -i '1a /usr/sbin/brunch-vm-relabel || true' \
			/roota/usr/share/cros/init/ui-pre-start || ret=1
	elif [ ! -f /roota/usr/share/cros/init/ui-pre-start ]; then
		echo "brunch: $0 missing ui-pre-start" > /dev/kmsg
		ret=1
	fi
fi

if [ "$vm_nosuspend" -eq 1 ]; then
	mkdir -p /roota/usr/share/power_manager/board_specific
	echo 1 > /roota/usr/share/power_manager/board_specific/disable_idle_suspend || ret=1
fi

exit $ret
