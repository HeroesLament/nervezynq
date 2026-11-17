# nervezynq

Nerves firmware for the **LibreSDR** — a software-defined radio built on a
Xilinx Zynq-7020 (`xc7z020clg400-1`) with an Analog Devices AD9363 transceiver.

The point of this project is that the whole stack is open. Elixir/BEAM
userspace controls the radio; a Rust port maps the programmable-logic (PL)
aperture; the PL bitstream is built with the open FPGA toolchain
(openXC7 / nextpnr / Project X-Ray), not vendor tools; the boot chain (U-Boot
SPL with the board's `ps7_init`, then U-Boot) and the kernel are built from
source by Buildroot. The only closed component anywhere in the loop is the
on-die Zynq BootROM.

> Status: **research, in progress, and up on silicon.** The receive path works
> — tune, gain, and snapshot IQ capture are proven on a real board, decoding
> the AD9363's known-answer BIST tone to the textbook result. It is *not* yet
> lab-calibrated (a DC-offset term is present by design), *not* yet streaming
> (snapshot capture only; DMA streaming is the current milestone), and has
> *no* transmit path yet. See `docs/SDR_V1.md` for exactly what is and isn't
> proven, and `docs/STREAM_RX_HANDOFF.md` for the streaming work.

## What's here

| Path | What it is |
|------|------------|
| `nervezynq/` | The Nerves application: AD9363 SPI bring-up, LVDS capture, the 2R2T MIMO decode, `Nervezynq.Fabric` over oxibit (`~/src/oxibit`, guarded PL loading and access), and the `Nervezynq.SDR` driver facade (`scripts/sdr.exs`). |
| `nerves_system_libresdr/` | The custom Nerves system for this board: Buildroot config, U-Boot/SPL patches, kernel config, device tree, fwup. Start with its `README.md`. Retains its own upstream licenses under `LICENSES/`. |
| `scope/` | `NzScope` — a wxWidgets/OpenGL waterfall + spectrum GUI (via [wx_mvu](https://github.com/HeroesLament/wx_mvu)) that visualizes the SDR's live FFT over a small TCP tap. |
| `patches-nextpnr/` | Fixes to nextpnr-xilinx's MMCM/PLL handling needed to build this design. |
| `openocd/` | OpenOCD config for JTAG bring-up of the board. |
| `docs/` | Design notes and session pass-ons; `docs/journal/` holds the raw lab logs. |

## Related repositories

- **[ehdl](https://github.com/HeroesLament/ehdl)** — the HDL. The fabric this
  firmware talks to (the AXI-lite register map in `regmap.exs`, the
  `libresdr_radio` design, the LVDS interface, the HP0 DMA path) is elaborated
  and emitted from ehdl. To understand the register offsets and the capture
  path referenced throughout this repo, read ehdl alongside it.
- **[wx_mvu](https://github.com/HeroesLament/wx_mvu)** — the MVU wxWidgets +
  OpenGL GUI framework the `scope/` app is built on.

## Hardware

- **SoC:** Zynq-7020, `xc7z020clg400-1` (dual Cortex-A9 + Artix-7 fabric).
- **Transceiver:** AD9363, 2R2T — RX1/RX2 and TX1/TX2 populated, so 2×2 MIMO
  is physically possible. Front end is wideband transformers (no band-limiting
  SAW), so sub-1 GHz passes. Tuning range is the AD9363's 325 MHz – 3.8 GHz.
- **Reference:** 40 MHz VCTCXO with a tuning DAC.

`nervezynq/AGENTS.md` is the working architecture guide — board wiring, the
SPI framing rules, the Fabric port rationale, and the hazards worth not
rediscovering. Start there if you're reading the code.

## Build & deploy

Requires the [Nerves](https://nerves-project.org) toolchain and Elixir/Erlang
per `.tool-versions`. The Rust port cross-compiles via `elixir_make`; you'll
need `rustup target add armv7-unknown-linux-gnueabihf` once.

```sh
cd nervezynq
export MIX_TARGET=libresdr
mix deps.get
mix firmware
./upload.sh <board-ip>        # OTA; the device reboots itself (~90 s)
```

The Nerves system, boot chain included, builds from source with Buildroot
through Nerves' `container` build runner (Apple's `container` CLI on macOS);
see `nerves_system_libresdr/README.md`. Fresh cards are burned with a per-board
serial (`NERVES_SERIAL_NUMBER=lsdr-x fwup ... -t complete`), which sets the
hostname and the board's `usb0` address.

PL bitstreams are loaded at runtime from Linux, never by U-Boot from the boot
partition, and the first load after every boot must be the documented bring-up.
See `nervezynq/AGENTS.md` ("Loading a bitstream", "Watchdog").

Running the desktop waterfall GUI against a live board is covered in
`scope/README.md`.

## Documentation

Board support (kernel, boot chain, Nerves system):

- `nerves_system_libresdr/README.md`: hardware, software versions, boot flow,
  SD layout, A/B updates, provisioning, building and deploying.
- `nerves_system_libresdr/docs/boot-chain.md`: the U-Boot/SPL build, its
  provenance and verification, deployment and recovery.
- `nerves_system_libresdr/docs/kernel.md`: kernel config and device tree, node
  by node, and how to change them safely.
- `nervezynq/AGENTS.md`: reaching the boards, loading bitstreams, the watchdog,
  the Fabric port, AD9363 bring-up, board facts.

Radio and fabric:

- `docs/SDR_V1.md` — the V1 receive driver: the API, what's measured, what's
  deliberately not there yet.
- `docs/STREAM_RX_HANDOFF.md` — the plan for gapless RX over HP0 DMA (V2).
- `docs/SILICON_MAP.md` — the accumulated map of what's proven on this silicon.
- `docs/HPDMA_SESSION.md` — first-light HP0 DMA into DDR, and the FCLK-throttle
  root cause.
- `docs/journal/` — raw session logs (`HANDOFF.md`, `STATE_DUMP.md`, …), kept
  for the reasoning trail. Unpolished by nature.

## License

The nervezynq-authored code is dual-licensed under either of

- MIT license (`LICENSE-MIT`)
- Apache License, Version 2.0 (`LICENSE-APACHE`)

at your option. Unless you explicitly state otherwise, any contribution you
submit for inclusion is dual-licensed as above, without additional terms.

**Vendored components keep their own licenses.** In particular
`nerves_system_libresdr/` bundles Buildroot/kernel/vendor material under the
licenses collected in `nerves_system_libresdr/LICENSES/` (GPL-2.0, CC-BY, TI
release terms, and others), and the GPL boot chain is GPL. The dual license
above applies to the original firmware code in this repository, not to those
third-party components.
