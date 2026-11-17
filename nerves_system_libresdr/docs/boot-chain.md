# LibreSDR boot chain

How the LibreSDR (Zynq-7020, `xc7z020clg400-1`, silicon rev 3.1) gets from
power-on to Linux, how every piece is built from source, how it was verified,
and how to deploy and recover it.

Status (2026-09-28): U-Boot 2025.01 and its SPL are built by Buildroot from the
patch series in `uboot/patches/`. Deployed and verified on all three boards:
dr-c and dr-a over the air, dr-b with a card reader (its old firmware had no USB
network; see "Card-reader path").

## Boot flow

```
BootROM (on-die, closed)
  reads BOOT.BIN from the SD card's FAT partition, copies it to OCM, jumps in
    |
U-Boot SPL (BOOT.BIN)
  ps7_init: MIO, PLLs, clocks, DDR3, peripherals; ps7_post_config
  loads u-boot.img (legacy image) from FAT into DDR
    |
U-Boot proper (u-boot.img)
  loads the environment from raw MMC (block 2048, 128 KiB)
  bootcmd from uboot/uboot.env: A/B slot choice, bootcount, revert
  loads uImage.<slot> and zynq-libresdr.<slot>.dtb from FAT, bootm
    |
Linux 6.12 + Nerves (erlinit, nerves_heart, the BEAM)
```

`ps7_post_config` turns the PS/PL level shifters on and releases the fabric
resets, so from here on M_AXI_GP0 is live while the PL is still blank. No
bitstream is loaded at boot. See `nervezynq/AGENTS.md`, "Loading a bitstream".

## What is built from where

| Piece | Source | Built by |
|---|---|---|
| SPL + `ps7_init` (`BOOT.BIN`) | U-Boot 2025.01 + `uboot/patches/0001..0004` | Buildroot `BR2_TARGET_UBOOT_SPL`, `spl/boot.bin` |
| U-Boot proper (`u-boot.img`) | same tree | Buildroot `BR2_TARGET_UBOOT_FORMAT_IMG` |
| U-Boot environment (`uboot-env.bin`) | `uboot/uboot.env` | `mkenvimage` in `post-createfs.sh` |
| Linux DTB (`zynq-libresdr.dtb`) | `dts/xilinx/zynq-libresdr.dts` | cpp + dtc in `post-createfs.sh` (see below) |
| Kernel (`uImage`) | linux 6.12.34 + `linux/` | Buildroot, `mkimage` in `post-createfs.sh` |

The Buildroot options are the U-Boot block at the end of `nerves_defconfig`.
`post-createfs.sh` copies `$BINARIES_DIR/boot.bin` to `BOOT.BIN`, the name the
BootROM looks for.

## The U-Boot patch series

Four patches on top of the v2025.01 tag, kept in `uboot/patches/` and applied by
Buildroot (`BR2_TARGET_UBOOT_PATCH`). They were written as git commits, so the
series can be regenerated with `git format-patch v2025.01..` from a tree that
has them applied.

1. **`ARM: dts: zynq: add LibreSDR board`**: `arch/arm/dts/zynq-libresdr.dts`:
   `zynq-7000.dtsi` plus UART0 (console), SD0 (boot and env), QSPI, 1 GB DDR,
   50 MHz PS_CLK, `fclk-enable = <0xf>`. Distinct from the Linux DT in `dts/`.
2. **`zynq: add LibreSDR ps7_init`**: `board/xilinx/zynq/zynq-libresdr/ps7_init_gpl.c`,
   picked up because `CONFIG_DEFAULT_DEVICE_TREE="zynq-libresdr"` names the
   directory. One table set for every silicon revision, as Xilinx's generated
   code does for rev 3.0 and later.
3. **`zynq: allow a raw MMC environment when booting from SD`**: stock
   `env_get_location()` offers only FAT or ext4 for SD boot, so a raw-offset
   environment (the Nerves fwup layout) is `ENVL_NOWHERE` and U-Boot boots on
   its default environment. The patch returns `ENVL_MMC` first when
   `CONFIG_ENV_IS_IN_MMC` is set. Upstreamable.
4. **`configs: add zynq_libresdr_defconfig`**: derived from
   `xilinx_zynq_virt_defconfig`: this board's DT only; `ENV_IS_IN_MMC`,
   `ENV_OFFSET=0x100000`, `ENV_SIZE=0x20000` (fwup `UBOOT_ENV_OFFSET` 2048,
   `UBOOT_ENV_COUNT` 256); FAT/NAND/SPI-flash env off; `SPL_LOAD_FIT` off, so
   the SPL loads a legacy-format `u-boot.img`; `SPL_FPGA` kept.

The environment offset and size must match `fwup_include/fwup-common.conf`. If
either changes, change both.

## Provenance: how this was reconstructed

The boards booted from 2026-07-28 on a source-built U-Boot 2025.01 whose tree
was then lost (banner `U-Boot 2025.01-dirty (Jul 28 2026 - 15:11:43 +0000)`).
Those binaries are kept as `boot/BOOT.BIN.2026-07-28` and
`boot/u-boot.img.2026-07-28`, and everything here was checked against them.

- **U-Boot DT**: extracted from the DTB U-Boot appends to `u-boot.img` (and the
  SPL's, from `BOOT.BIN`), decompiled, rewritten as source.
- **ps7_init tables**: the vendor-FSBL tables in `ref/ps7/*.inc` were compared,
  op by op, with the tables embedded in the old SPL (U-Boot encoding: address
  with the opcode in bits 1:0, then mask/value words). All five match.
  `ps7_post_config` is not in `ref/ps7` and was taken from the old SPL: the
  stock Xilinx sequence (unlock, `LVL_SHFTR_EN <- 0xF`, `FPGA_RST_CTRL <- 0`,
  lock). The `.inc` extractor left two opcodes undecoded: `0x22` is Xilinx FSBL
  `EMIT_WRITE(addr, val)` and `0x52` is `EMIT_MASKDELAY(addr, mask)`.
- **Config**: `.config` options were recovered by diffing the string tables of
  old and new binaries until nothing but compiler fragments differed. That
  found `SPL_LOAD_FIT` off and `SPL_FPGA` on.

Verified for the build that shipped (Buildroot, Nerves GCC 15 toolchain):

| Check | Result |
|---|---|
| ps7 tables (pll, clock, ddr, mio, peripherals, post_config) | identical to the old SPL |
| SPL DTB, U-Boot DTB (decompiled) | identical |
| String tables | identical apart from compiler/layout fragments |
| Zynq boot header | valid, checksum OK, 101000 bytes (limit 192 KB) |
| `ps7_init` disassembly | 30 instructions, only calls are to `ps7_config` |

Hardware, dr-c, 2026-09-28: boots `U-Boot SPL 2025.01 (Jun 08 2026 - 20:20:00
+0000)` through to IEx; environment loads from MMC; SWDT reset boots cleanly;
A/B OTA works, including U-Boot `saveenv` to MMC and the validator committing
the new slot. The date in the banner is Buildroot's reproducible-build
timestamp, not the build time.

### The failure on the way (keep this in mind)

The first deployed build had a guard in `ps7_init()` that returned early unless
`ps7GetSiliconVersion() == PCW_SILICON_VERSION_3`. That constant is 2 (rev
3.0); these boards report `PS_VERSION = 3` (rev 3.1, `devcfg MCTRL[31:28]`).
The SPL skipped MIO/clock/DDR init and died before the UART came up: total
silence after `reboot: Restarting system`, and JTAG could not halt either core.
Data checks (tables, DTBs, strings) cannot catch control-flow bugs in front of
the data; the disassembly check above was added for that reason.

## Building

Nothing special beyond the normal firmware build:

```sh
cd nervezynq
MIX_TARGET=libresdr mix firmware
```

The system is built by Nerves' `container` build runner (Apple's `container`
CLI, Virtualization.framework), not Docker. The Buildroot output tree persists
in a container volume mounted at `/home/nerves/project`:

```sh
container volume list          # nerves_system_libresdr-<id> (+ -platform)
```

### Stale-build traps

Buildroot's per-package stamps do not track files that live outside the
package, so these edits change the Nerves artifact checksum, trigger a system
build, and still ship the OLD output unless handled:

- **`dts/`** (Linux DT): handled. `post-createfs.sh` compiles
  `zynq-libresdr.dtb` from `dts/` on every system build.
- **`uboot/patches/` or the U-Boot defconfig**: NOT handled automatically.
  Remove the U-Boot build directory first, then build:

  ```sh
  container run --rm \
      --volume nerves_system_libresdr-<id>:/home/nerves/project \
      ghcr.io/nerves-project/nerves_system_br:1.34.0 \
      rm -rf /home/nerves/project/build/uboot-2025.01
  MIX_TARGET=libresdr mix firmware
  ```

  Then confirm the change is in the build before deploying, e.g. by
  disassembling from the build volume:

  ```sh
  container run --rm --volume nerves_system_libresdr-<id>:/home/nerves/project \
      ghcr.io/nerves-project/nerves_system_br:1.34.0 sh -c \
      'cd /home/nerves/project && host/bin/armv7-nerves-linux-gnueabihf-objdump \
         -d build/uboot-2025.01/spl/u-boot-spl --disassemble=ps7_init'
  ```

- **`linux/` config fragments**: same stamp problem; remove
  `build/linux-custom` the same way.
- **Removing files from the rootfs** (a `rootfs_overlay/` file, or a package
  turned off in `nerves_defconfig`): Buildroot copies into `target/` but never
  deletes from it, so the removed files keep shipping. Delete them from
  `target/` in the build volume (a disabled package's
  `build/<pkg>-<ver>/.files-list.txt` lists what it installed), then build,
  then list the image that was actually built:

  ```sh
  container run --rm --volume nerves_system_libresdr-<id>:/home/nerves/project \
      ghcr.io/nerves-project/nerves_system_br:1.34.0 sh -c \
      'cd /home/nerves/project && host/bin/unsquashfs -l images/rootfs.squashfs'
  ```

## Deploying a new boot chain

`BOOT.BIN` and `u-boot.img` sit on the shared FAT partition, outside the A/B
slots. The normal OTA (`upload.sh`, fwup `upgrade.*`) never writes them, so it
cannot break the boot chain. Updating them is a separate, opt-in fwup task,
`bootloader` (see `fwup.conf`). It needs validated running firmware, writes both
files under temporary names, renames them into place only after both writes
succeed, and keeps the previous pair as `BOOT.BIN.prev` / `u-boot.img.prev`.

One board first, with its debug UART captured:

```sh
# copy the .fw to the board and run the task there
echo "put _build/libresdr_dev/nerves/images/nervezynq.fw /data/nervezynq.fw" \
    | sftp -b - <board-ip>
ssh <board-ip>
```
```elixir
System.cmd("fwup", ~w(-a -i /data/nervezynq.fw -t bootloader -d /dev/mmcblk0),
           stderr_to_stdout: true)
Nerves.Runtime.reboot()
```

Pass criteria, in order, on the UART:

1. `U-Boot SPL 2025.01 (...)` banner with the expected date, within a second.
2. `Loading Environment from MMC... Reading from MMC(0)... OK` (not
   `using default environment`).
3. `NERVES: slot <a|b>` and the kernel, then IEx.
4. `:heart.set_cmd(~c"disable_hw")` gives a clean SWDT reset through the new chain.
5. A normal `./upload.sh` OTA shows `Saving Environment to MMC... OK`, boots the
   other slot, and `Nerves.Runtime.KV` ends with `validated=1 upgrade_available=0`.

Only then roll it to the other boards. `ehdl/.scratch/np_new/rollout_bootloader.sh
<board-ip>` runs the whole sequence for a board without a UART: the bootloader
task, reboot, a hash check of the files on the card, and a normal OTA with
validation, stopping at the first failure.

### Card-reader path

For a board that cannot be reached over the network, run the same fwup tasks
against its card on the Mac. Order matters: `upgrade` clears
`nerves_fw_validated`, which `bootloader` requires, so the boot chain goes
first. fwup ejects the card after every write by default and macOS then
auto-mounts the FAT partition, so pass `-U --no-eject` when running more than
one task:

```sh
F=_build/libresdr_dev/nerves/images/nervezynq.fw
diskutil unmountDisk /dev/diskN
sudo fwup -a -U --no-eject -i $F -t bootloader -d /dev/rdiskN
sudo fwup -a -U --no-eject -i $F -t upgrade    -d /dev/rdiskN
# check: active slot flipped, upgrade_available=1, serial is the right board
sudo dd if=/dev/rdiskN bs=512 skip=2048 count=256 2>/dev/null \
    | LC_ALL=C tr '\0' '\n' \
    | LC_ALL=C grep -a -E '^nerves_serial_number|^nerves_fw_active|^upgrade_available'
diskutil eject /dev/diskN
```

`/data`, the serial number and the A/B history are untouched; the board
validates the new slot itself on first boot, or U-Boot falls back to the old
one.

## Recovery

If a board stays silent after a boot-chain update, it is not bricked; the
previous pair is on its FAT partition. Pull the card, and on the Mac:

```sh
B=/Volumes/BOOT
mv $B/BOOT.BIN $B/BOOT.BIN.bad
mv $B/u-boot.img $B/u-boot.img.bad
cp $B/BOOT.BIN.prev $B/BOOT.BIN
cp $B/u-boot.img.prev $B/u-boot.img
sync
diskutil eject /dev/diskN
```

macOS leaves `._*` AppleDouble files on the FAT partition; the BootROM only
looks for `BOOT.BIN` and ignores them. The 2026-07-28 binaries are also in
`boot/` as a last resort.

JTAG (`openocd -f openocd/libresdr.cfg`, FT4232H channel A) could not halt
either core with a dead SPL. `REBOOT_STATUS` (`0xF8000258`) holds the BootROM
error code if a halt is possible.
