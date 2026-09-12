# VMware

Clone the repository:

```bash
git clone https://github.com/pilotbellyt-spec/crosvm.git CrOSVM
cd CrOSVM
```

Prepare the Brunch files and VM packages. Supply both recovery images:

```bash
./scripts/install-image.sh --target vmware \
  --rammus images/rammus.bin --reven images/reven.bin \
  --output images/chromeos-vmware.img --size 32
```

Open `images/chromeos-vmware.vmx` in VMware Workstation.
Keep the `.vmx` and `.vmdk` files together.

The first boot takes several minutes.
