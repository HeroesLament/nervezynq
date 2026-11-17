# Linux kernel and device tree

What the LibreSDR kernel is built from, why each non-default option and DT node
is there, and how to change them without shipping a stale build.

## Kernel

| | |
|---|---|
| Version | Linux 6.12.34 (kernel.org stable tarball, `BR2_LINUX_KERNEL_CUSTOM_TARBALL_LOCATION`) |
| Base config | `multi_v7_defconfig` (`BR2_LINUX_KERNEL_DEFCONFIG="multi_v7"`) |
| Board config | `linux/nerves-zynq.fragment`, merged on top |
| Patches | every `*.patch` in `linux/` (`BR2_LINUX_KERNEL_PATCH`); currently `0002-squashfs-provide-backing_dev_info...`, carried from the upstream Nerves systems |
| Image | zImage, wrapped as a legacy `uImage` (load/entry `0x8000`) by `post-createfs.sh` |

### What the fragment adds, and why

Grouped as in `linux/nerves-zynq.fragment`, whose comments carry the detail.

**Nerves basics.** `SQUASHFS` + `SQUASHFS_XZ` (read-only rootfs), `F2FS_FS`
(application partition), `TMPFS`, `DEVTMPFS` + `DEVTMPFS_MOUNT`.

**Zynq PS peripherals.**

| Option | For |
|---|---|
| `SERIAL_XILINX_PS_UART` + `_CONSOLE` | UART0 console (`ttyPS0`) |
| `MMC_SDHCI`, `MMC_SDHCI_PLTFM`, `MMC_SDHCI_OF_ARASAN` | SD0 |
| `MACB` | GEM0 Ethernet |
| `GPIO_ZYNQ` | MIO/EMIO GPIO (LED, button, PHY resets) |
| `CADENCE_WATCHDOG` | The PS SWDT. `XILINX_WATCHDOG` is the PL AXI IP and does not bind; without Cadence there is no `/dev/watchdog0` and nerves_heart runs unprotected. |
| `WATCHDOG`, `XILINX_WATCHDOG` | Enabled but unused on this board |
| `MARVELL_PHY` | Enabled, but the PHY is an RTL8211E (bound by the Realtek driver from `multi_v7`) |

**PL access.** `FPGA`, `FPGA_MGR_ZYNQ_FPGA`, `FPGA_BRIDGE`, `FPGA_REGION`,
`OF_FPGA_REGION` provide `fpga_manager` (the application reads its state), and
`UIO`, `UIO_PDRV_GENIRQ`, `UIO_DMEM_GENIRQ` are available for userspace drivers.
Bitstreams are actually loaded by the application through devcfg; see
`../../nervezynq/AGENTS.md`.

**USB device mode.** `USB_CHIPIDEA` + `USB_CHIPIDEA_UDC` + `USB_CHIPIDEA_GENERIC`
(the Zynq's ChipIdea controller), `USB_ULPI` + `USB_ULPI_VIEWPORT`, `USB_PHY`,
`USB_GADGET`, `USB_LIBCOMPOSITE`, and configfs gadgets: `CONFIGFS_FS`,
`USB_CONFIGFS`, `USB_CONFIGFS_ACM`, `USB_CONFIGFS_ECM`. The legacy `g_serial`
is off on purpose: it binds at init before `ci_hdrc` has probed, fails with
"couldn't find an available UDC" and never retries. configfs lets
`usb-gadget-init` bind after the UDC exists. `REGULATOR` +
`REGULATOR_FIXED_VOLTAGE` back the fixed VBUS regulator the PHY driver insists
on (see the DT below).

**Things that must be off.** `CPU_FREQ`, `ARM_ZYNQ_CPUFREQ`, `CPUFREQ_DT`,
`CPUFREQ_DT_PLATDEV`: `cpufreq-dt` probes on Zynq, fails to set the ARM clock
(`-EBUSY`) and `BUG()`s inside `kernel_init`, a panic before userspace.

**For the userspace stack.** `IP_ADVANCED_ROUTER` + `IP_MULTIPLE_TABLES`:
vintage_net uses one routing table per interface; without them
`ip route add ... table N` fails, RouteManager crashes and takes vintage_net
and mdns_lite down with it. `CGROUPS`, `MEMCG`, `CGROUP_SCHED`,
`FAIR_GROUP_SCHED`: erlinit mounts the cpu and memory controllers.

## Device tree

Source: `dts/xilinx/zynq-libresdr.dts`, on top of the kernel's
`zynq-7000.dtsi`. `post-createfs.sh` compiles it on every system build (same
cpp flags and `dtc` as the kernel's own rule) into `zynq-libresdr.dtb`, which
fwup writes to the FAT partition as `zynq-libresdr.<slot>.dtb`. U-Boot has its
own, separate board DT (`uboot/patches/0001`).

| Node | Setting | Why |
|---|---|---|
| `/memory@0` | 1 GB | |
| `/reserved-memory/pcap-readback@3fc00000` | 4 MB, `no-map` | Fixed, contiguous buffer for devcfg (PCAP) configuration readback, big enough for the whole xc7z020 configuration memory. A DT node rather than `mem=` because bootargs live in the raw U-Boot env. |
| `&clkc` | `ps-clk-frequency = <50000000>` | This board's PS_CLK is 50 MHz, not 33.333 MHz. |
| `&clkc` | `fclk-enable = <0xf>` | Keeps FCLK0..3 running. Without it FCLK0, which clocks the PL's AXI slave, is gated from the start and every AXI read into the PL hangs the CPU. `clk_ignore_unused` does not help. |
| `&uart0` | okay | Console, `stdout-path = "serial0:115200n8"` |
| `&gem0` | RGMII-ID, PHY at 0, reset on MIO46 | Ethernet (RTL8211E) |
| `&sdhci0` | `broken-cd`, `disable-wp`, 4-bit | The board wires neither card-detect nor write-protect. |
| `&watchdog0` | `reset-on-timeout` | Without it `cdns-wdt` leaves `ZMR.RSTEN` clear and a timeout only raises an interrupt, so a CPU stalled on a PL access is never reset. Check on a board: `ZMR` (`0xF8005000`) reads `0x33`. |
| `&usb0` | `dr_mode = "peripheral"` | In OTG mode `ci_hdrc` picks its role at probe from ID/VBUS and can come up as a host (or register no UDC), which leaves the board with no USB network. The board is always the device. |
| `usb_phy0` | `usb-nop-xceiv`, reset on MIO47 | The USB3320 ULPI PHY, modelled as mainline does for zed/zc702. The Xilinx vendor `ulpi-phy` compatible matches nothing in mainline and leaves `ci_hdrc` deferred forever. |
| `usb_vbus` | fixed 5 V regulator | `usb_phy_generic` requests VBUS exclusively and refuses a dummy supply. |
| `leds/led0` | MIO15, heartbeat | |
| `gpio-keys/button` | MIO14 | |

Deliberately absent: the AD9363 (driven from userspace over SPI on PL pins, via
`Nervezynq.AD9363`) and anything in the PL (blank at boot, loaded at runtime).

Checking the running DT on a board:

```sh
ssh <board-ip>
```
```elixir
File.read!("/proc/device-tree/axi/usb@e0002000/dr_mode")   # "peripheral\0"
File.exists?("/proc/device-tree/axi/watchdog@f8005000/reset-on-timeout")
```

## Changing the kernel or the device tree

**Device tree.** Edit `dts/xilinx/zynq-libresdr.dts`, then
`MIX_TARGET=libresdr mix firmware` in `../nervezynq`. `post-createfs.sh`
recompiles it. Verify in the image:

```sh
unzip -o -q _build/libresdr_dev/nerves/images/nervezynq.fw -d /tmp/fwchk
grep -c -a <property> /tmp/fwchk/data/zynq-libresdr.dtb
```

**Kernel config or patches.** Edit `linux/nerves-zynq.fragment` or add a patch
to `linux/`. The artifact checksum changes, but Buildroot will not rebuild the
kernel on its own. Delete the kernel build directory in the build volume, then
build:

```sh
container volume list    # nerves_system_libresdr-<id>
container run --rm --volume nerves_system_libresdr-<id>:/home/nerves/project \
    ghcr.io/nerves-project/nerves_system_br:1.34.0 \
    rm -rf /home/nerves/project/build/linux-custom
MIX_TARGET=libresdr mix firmware
```

Then confirm the option in the built kernel before deploying (for example by
checking for a driver's probe message in `dmesg` after an OTA to one board).

**Kernel version.** Change `BR2_LINUX_KERNEL_CUSTOM_TARBALL_LOCATION` in
`nerves_defconfig`; the new version builds in a fresh directory. Re-check the
fragment's "must be off" section against the new version's Kconfig.
