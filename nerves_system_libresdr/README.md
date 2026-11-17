# nerves_system_libresdr

Nerves system for the LibreSDR: a Zynq-7020 board with an AD9363 transceiver
(a PlutoSDR-class design, board rev 5). Everything that runs on the ARM side is
built from source by Buildroot: the U-Boot SPL with the board's `ps7_init`,
U-Boot, Linux, and the root filesystem. The only closed code in the boot path is
the Zynq's on-die BootROM.

This directory started as a fork of `nerves_system_bbb` v2.30.0. The BeagleBone
files were removed on 2026-09-28; see [What was removed from the fork](#what-was-removed-from-the-fork).

## Hardware

| | |
|---|---|
| SoC | Xilinx Zynq-7020, `xc7z020clg400-1`, silicon rev 3.1 (`PS_VERSION` 3) |
| CPU | 2x ARM Cortex-A9 (ARMv7-A, NEON/VFPv3) |
| Memory | 1 GB DDR3 |
| Storage | microSD on SD0 (no card-detect or write-protect lines) |
| Radio | AD9363, SPI on PL pins, driven from userspace; not in the device tree |
| USB | OTG connector, USB3320 ULPI PHY; used as a **device only** (`dr_mode = "peripheral"`) |
| Ethernet | GEM0, RTL8211E PHY, RGMII; negotiates 100 Mbps (not investigated) |
| Console | UART0, 115200 8N1, on the DEBUG USB-C (FT4232H channel C) |
| JTAG | DEBUG USB-C, FT4232H channel A (`openocd -f ../openocd/libresdr.cfg`) |
| Watchdog | Zynq SWDT (Cadence `cdns,wdt-r1p2`), reset on timeout |
| LED / button | green LED on MIO15 (heartbeat trigger); button on MIO14 |
| PL | Artix-7-class fabric, blank at boot; loaded at runtime from Linux |

PS reference clock is 50 MHz, not the usual 33.333 MHz.

## Software

| | |
|---|---|
| Buildroot | 2026.05, via `nerves_system_br` 1.34.0 |
| Toolchain | `nerves_toolchain_armv7_nerves_linux_gnueabihf` 15.3.0 (GCC 15) |
| Boot chain | U-Boot 2025.01 SPL + U-Boot, with `uboot/patches/` ([docs/boot-chain.md](docs/boot-chain.md)) |
| Kernel | Linux 6.12.34, `multi_v7_defconfig` + `linux/nerves-zynq.fragment` ([docs/kernel.md](docs/kernel.md)) |
| Device tree | `dts/xilinx/zynq-libresdr.dts` ([docs/kernel.md](docs/kernel.md)) |
| Root filesystem | squashfs, read-only, A/B slots |
| Application data | f2fs on partition 4, mounted at `/root` |
| Update | fwup, A/B with automatic revert (`uboot/uboot.env`) |

## Boot flow

BootROM loads `BOOT.BIN` (the U-Boot SPL) from the FAT partition. The SPL runs
`ps7_init` (MIO, PLLs, clocks, DDR3), then loads `u-boot.img`. U-Boot reads its
environment from a raw area of the card, picks slot A or B, and boots
`uImage.<slot>` with `zynq-libresdr.<slot>.dtb`. Details, provenance and
recovery: [docs/boot-chain.md](docs/boot-chain.md).

The SPL's `ps7_post_config` enables the PS/PL level shifters and releases the
fabric resets. The PL is still blank at that point, so any M_AXI_GP0 access
before a bitstream is loaded hangs the CPU. With the watchdog in reset mode the
board recovers in about 40 s, but the rule is: load a bitstream before touching
the fabric. See `../nervezynq/AGENTS.md`, "Loading a bitstream".

## SD card layout

Offsets in 512-byte blocks, from `fwup_include/fwup-common.conf`.

| Offset | Size | What |
|---|---|---|
| 0 | 1 | MBR |
| 2048 | 256 (128 KiB) | U-Boot environment, raw (no partition) |
| 4096 | 57344 (28 MiB) | p1, FAT32 `BOOT`: `BOOT.BIN`, `u-boot.img`, `uImage.a/b`, `zynq-libresdr.a/b.dtb` |
| 63488 | 286720 (140 MiB) | p2, rootfs A (squashfs) |
| 350208 | 286720 (140 MiB) | p3, rootfs B (squashfs) |
| 636928 | rest | p4, application data (f2fs), `/root` |

Kernel and DTB live on the FAT partition, one pair per slot, because U-Boot's
squashfs support is slow. A normal OTA writes only the inactive slot's kernel,
DTB and rootfs. `BOOT.BIN` and `u-boot.img` are shared and are only written by
the `complete` task (a fresh card) or the opt-in `bootloader` task.

## A/B updates and revert

The boot logic is entirely in `uboot/uboot.env`, which `post-createfs.sh` turns
into `uboot-env.bin`:

- `nerves_fw_active` selects the slot (`a` = rootfs p2, `b` = p3).
- After an OTA, `upgrade_available=1`. U-Boot increments `bootcount` on every
  boot and saves the environment. Past `bootlimit` (1), `nerves_revert`
  switches back to the other slot.
- The application's `Nervezynq.FirmwareValidator` marks the new slot good 30 s
  after boot (`nerves_fw_validated=1`, `upgrade_available=0`).

On the target, `/etc/fw_env.config` points `fw_printenv`/`fw_setenv` at the same
area (`/dev/mmcblk0`, offset `0x100000`, 128 KiB); `Nerves.Runtime.KV` reads it.

## Identity and provisioning

Each card is burned with a serial number, stored in the U-Boot environment as
`nerves_serial_number`:

```sh
sudo NERVES_SERIAL_NUMBER=lsdr-c fwup -a -i nervezynq.fw -t complete -d /dev/rdiskN
```

- `boardid` reads it (`/etc/boardid.config`); erlinit names the host
  `nerves-` plus its last four characters (`-n nerves-%-.4s`): `lsdr-c` is
  `nerves-dr-c`.
- The application's `usb-gadget-init` hashes it into the USB gadget's MAC
  addresses (`02:1a:35:HH:LL:22` board, `:23` host) and USB serial, and
  VintageNetDirect derives a per-board /30 for `usb0`. Boards with the same
  serial collide on the host.

## Console and network

- **USB (primary):** the application binds a configfs CDC-ECM + CDC-ACM gadget
  (`usb-gadget-init`, run by erlinit `--pre-run-exec`). ECM gives `usb0`, and
  `ssh <board-ip>` lands in IEx. The kernel needs `dr_mode = "peripheral"`; with
  `otg` the controller can come up as a USB host and the board has no USB
  network at all.
- **UART:** IEx is also on UART0 at 115200 (the application's `erlinit.config`
  names `ttyGS0`, which does not exist yet when erlinit starts; it logs
  `error setting controlling terminal: /dev/ttyGS0`). The UART also shows the
  SPL, U-Boot and kernel logs, which is the only view of a board that does not
  reach userspace.
- **Ethernet:** `eth0`, DHCP.

## Building

From the application:

```sh
cd ../nervezynq
MIX_TARGET=libresdr mix firmware
```

`mix.exs` in the application depends on this directory with
`nerves: [compile: true]`, so the system is built from source whenever its
checksum changes (the `package_files` list in this directory's `mix.exs`).
Nerves runs Buildroot through its `container` build runner (Apple's `container`
CLI on macOS); the Buildroot tree persists in the `nerves_system_libresdr-<id>`
container volume, so rebuilds are incremental (one to three minutes).

Buildroot does not rebuild a package when an input outside it changes:

- `dts/` is handled: `post-createfs.sh` compiles `zynq-libresdr.dtb` on every
  build.
- `uboot/patches/`, the U-Boot defconfig and `linux/` fragments are not: delete
  that package's build directory in the volume first. Commands in
  [docs/boot-chain.md](docs/boot-chain.md), "Stale-build traps".

Verify a change in the built image, not the source tree.

## Deploying

| What | How |
|---|---|
| Normal update | `MIX_TARGET=libresdr ./upload.sh <board-ip>` from `../nervezynq` (OTA, A/B) |
| Boot chain update | opt-in fwup `bootloader` task, one board at a time ([docs/boot-chain.md](docs/boot-chain.md)) |
| Fresh card | `fwup -t complete` with `NERVES_SERIAL_NUMBER` (above) |
| Unreachable board | fwup tasks against its card in a reader ([docs/boot-chain.md](docs/boot-chain.md), "Card-reader path") |

## Directory layout

| Path | What |
|---|---|
| `nerves_defconfig` | Buildroot configuration: toolchain, kernel, U-Boot, packages |
| `mix.exs` | Nerves package definition; `package_files` is the artifact checksum |
| `linux/nerves-zynq.fragment` | Kernel config applied on top of `multi_v7_defconfig` |
| `linux/0002-squashfs-*.patch` | Kernel patch carried from upstream Nerves systems |
| `dts/xilinx/zynq-libresdr.dts` | Linux device tree |
| `uboot/patches/` | U-Boot 2025.01 patch series (board DT, `ps7_init`, env fix, defconfig) |
| `uboot/uboot.env` | U-Boot environment source: A/B boot, bootcount, revert |
| `boot/*.2026-07-28`, `boot/BOOT.BIN.vendor-backup` | Reference binaries only ([boot/README.md](boot/README.md)) |
| `fwup.conf` | Firmware image and tasks: `complete`, `upgrade.a/b`, `bootloader`, `provision` |
| `fwup-ops.conf` | On-target operations: `revert`, `validate`, `factory-reset`, `status` |
| `fwup_include/` | Partition layout and provisioning, shared by both fwup files |
| `post-build.sh` | Builds `ops.fw` into the rootfs, copies `fwup_include` |
| `post-createfs.sh` | Assembles `BOOT.BIN`, `uImage`, `uboot-env.bin`, compiles the DTB |
| `rootfs_overlay/etc/erlinit.config` | Mounts, hostname, console (the application overrides it) |
| `rootfs_overlay/etc/boardid.config`, `fw_env.config` | Serial number source (U-Boot env, MAC fallback); U-Boot env location |
| `busybox.fragment` | Busybox options on top of the Nerves defaults |
| `docs/` | [boot-chain.md](docs/boot-chain.md), [kernel.md](docs/kernel.md) |

## What was removed from the fork

Removed 2026-09-28 because nothing on this board uses them:

| Removed | Was |
|---|---|
| `rootfs_overlay/usr/bin/config-pin` | BeagleBone cape pin-mux tool |
| `rootfs_overlay/etc/modprobe.d/wl18xx.conf`, `rootfs_overlay/lib/firmware/ti-connectivity/` | TI WiLink WiFi/BT options and firmware (BeagleBone Black Wireless) |
| `package/extra-dts`, `BR2_PACKAGE_EXTRA_DTS` | BeagleBone i2c1/i2c2 DT overlays in `/lib/firmware` |
| `BR2_PACKAGE_LINUX_FIRMWARE` (Ralink RT2xx, Realtek 87xx) | USB WiFi dongle firmware; `usb0` is peripheral-only, there is no USB host |
| `linux/linux-6.12.defconfig`, `linux/update-kernel-patch.sh` | BeagleBone kernel config and rcn-ee patch tooling; never read by this build |
| U-Boot overlay/cape variables in `fwup_include/provisioning.conf` | BeagleBone U-Boot overlay controls; only `nerves_serial_number` remains |
| `bbb` and `cpuinfo` sources in `rootfs_overlay/etc/boardid.config` | BeagleBone EEPROM and AM335x `/proc/cpuinfo` serial |
| `boot/uEnv.txt` | Vendor-style `uenvcmd` boot script; U-Boot runs `bootcmd` from the raw-MMC env and never read it |
| `assets/images/beaglebone-black.png`, `LICENSES/CC-BY-SA-3.0.txt`, `LICENSES/LicenseRef-TI-Release.txt` | Image and licenses for the removed files |

`CHANGELOG.md` below the `libresdr` section is upstream `nerves_system_bbb`
history, kept for reference.

## Licensing

Buildroot, the kernel and U-Boot are GPL-2.0; see `LICENSES/` and
`REUSE.toml`. The boot chain is built entirely from GPL source; the reference
binaries in `boot/` are not part of the build.
