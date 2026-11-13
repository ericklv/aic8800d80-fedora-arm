# AIC8800D80 WiFi + Bluetooth on Fedora ARM

Install notes and patches for an AIC8800D80 USB adapter (`a69c:8d80`) on Fedora aarch64 with Linux 7.2 and 7.3.

No single upstream repository worked on this hardware, so this setup combines parts of two. This repository holds only the patches and the procedure. The driver sources and firmware are fetched from upstream at pinned commits.

## Status

| Item | Environment | Result |
|---|---|---|
| WiFi | Fedora aarch64, kernel 7.2.6 | Working on the original machine |
| This procedure, end to end | Fedora aarch64 | **Not run.** It was reconstructed from shell history (see [Provenance](#provenance)) |
| `aic_load_fw`, `aic8800_fdrv` build (`0001` and `0003`) | Fedora aarch64, kernels 7.2.15 and 7.3.3, gcc | Compile without errors |
| `aic_btusb` build (BlueZ mode) | Fedora aarch64, kernel 7.3.3, gcc | Compiles without errors |
| WiFi and Bluetooth at the same time | Fedora aarch64, kernel 7.3.3, Orange Pi 5 | Working: `wlan0` associated (WPA2/WPA3 AP), `hci0` powered and discovering. Pairing a device not tested yet |

Patches apply cleanly to the pinned commit.

> [!WARNING]
> **Kernel 7.4 and later are untested.** Check `uname -r` before starting.

Bluetooth depends on the WiFi loader: the adapter enumerates as `a69c:8d80` (vendor interface only) until `aic_load_fw` uploads the firmware, then re-enumerates as `a69c:8d81` with the Bluetooth interface that `aic_btusb` binds to.

## Components

| Component | Source | Notes |
|---|---|---|
| `aic8800_fdrv` (WiFi) | `asanrivas/aic8800-linux-driver` | Patched by `0001` and `0003`, upstream config (`CONFIG_USB_BT=y`) |
| `aic_load_fw` (firmware loader) | `radxa-pkg/aic8800` | Replaces the asanrivas copy, which lacks `aic_compat_8800d80.c` |
| `aic_btusb` (Bluetooth) | `radxa-pkg/aic8800` | Separate module, installed outside DKMS, built in BlueZ mode |
| Firmware | `radxa-pkg/aic8800` | `fw/aic8800D80` |
| `btusb` block | Local modprobe rule | Stops the generic driver from claiming the Bluetooth interface |

### Patches

**`patches/0001-kernel-7.2-compat.patch`** extends `scripts/dkms-pre-build.sh`, which DKMS runs before each build. All fixes are idempotent.

- Adds an `aic_strncpy` shim to `rwnx_fw_dump.c`, `rwnx_msg_tx.c` and `rwnx_platform.c`, because `strncpy()` was removed from the kernel in 7.2.
- Adds the new trailing `const u8 *` argument to `rwnx_cfg80211_remain_on_channel()` in `rwnx_main.c`, guarded for kernel 7.2+. The argument is ignored.

There is no `0002` any more. It set `CONFIG_USB_BT=n` and `CONFIG_USB_MSG_IN_EP=n`, which made `aic8800_fdrv` match `a69c:8d81` on **any** interface, so it bound the Bluetooth interface 0. That only worked while `aic_btusb` was absent. With the upstream `CONFIG_USB_BT=y`, it matches only the vendor interface (`ff/ff/ff`, interface 2) and leaves interfaces 0 and 1 to `aic_btusb`.

**`aic_btusb` in BlueZ mode.** Radxa's source defaults to `CONFIG_BLUEDROID 1` (Android), which exposes `/dev/aicbt_dev` instead of an HCI device, so BlueZ sees no controller. `install.sh` sets it to `0`, as Radxa's own `debian/patches/fix-aic_btusb-use-bluez-by-default.patch` does.

**`patches/0003-kernel-7.3-compat.patch`** ports the driver to the 7.3 `cfg80211` API. Every change is guarded by `KERNEL_VERSION(7, 3, 0)`, so 7.2 builds are unaffected. It is the USB part of Radxa's `fix-linux-7.3-build.patch`, adapted to this tree.

- `remain_on_channel` and `mgmt_tx` receive the cookie by value, since cfg80211 now assigns it. The driver stores it (in the RoC element and in `rwnx_sw_txhdr`) and reports that value back in `cfg80211_ready_on_channel()`, `cfg80211_remain_on_channel_expired()` and `cfg80211_mgmt_tx_status()`, instead of its own counter or the skb address.
- Frames not sent through `mgmt_tx` (internal RoC, TDLS discovery, monitor injection) carry cookie 0 and skip the TX status report.
- `probe_client` is registered as `probe_peer`, uses the given cookie, and `cfg80211_probe_status()` gets `link_id = -1`.
- The `remain_on_channel` signature already includes the 7.2 `link_addr` argument, so the `0001` pre-build fixup skips it.

### Why `btusb` is blocked

The stock `btusb` driver and the vendor `aic_btusb` driver can both claim the adapter's Bluetooth interface. The likely result is the symptom seen before this fix: WiFi or Bluetooth worked, but not both, varying between boots or replugs.

This rule blocks `btusb` for the **whole system**, so other USB Bluetooth adapters that depend on it will stop working.

## Automated installation

`install.sh` runs the manual steps below. Run it as a normal user; it asks for sudo when needed. It stops on kernel 7.4+ unless `--allow-unsupported-kernel` is given.

```bash
./install.sh --dry-run    # print the commands without changing anything
./install.sh              # install
sudo reboot
./install.sh verify       # check modules and interfaces
```

| Command | Purpose |
|---|---|
| `./install.sh install` | Full installation (default) |
| `./install.sh rebuild-bt` | Rebuild `aic_btusb` after a kernel update |
| `./install.sh verify` | Check modules, WiFi interface and Bluetooth controller |
| `./install.sh uninstall` | Remove everything it installed, except the sources |

Sources are kept in `~/aic8800-build`, or in `AIC8800_WORK` if set. Each install resets those clones to the pinned commits, which discards any edits there. Unlike the manual steps, the script always installs the udev rule, which only acts on the storage-mode USB IDs.

The script has only been tested with `sudo`, `dnf`, `dkms` and `make` stubbed out, on a machine without the adapter. It has not yet run on Fedora ARM.

## Manual installation

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
PATCHES="$HOME/aic8800d80-fedora-arm/patches"
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
git apply "$PATCHES/0003-kernel-7.3-compat.patch"

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
sed -i 's/^\(#define CONFIG_BLUEDROID[[:space:]]\+\)1/\10/' aic_btusb.h   # BlueZ instead of Android
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

Test WiFi and Bluetooth **at the same time**.

## Kernel updates

| Component | After a kernel update |
|---|---|
| `aic_load_fw`, `aic8800_fdrv` | DKMS rebuilds them automatically |
| Firmware, modprobe rule | No action needed |
| `aic_btusb` | **Rebuild by hand**, because it is not managed by DKMS |

After rebooting into the new kernel, rebuild Bluetooth with `./install.sh rebuild-bt`, or by hand. For the manual route, keep `$WORK` or fetch the Radxa source again.

```bash
cd "$HOME/aic8800-build/radxa-aic8800/src/USB/driver_fw/drivers/aic_btusb"
sed -i 's/^\(#define CONFIG_BLUEDROID[[:space:]]\+\)1/\10/' aic_btusb.h
make clean && make
sudo install -p -m 644 aic_btusb.ko "/lib/modules/$(uname -r)/kernel/drivers/bluetooth/"
sudo depmod -a
sudo modprobe aic_btusb
```

## Kernel 7.3 and later

Kernel 7.3 changed the `cfg80211` API in ways that break the unpatched driver:

| API change | Handled in `0003` |
|---|---|
| `cfg80211_probe_status()` takes a `link_id` | Passes `-1` (no MLO) |
| `mgmt_tx` and `remain_on_channel` take the cookie as `u64` instead of `u64 *` | Stores cfg80211's cookie and reports it back |
| `probe_client` removed from `struct cfg80211_ops`, replaced by `probe_peer` | Registered as `probe_peer` |

Signature changes alone would compile but break off-channel management frames (for example WPA3/SAE and P2P), because cfg80211 matches TX status reports by cookie.

7.4 is untested. Radxa already carries a separate `fix-linux-7.4-build.patch`, so expect another port there.

## Troubleshooting

| Symptom | Likely cause | Action |
|---|---|---|
| `implicit declaration of function 'strncpy'` | `0001` is missing or the pre-build script did not run | Check `grep aic_strncpy /usr/src/aic8800-1.2.1/scripts/dkms-pre-build.sh` and that the script is executable |
| Incompatible pointer at `remain_on_channel` or `mgmt_tx` | On 7.2: `0001` is missing. On 7.3: `0003` is missing | Check `uname -r` and the patches |
| No Bluetooth controller, adapter stays at `a69c:8d80` | `aic_load_fw` is not loaded, so the firmware was never uploaded | Fix the WiFi modules first (`dkms status`, `lsmod`) |
| `/dev/aicbt_dev` exists but `bluetoothctl show` finds no controller | `aic_btusb` built in Android (Bluedroid) mode | Rebuild it with `CONFIG_BLUEDROID 0` (`./install.sh rebuild-bt`) |
| Adapter at `a69c:8d81`, `aic_btusb` bound, but no WiFi interface | `aic8800_fdrv` built with `CONFIG_USB_BT=n` binds interface 0, which `aic_btusb` owns | Use the upstream `CONFIG_USB_BT=y` (no `0002`) and reinstall |
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
- **Local working trees.** `0001` and the former `0002` are the uncommitted diffs from local clones of the asanrivas repository.

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
| [radxa-pkg/aic8800](https://github.com/radxa-pkg/aic8800) | `aic_load_fw`, `aic_btusb`, firmware; basis of `0003` (`debian/patches/fix-linux-7.3-build.patch`) | GPL-3.0+, per its `LICENSE` and `debian/copyright` |
| [theabramkhan/aic8800d80-linux-kernel7](https://github.com/theabramkhan/aic8800d80-linux-kernel7) | Approach for the kernel 7.2 fixes in `0001` | See its repository |

This repository does not redistribute their sources or firmware.
