# AGENTS.md — nervezynq

Nerves firmware for the LibreSDR (Zynq-7020, `xc7z020clg400-1`). Owns the whole
stack: GPL boot chain, BEAM userspace, a Rust port into the PL, and SPI control
of the AD9363 transceiver. No vendor blobs anywhere; the only closed thing in
the loop is the on-die BootROM. The boot chain (SPL + `ps7_init`, U-Boot) is
built from source by Buildroot; see `../nerves_system_libresdr/docs/boot-chain.md`.

## Reaching the board

Over the USB gadget (usb0). Each card is burned with `NERVES_SERIAL_NUMBER`;
`usb-gadget-init` hashes the serial into the gadget MAC and VintageNetDirect
derives a /30 from it, so every board has its own fixed subnet (see
`docs/RF_FIRST_LIGHT.md`, "Board identity changes").

| Serial | Hostname | Board (usb0) | Mac side |
|---|---|---|---|
| `lsdr-a` | `nerves-dr-a` | `172.31.104.113` | `172.31.104.114` |
| `lsdr-b` | `nerves-dr-b` | `172.31.29.213` | `172.31.29.214` |
| `lsdr-c` | `nerves-dr-c` | `172.31.194.197` | `172.31.194.198` |

```sh
ssh 172.31.194.197            # drops straight into IEx
```

The old single-board address `172.31.248.125` no longer applies.

After a hub replug the Mac sometimes leaves a board's ECM interface inactive or
drops it entirely while the board itself has booted fine (seen on dr-a and dr-c
2026-09-28). Replugging that one board's OTG cable fixes it. Check the debug
UART before assuming the board is hung.

## Build and deploy

```sh
MIX_TARGET=libresdr mix firmware
MIX_TARGET=libresdr ./upload.sh <board-ip>
```

The Nerves system (`../nerves_system_libresdr`, `nerves: [compile: true]`) is
built from source by Buildroot through Nerves' `container` build runner (Apple's
`container` CLI, not Docker or colima). Edits under the system's
`package_files` list change the artifact checksum and trigger an incremental
system build in the persistent `nerves_system_libresdr-<id>` container volume
(`container volume list`), usually one to three minutes.

Buildroot does not rebuild a package when files outside it change. Handled:
`dts/` (see below). Not handled: `uboot/patches/`, the U-Boot defconfig and
`linux/` fragments; remove that package's build directory in the volume first.
`../nerves_system_libresdr/docs/boot-chain.md`, "Stale-build traps", has the
commands.

Device-tree edits: `post-createfs.sh` compiles `zynq-libresdr.dtb` from
`dts/` on every system build (Buildroot's own DT build does not notice `dts/`
changes). Still verify a DT change in the built image rather than assuming:

```sh
unzip -o -q _build/libresdr_dev/nerves/images/nervezynq.fw -d /tmp/fwchk
grep -c -a <property> /tmp/fwchk/data/zynq-libresdr.dtb
```

`upload.sh` needs `MIX_TARGET` in the environment or it prints a confusing
"check your Nerves environment" message. The device reboots itself after fwup
finishes; give it ~90 s.

A/B failover is armed: `fwup.conf` sets `upgrade_available=1` and
`Nervezynq.FirmwareValidator` clears it 30 s after boot. Without that every OTA
reverts after bootlimit. The validator deliberately does **not** wait for
network — a down link would revert good firmware.

### Loading a bitstream

Bitstreams are loaded at runtime from Linux, never by U-Boot. **Never leave a
`.bit` on the FAT boot partition**: U-Boot programs it before Linux and a
transfer that never completes hangs the boot with no console
(`docs/journal/HANDOFF.md`, "SOLVED: the board did not boot because U-Boot was
programming the PL at boot").

After every boot the PL is blank, but the U-Boot SPL's `ps7_post_config` has
already enabled the PS/PL level shifters and released the fabric resets, so GP0
is live and any access would hang the CPU. Loading and PL access both go
through **oxibit** (`~/src/oxibit`, built into `priv/oxibit` by the Makefile):

```elixir
Nervezynq.PL.reload("/data/hp_dma_s1.bin")        # or Nervezynq.Fabric.load/2
Nervezynq.Fabric.status()                         # ready?, boundary, FCLKs, loaded config hash
Nervezynq.PL.reload("/data/hp_loop_s0.bin", aperture: false)   # design with no GP0 slave
```

`Nervezynq.Fabric` owns the one `oxibit port` process, which holds oxibit's
lock and refuses every aperture access unless hardware reads configured
(DevC STATUS `PSS_FST_CFG_B` and `PSS_GTS_CFG_B`) with the boundary open. The
file is checked (structure, CRC, IDCODE) before the PL is erased; a load that
fails after the erase leaves the PL blank and access refused. Details and the
measurements behind them: oxibit `docs/zynq7.md`.

Because the port holds the lock, the `oxibit` CLI on the board can run
`status` (and `inspect`/`verify`) alongside the app, but its `load`, `clear`,
`peek` and `poke` report "held by pid N". Use the Elixir API.

The radio bring-up is still `LsdrBringup.run/2`
(`designs/libresdr_radio/taps/serve/lsdr_bringup.exs` in ehdl), which loads
`hp_dma_s1.bin` through `Nervezynq.PL`.

oxibit stages bitstreams in the `pcap-readback` reservation (`0x3FC00000`,
4 MiB), which also holds the HP rings (`0x3FD00000`, `0x3FF00000`), the
readback buffer and `ocu_ingest`'s region. A load erases the PL first, so no
design is DMA-ing there during staging, and overwrites whatever was there.

### Watchdog

The SWDT (`cdns-wdt` at `0xF8005000`) is petted by nerves_heart (WDT timeout
10 s, VM timeout 30 s). The DT must carry `reset-on-timeout;` on `&watchdog0`:
without it the driver leaves `ZMR.RSTEN` clear, the timeout only raises an
interrupt (`Watchdog timed out. Internal reset not enabled`), and a CPU stalled
on an unanswered GP0/HP read stays hung until a power cycle. With it, `ZMR`
reads `0x33` and a hung bus read recovers by SWDT reset in about 37 s (10/10 on
dr-c, 2026-09-28). A system reset clears the PL configuration, so the bring-up
rule above applies after every watchdog reset too.

Quick check on a board:

```elixir
{:ok, p} = Nervezynq.PortWire.open(0xF8005000, 0x1000)
Nervezynq.PortWire.transact(p, {:read32, 0})   # expect {:ok, 0x33}
:heart.set_cmd(~c"disable_hw")                  # board should reset within ~10 s
```

## `Nervezynq.Fabric`

GenServer over `oxibit port`, a Rust port that owns loading and the PL
aperture and speaks `{:packet, 4}` on stdio (`Nervezynq.PortWire`). Every
other physical mapping (SLCR, DevC, DDR rings, PS GPIO) goes through
`PortWire.open/2`, i.e. `oxibit mem`, which refuses any range inside
M_AXI_GP0/GP1, so nothing but this port can reach the PL.

**Why a port, not a NIF.** `/dev/mem` cannot be read with `pread` here: ARM's
`valid_phys_addr_range()` restricts read/write to physical RAM, so a `pread` at
`0x4000_0000` returns `EFAULT`. `mmap` has no such restriction, so native code
is unavoidable. In a NIF an AXI access that decodes-but-errors arrives as
`SIGBUS` on a scheduler thread and takes the VM with it — no supervisor, no ssh,
no OTA, a field device that needs visiting. As a port it is one OS process.

A process boundary protects against **faults, not hangs**: a read into
unconfigured PL hangs the CPU regardless of who issued it. The guard is
therefore in the port and reads hardware before every access op; a refusal is
`{:error, {:pl_not_ready, why}}`. `Fabric.invalidate/0` and `authorise/0` are
deprecated no-ops kept so old scripts still run. INT_STS `PCFG_DONE` is **not**
a configured signal: it is a latched flag that the PROG_B pulse itself sets,
and gating on it hung dr-c once (oxibit `docs/zynq7.md`).

Cross-compile: the Makefile builds oxibit from `OXIBIT_DIR` (default
`../../oxibit`, i.e. `~/src/oxibit`) via `elixir_make`. The target triple is
`armv7-unknown-linux-gnueabihf` (ARMv7-A hardfloat + NEON, **not** the `arm-`
triple, which is ARMv6). `$CROSSCOMPILE` supplies the linker prefix. Needs
`rustup target add armv7-unknown-linux-gnueabihf` once. The Makefile also
deletes the retired `fabric_port` and `devcfg_load` from `priv/` on every build.

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
synthesis, place, route and bitstream reload.

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
- A card with firmware older than the `dr_mode = "peripheral"` DT change (e.g.
  `6fb5359d`) has `usb0` in OTG mode and can come up as a USB **host**
  (`ci_hdrc ci_hdrc.0: EHCI Host Controller` in dmesg, UDC `not attached`). It
  boots, but has no USB network, no cable or port swap helps, and it cannot be
  reached for an OTA. Update it with the card-reader path in
  `../nerves_system_libresdr/docs/boot-chain.md` (dr-b, 2026-09-28). All three
  boards are past this.

## Known-unfixed

- `zynq: allow a raw MMC environment when booting from SD`
  (`uboot/patches/0003`) is upstreamable and not yet sent.
- Ethernet negotiates 100 Mbps on a gigabit RTL8211E. Never investigated.
- `rootfs_overlay/etc/erlinit.config` sets `-c ttyGS0` (the USB ACM gadget),
  which does not exist yet when erlinit starts: boot logs `error setting
  controlling terminal: /dev/ttyGS0`. IEx is reachable over ssh and on the
  debug UART regardless. Pick one console and make the config say so.
