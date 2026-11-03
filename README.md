# AIC8800D80 WiFi + Bluetooth on Fedora ARM

Install notes and patches for an AIC8800D80 USB adapter (`a69c:8d80`) on Fedora aarch64 with Linux 7.2.

No single upstream repository worked on this hardware, so this setup combines parts of two. This repository holds only the patches and the procedure. The driver sources and firmware are fetched from upstream at pinned commits.

## Status

| Item | Environment | Result |
|---|---|---|
| WiFi | Fedora aarch64, kernel 7.2.6 | Working on the original machine |
| Bluetooth and WiFi at the same time | Fedora aarch64 | **Not confirmed.** The record of the original setup ends before any check |
| This procedure, end to end | Fedora aarch64 | **Not run.** It was reconstructed from shell history (see [Provenance](#provenance)) |
| `aic_btusb` and `aic_load_fw` build | x86_64, kernel 7.3.1, clang | Compile without errors (`aic_load_fw` was not linked into a `.ko`, because the overall build stopped) |
| `aic8800_fdrv` build | x86_64, kernel 7.3.1, clang | **Fails.** See [Kernel 7.3 and later](#kernel-73-and-later) |

Patches apply cleanly to the pinned commit. The exact tree has not been rebuilt against 7.2 headers since the patches were extracted.

> [!WARNING]
> **Kernel 7.3 and later are not supported.** Check `uname -r` before starting. On 7.3+, either boot and pin a 7.2 kernel or port the driver first.

## Components

| Component | Source | Notes |
|---|---|---|
| `aic8800_fdrv` (WiFi) | `asanrivas/aic8800-linux-driver` | Patched by `0001` and `0002` |
| `aic_load_fw` (firmware loader) | `radxa-pkg/aic8800` | Replaces the asanrivas copy, which lacks `aic_compat_8800d80.c` |
| `aic_btusb` (Bluetooth) | `radxa-pkg/aic8800` | Separate module, installed outside DKMS |
| Firmware | `radxa-pkg/aic8800` | `fw/aic8800D80` |
| `btusb` block | Local modprobe rule | Stops the generic driver from claiming the Bluetooth interface |

### Patches

**`patches/0001-kernel-7.2-compat.patch`** extends `scripts/dkms-pre-build.sh`, which DKMS runs before each build. All fixes are idempotent.

- Adds an `aic_strncpy` shim to `rwnx_fw_dump.c`, `rwnx_msg_tx.c` and `rwnx_platform.c`, because `strncpy()` was removed from the kernel in 7.2.
- Adds the new trailing `const u8 *` argument to `rwnx_cfg80211_remain_on_channel()` in `rwnx_main.c`, guarded for kernel 7.2+. The argument is ignored.

**`patches/0002-wifi-disable-usb-bt.patch`** changes the WiFi driver configuration.

- Sets `CONFIG_USB_BT=n` and `CONFIG_USB_MSG_IN_EP=n` in the `aic8800_fdrv` Makefile, so Bluetooth is left to `aic_btusb`.
- Defines `USB_PRODUCT_ID_AIC8800D83`, `D84` and `D85` in `aicwf_usb.h`, under `#ifndef CONFIG_USB_BT`.

### Why `btusb` is blocked

The stock `btusb` driver and the vendor `aic_btusb` driver can both claim the adapter's Bluetooth interface. The likely result is the symptom seen before this fix: WiFi or Bluetooth worked, but not both, varying between boots or replugs.

This rule blocks `btusb` for the **whole system**, so other USB Bluetooth adapters that depend on it will stop working.

## Installation

Commands are written for bash. If your login shell is fish, run `bash` first.

### 1. Install build dependencies

```bash
sudo dnf install dkms kernel-devel kernel-headers gcc make git python3 sg3_utils usbutils
```

Headers must match the running kernel. If this check fails, reboot into the newest kernel and try again:

```bash
ls "/lib/modules/$(uname -r)/build"
```

### 2. Fetch sources at the pinned commits

Set `PATCHES` to the `patches` directory of your clone of this repository.

```bash
PATCHES="$HOME/aic8800-d80-fedora-arm/patches"
WORK="$HOME/aic8800-build"
mkdir -p "$WORK" && cd "$WORK"

git clone https://github.com/asanrivas/aic8800-linux-driver.git
git -C aic8800-linux-driver checkout 4125bcc0d3fadc40ab3194c80389284dd54b872e

git clone https://github.com/radxa-pkg/aic8800.git radxa-aic8800
git -C radxa-aic8800 checkout 516e3b087763d80c44f5e3b6d2dd63e0d925c91d
```

### 3. Assemble the source tree

```bash
cd "$WORK/aic8800-linux-driver"
git apply "$PATCHES/0001-kernel-7.2-compat.patch"
git apply "$PATCHES/0002-wifi-disable-usb-bt.patch"

RADXA="$WORK/radxa-aic8800/src/USB/driver_fw"
rm -rf drivers/aic8800/aic_load_fw
cp -r "$RADXA/drivers/aic8800/aic_load_fw" drivers/aic8800/aic_load_fw
chmod +x scripts/dkms-pre-build.sh
```

Replace the whole `aic_load_fw` directory. Copying individual files leaves unresolved symbols such as `FW_PATCH_BASE_NAME_8800D80_U02_EXT`, `ext_patch_nb` and `wl_addr`.

### 4. Build and install the WiFi modules with DKMS

This removes any earlier `aic8800/1.2.1` installation.

```bash
sudo dkms remove aic8800/1.2.1 --all 2>/dev/null
sudo rm -rf /usr/src/aic8800-1.2.1
sudo cp -r "$WORK/aic8800-linux-driver" /usr/src/aic8800-1.2.1

sudo dkms add -m aic8800 -v 1.2.1
sudo dkms build -m aic8800 -v 1.2.1
sudo dkms install -m aic8800 -v 1.2.1 --force
```

Compiler warnings such as `-Wmissing-declarations` and `-Wimplicit-fallthrough` are expected. If the build fails, check `/var/lib/dkms/aic8800/1.2.1/build/make.log`.

### 5. Install the firmware

```bash
sudo mkdir -p /lib/firmware/aic8800D80
sudo cp -r "$RADXA/fw/aic8800D80/." /lib/firmware/aic8800D80/
```

Do not run the upstream `install_setup.sh` after this step. It copies the asanrivas firmware over this directory.

### 6. Build and install the Bluetooth module

```bash
cd "$RADXA/drivers/aic_btusb"
make
sudo install -p -m 644 aic_btusb.ko "/lib/modules/$(uname -r)/kernel/drivers/bluetooth/"
sudo depmod -a
```

### 7. Block the generic `btusb` driver

```bash
echo "install btusb /bin/false" | sudo tee /etc/modprobe.d/aic8800-bt.conf
```

### 8. Load modules at boot

The record of the original setup does not show this step. It comes from the upstream `install_setup.sh`.

```bash
printf '%s\n' aic_load_fw aic8800_fdrv | sudo tee /etc/modules-load.d/aic8800.conf
```

If the adapter appears as a USB storage device (`a69c:5721`, `5723` or `5725`) instead of `a69c:8d80`, also install the mode-switch rule:

```bash
sudo cp "$WORK/aic8800-linux-driver/tools/aic.rules" /etc/udev/rules.d/
sudo udevadm control --reload
sudo udevadm trigger
```

### 9. Reboot and verify

Reboot with the adapter plugged in, then run:

```bash
dkms status | grep aic8800
lsusb | grep -i a69c
lsmod | grep -E 'aic|btusb'
nmcli device
bluetoothctl show
sudo dmesg | grep -iE 'aic|firmware' | tail -40
```

Expected results:

- `dkms status` reports `aic8800/1.2.1` as `installed` for the running kernel.
- `lsmod` lists `aic_load_fw`, `aic8800_fdrv` and `aic_btusb`, but not `btusb`.
- `nmcli device` lists a WiFi interface, and `bluetoothctl show` lists a controller.

Test WiFi and Bluetooth **at the same time**, since this has not been confirmed. Then update the [Status](#status) table.

## Kernel updates

| Component | After a kernel update |
|---|---|
| `aic_load_fw`, `aic8800_fdrv` | DKMS rebuilds them automatically |
| Firmware, modprobe rule | No action needed |
| `aic_btusb` | **Rebuild by hand**, because it is not managed by DKMS |

After rebooting into the new kernel, rebuild Bluetooth. Keep `$WORK` for this, or fetch the Radxa source again.

```bash
cd "$HOME/aic8800-build/radxa-aic8800/src/USB/driver_fw/drivers/aic_btusb"
make clean && make
sudo install -p -m 644 aic_btusb.ko "/lib/modules/$(uname -r)/kernel/drivers/bluetooth/"
sudo depmod -a
sudo modprobe aic_btusb
```

## Kernel 7.3 and later

`aic8800_fdrv` does not build against 7.3.1, due to `cfg80211` API changes. All five compile errors are in `rwnx_main.c`. Line numbers below are from the patched file.

| Line | API change | Error |
|---|---|---|
| 3498, 3500 | `cfg80211_probe_status()` takes another argument | Expected 8 arguments, got 7 |
| 5823 | `mgmt_tx` takes `u64` instead of `u64 *` as its last argument | Incompatible function pointer |
| 5828 | `probe_client` was removed from `struct cfg80211_ops` | Unknown field |
| 5836 | `remain_on_channel` takes `u64` instead of `u64 *` for the cookie | Incompatible function pointer |

Fixing these needs a real port, not only signature changes, because the driver returns its cookie through the pointer that is going away. A later build may expose further errors, as well as runtime problems that compilation cannot reveal.

Until the driver is ported, stay on a 7.2 kernel:

```bash
sudo dnf versionlock add kernel kernel-core kernel-modules kernel-modules-core kernel-devel
```

## Troubleshooting

| Symptom | Likely cause | Action |
|---|---|---|
| `implicit declaration of function 'strncpy'` | `0001` is missing or the pre-build script did not run | Check `grep aic_strncpy /usr/src/aic8800-1.2.1/scripts/dkms-pre-build.sh` and that the script is executable |
| Incompatible pointer at `remain_on_channel` | On 7.2: `0001` is missing. On 7.3+: see above | Check `uname -r` and the patch |
| `FW_PATCH_BASE_NAME_8800D80_U02_EXT` undefined | Partial copy of `aic_load_fw` | Repeat step 3, replacing the whole directory |
| Module fails to load with `Key was rejected by service` | Secure Boot rejects unsigned modules | Disable Secure Boot, or enroll a MOK and sign the modules |
| `btusb` still loaded after reboot | Module was loaded from an older initramfs | Run `sudo dracut -f` and reboot |
| Bluetooth gone after a kernel update | `aic_btusb` is not managed by DKMS | See [Kernel updates](#kernel-updates) |

## Uninstall

```bash
sudo dkms remove aic8800/1.2.1 --all
sudo rm -rf /usr/src/aic8800-1.2.1 /lib/firmware/aic8800D80
sudo rm -f /etc/modprobe.d/aic8800-bt.conf /etc/modules-load.d/aic8800.conf /etc/udev/rules.d/aic.rules
sudo rm -f /lib/modules/*/kernel/drivers/bluetooth/aic_btusb.ko
sudo depmod -a
```

## Provenance

The original setup was edited by hand under `/usr/src/aic8800-1.2.1` and never committed. This procedure was rebuilt from the following sources:

- **Shell history from the ARM machine.** It is deduplicated, so the order of steps was inferred. It ends at `modprobe -r aic8800_fdrv aic_load_fw`, with no later verification.
- **Local working trees.** `0001` and `0002` are the uncommitted diffs from local clones of the asanrivas repository.

These steps differ from the history on purpose:

- `depmod -a` was added after installing `aic_btusb`.
- `mkdir -p` was added for the firmware directory.
- `aic_btusb.c` is no longer copied into `/lib/modules`, since only the `.ko` is needed.
- The trial-and-error copying of individual `aic_load_fw` files was dropped.

The Radxa commit is the one used for the compile test. The ARM machine used a shallow clone of the branch head at the time, so its commit may have differed.

## Credits and licensing

| Project | Used for | License |
|---|---|---|
| [asanrivas/aic8800-linux-driver](https://github.com/asanrivas/aic8800-linux-driver) | Base driver, patched here | MIT, per its `LICENSE` |
| [radxa-pkg/aic8800](https://github.com/radxa-pkg/aic8800) | `aic_load_fw`, `aic_btusb`, firmware | GPL-3.0+, per its `LICENSE` and `debian/copyright` |
| [theabramkhan/aic8800d80-linux-kernel7](https://github.com/theabramkhan/aic8800d80-linux-kernel7) | Approach for the kernel 7.2 fixes in `0001` | See its repository |

This repository does not redistribute their sources or firmware.
