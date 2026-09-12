# QEMU

Clone the repository:

```bash
git clone https://github.com/pilotbellyt-spec/crosvm.git CrOSVM
cd CrOSVM
```

Prepare the Brunch files and VM packages. Supply both recovery images:

```bash
./scripts/install-image.sh --target qemu \
  --rammus images/rammus.bin --reven images/reven.bin \
  --output images/chromeos-qemu.img --size 32
```

Run it:

```bash
./scripts/run-qemu.sh --image images/chromeos-qemu.img --display gtk
```

Enable nested virtualization to run Android apps.

The first boot takes several minutes.
