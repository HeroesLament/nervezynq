# AGENTS.md — nervezynq

Nerves firmware for the LibreSDR (Zynq-7020, `xc7z020clg400-1`). Owns the whole
stack: GPL boot chain, BEAM userspace, a Rust port into the PL, and SPI control
of the AD9363 transceiver. No vendor blobs anywhere — the only closed thing in
the loop is the on-die BootROM.

## Reaching the board

**usb0 at `172.31.248.125`** — static, reliable, and currently the only path.
eth0 has been down for a while; when it worked it took a fresh DHCP lease on
every reboot, so `dns-sd -t 6 -G v4 nerves-0000.local` was how you found it.

```sh
ssh 172.31.248.125            # drops straight into IEx
```

## Build and deploy

```sh
MIX_TARGET=libresdr mix firmware
MIX_TARGET=libresdr ./upload.sh 172.31.248.125
```

`upload.sh` needs `MIX_TARGET` in the environment or it prints a confusing
"check your Nerves environment" message. The device reboots itself after fwup
finishes; give it ~90 s.

A/B failover is armed: `fwup.conf` sets `upgrade_available=1` and
`Nervezynq.FirmwareValidator` clears it 30 s after boot. Without that every OTA
reverts after bootlimit. The validator deliberately does **not** wait for
network — a down link would revert good firmware.

### Deploying a bitstream (separate from firmware)

The PL bitstream lives on the FAT boot partition and is loaded by u-boot
(`fpga loadb`) before Linux starts. Linux's `fpga_manager` only reports state.

```sh
scp top.bit 172.31.248.125:/root/libresdr.bit
```
```elixir
cmd("mount -o remount,rw /mnt/boot && cp /root/libresdr.bit /mnt/boot/ && \
     ls -l /mnt/boot/libresdr.bit; mount -o remount,ro /mnt/boot")
Nerves.Runtime.reboot()
```

There is no `sync` in this busybox. A reboot is required — the bitstream is only
read at boot.

## `Nervezynq.Fabric`

GenServer over `native/fabric`, a Rust port that mmaps the PL aperture and
speaks `{:packet, 4}` on stdio.

**Why a port, not a NIF.** `/dev/mem` cannot be read with `pread` here: ARM's
`valid_phys_addr_range()` restricts read/write to physical RAM, so a `pread` at
`0x4000_0000` returns `EFAULT`. `mmap` has no such restriction, so native code
is unavoidable. In a NIF an AXI access that decodes-but-errors arrives as
`SIGBUS` on a scheduler thread and takes the VM with it — no supervisor, no ssh,
no OTA, a field device that needs visiting. As a port it is one OS process.

The port protects against **faults, not hangs**: a read into unconfigured PL
hangs the CPU regardless of who issued it. Hence the `fpga0/state` guard on
every call, cached once it reads `operating`. **If anything ever gains the
ability to reload a bitstream at runtime, that cache must be invalidated.**

Cross-compile: `native/fabric` builds via `elixir_make`. The target triple is
`armv7-unknown-linux-gnueabihf` (ARMv7-A hardfloat + NEON — **not** the `arm-`
triple, which is ARMv6). `$CROSSCOMPILE` supplies the linker prefix. Needs
`rustup target add armv7-unknown-linux-gnueabihf` once.

### Register map (matches `Hw.AXI4Lite.Slave`)

| Offset | Name | Notes |
|--------|------|-------|
| 0x00 | MAGIC | `0x45484431` "EHD1" |
| 0x04 | VERSION | `0x00010000` |
| 0x08 | SCRATCH | RW |
| 0x0C–0x18 | CTRL0–3 | RW, driven into the fabric |
| 0x1C–0x28 | STATUS0–3 | RO, sampled from the fabric |

On the `libresdr_radio` design:

- `STATUS0` — SPI: `[7:0]` last byte in, `[8]` done toggle, `[9]` tx_ready
- `STATUS1` — `[23:0]` fabric heartbeat on the AXI clock
- `STATUS2` — `[23:0]` DATA_CLK/512 edge count
- `STATUS3` — `[11:0]` last captured LVDS sample word, `[13:12]` RX_FRAME

`STATUS1` and `STATUS2` are **different clocks with different failure modes**.
Two reads returning different heartbeats prove the fabric clock runs; two
returning different `STATUS2` values prove the transceiver's does. From
userspace a dead one looks exactly like a broken bus.

## `Nervezynq.AD9363`

SPI control composed in Elixir on the fabric's byte pipe. The fabric moves one
byte with a chip-select hold bit and knows nothing about the command grammar —
that is deliberate, so a framing mistake costs a module reload rather than a
synthesis, place, route, bitstream and reboot cycle.

```elixir
AD9363.bring_up()
{:ok, %{locked: true, overflow_reg: 128, xo_bypass: true,
        integer: 24, fract: 1203241, icp: 4}}
```

That is reset → bias → reference clock path → BBPLL lock, and it gets DATA_CLK
to **7.694 MHz**, measured via `STATUS2`.

### SPI framing — from ADI's driver, not from memory

`~/src/no-OS/drivers/rf-transceiver/ad9361/ad9361.h`:

```c
#define AD_READ    (0 << 15)
#define AD_WRITE   (1 << 15)
#define AD_CNT(x)  ((((x) - 1) & 0x7) << 12)
#define AD_ADDR(x) ((x) & 0x3FF)
```

Address is **10 bits, not 13**. Count occupies **bits 14:12**.

**Never clock more than 24 clocks for a single-byte access.** A 32-clock
transaction where the device expects 24 desynchronises the AD9363's SPI state
machine; every subsequent read returns zeros and only a RESETB pulse recovers
it. It presents as a dead chip. This cost real time once already.

`Hw.SPI.Master` needs `MISO_SAMPLE_TRAILING: 1` for this device. SPI "mode 0"
pins down when the master drives and samples but not when the slave updates:
an MCP2515 drives MISO on the falling edge, the AD936x on the **rising** edge.
Sampling as SCK rises reads one bit early — a coherent, plausible stream shifted
one place, which is why it survives a casual look. Product ID read `0x85` where
`0x0A` was expected, and `0x85 << 1 == 0x0A`.

### What was missing when the BBPLL would not lock

Two omissions, and the second mattered more:

- `RX_REF_RESET_BAR` / `TX_REF_RESET_BAR` (`REG_REF_DIVIDE_CONFIG_1/2`, 0x2AB /
  0x2AC) hold the reference dividers in reset from power-on.
- `REG_CLOCK_ENABLE` (0x009) carries `BBPLL_ENABLE`. **The PLL is powered down
  until asked.** Writing a correct frequency word into a disabled PLL succeeds
  at every write, verifies on readback, and locks nothing.

`xo_bypass: true` is correct for this board: the 40 MHz VCTCXO feeds the XTAL
pins as an external clock rather than as a bare crystal driven by the internal
DCXO. `bring_up(:auto)` tries both and reports which locked — guessing wrong is
not destructive, so trying beats reasoning from the schematic.

## Board facts worth not rediscovering

- Transceiver is an **AD9363, 2R2T** — RX1/RX2, TX1/TX2 all populated, so 2x2
  MIMO is physically possible. (An AD9364 would be 1R1T and would rule it out.)
- Front end is `TCM1-63AX+` wideband transformers — no band-limiting SAW, so
  sub-1 GHz passes.
- Every AD9363 signal is in **bank 34**, VCCO **2.5 V** (the transceiver's
  `VDD_INTERFACE`). Single-ended control lines are `LVCMOS25`, not 3.3 V — a
  bank has one VCCO and the LVDS pairs need 2.5 V.
- SPI goes to **PL pins**, not PS MIO: `R14` CLK, `P15` DI, `R19` DO, `P18` ENB,
  `N17` RESETB, `R18` ENABLE, `P14` TXNRX, `P16` EN_AGC. No EMIO needed.
- 40 MHz VCTCXO with a tuning DAC on `VCTCXO_VFC` — the reference is trimmable,
  which matters for 802.11 frequency accuracy later.
- `RX_D1_N` is **V18** by inference, not by direct schematic read. pdftotext
  lost that net name and `W17` (the obvious guess) does not exist on clg400.
  Worth an eyeball before trusting samples from that lane.

## Known-unfixed

- **Nerves artifact checksums do not cover DTS edits.** Editing
  `nerves_system_libresdr/dts/xilinx/zynq-libresdr.dts` does not invalidate the
  cached artifact, so `mix firmware` silently ships an old DTB. Worked around
  once by patching the DTB inside `~/.nerves/artifacts/...`.
- u-boot `lib/initcall.c` still carries bring-up instrumentation writing to DDR
  `0x0F000000`. Remove or `CONFIG_`-guard before publishing.
- u-boot `board/xilinx/zynq/board.c` has a local fix returning `ENVL_MMC` when
  `CONFIG_ENV_IS_IN_MMC` is set. Upstreamable — raw-MMC env is currently
  unreachable on any Zynq booting from SD.
- Ethernet negotiates 100 Mbps on a gigabit RTL8211E. Never investigated.
