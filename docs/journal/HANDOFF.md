# Handoff — LibreSDR / EHDL / HaLow

Written at the end of a long session, for whoever picks this up next.
The per-repo `AGENTS.md` files carry the durable facts; this is the *state* and
the *judgement calls*.

## The goal

2x2 MIMO 802.11ah (WiFi HaLow) on a LibreSDR, with the hardware described in
Elixir (EHDL), synthesised by openXC7, running on Nerves. No Vivado, no vendor
blobs.

## Where things actually stand

Working and proven on hardware:

- GPL boot chain — BootROM → SPL → u-boot → Linux, all built from source
- Nerves A/B OTA, validated, carrying a cross-compiled Rust port
- PL bitstream from Elixir via openXC7; AXI4-Lite control plane, reads *and*
  writes
- `Nervezynq.Fabric` — mmap port, guarded, supervised
- `Nervezynq.AD9363` — SPI control; product ID `0x0A` confirmed; **BBPLL locked**
- **DATA_CLK running at 7.694 MHz**, measured through the fabric
- LVDS receive front end *built* (`IBUFDS` + `IDDR` on clock, frame and 6
  lanes) — but **not receiving anything**. See the correction below.

Not started: any DSP, any 802.11, the TX path, DMA/bursts, the MAC.

The EHDL stdlib has UART, SPI, CAN, USB, AXI, CDC and a few Xilinx primitives.
**Zero DSP.** That whole tree is greenfield.

## Next three steps, in order

1. **Transcribe `ad9361_bist_prbs()`** — `~/src/no-OS/drivers/rf-transceiver/`
   `ad9361/ad9361.c` line 1176. `REG_BIST_CONFIG` = 0x3F4,
   `REG_BIST_AND_DATA_PORT_TEST_CONFIG` = 0x3F6, `BIST_ENABLE` = bit 0,
   `BIST_CTRL_POINT(x)` = bits 3:2.
2. **Read `STATUS3` against the expected PRBS and count errors.** This is the
   only way to settle whether the missing `DIFF_TERM` matters at these rates.
   If the error rate is bad, the fix is prjxray fuzzer work to characterise the
   on-die termination bits — a real upstream contribution, not a local hack.
3. **Clock chain dividers and data port config.** 7.694 MHz is presumably a
   reset default, not anything chosen. Programming the dividers makes `STATUS3`
   contain *meaningful* sample words rather than merely non-zero ones.

## The most important thing to internalise

Three separate bugs this session had the same shape: **the design elaborated,
validated, synthesised, placed, routed, and was wrong on silicon.**

- `defhw` calls inside `hdl_case` branches elaborated to nothing — registers
  declared, initialised, read, never assigned. Every write dropped.
- `Ops.Mux` was last-match-wins in emitted Verilog but first-match-wins in both
  simulators. A trailing catch-all clobbered every arm above it, in hardware
  only.
- `MAXIGP0RLAST` was documented as tied high and never wired. Reads never
  retired; everything else looked healthy.

Simulation passing means less here than it does almost anywhere else. When a
result *could* be produced by a broken path that happens to look plausible,
assert on emitted Verilog, or measure on hardware. `STATUS3` being non-zero
right now proves transitions are arriving, **not** that they are correct. Those
are different claims and this session confused them more than once.

## Judgement calls I made that you may want to revisit

- **Port, not NIF, for `/dev/mem`.** Fault isolation over latency. If sample
  streaming ever needs the round trip, `native/fabric` is one crate with the
  mmap core in `lib.rs` — add a `nif.rs` frontend rather than rewriting.
- **Elixir composes SPI transactions, fabric moves bytes.** Keeps protocol
  mistakes cheap. Worth preserving.
- **`SAME_EDGE` + an explicit Q1 delay flop** rather than waiting for upstream
  `SAME_EDGE_PIPELINED`. The delay is at top level, deletable in one place.
- **Four ctrl/status registers, not one.** Arbitrary; widen again when needed.
- **Kernel `ad9361` driver not used.** We own the SPI path. This is the "own
  the whole stack" premise, but note ADI's calibration sequences are long and
  reimplementing all of them is a genuine cost. Reconsider if it stalls.

## Strategy for the PHY, when you get there

HaLow is **802.11ac with every clock divided by ten**, and that is enormously
in your favour. 2 MHz channel = 64-point FFT, 40 µs symbols. At 100 MHz fabric
that is **4000 cycles per OFDM symbol**; a 64-point radix-2 FFT is 192
butterflies, so one time-multiplexed butterfly unit finishes in under 5% of the
budget. Nothing needs to be fast. openXC7's weak timing model mostly stops
mattering.

Same collapse at the radio interface: `DATA_CLK` ≈ 4 × Fs for 2R2T, so a
HaLow-appropriate 4 MSPS is ~16 MHz — 6% of what the AD9363 can do.

Three opinions I hold reasonably strongly:

- **Write the golden model in Elixir first.** The whole receive chain — sync,
  CFO, FFT, equalise, demap, Viterbi — as ordinary Elixir against captured IQ,
  until it decodes a real beacon. *Then* port block by block into EHDL with
  `Hw.Sim` diffing each block against the model. Building blocks first and
  integrating later is how DSP projects die.
- **Receive before transmit, against a commercial AP.** Independent ground
  truth. Build TX first and you validate against your own RX; two
  implementations sharing one misreading agree perfectly with each other and
  with nothing else.
- **Snapshot mode before DMA.** A BRAM capture buffer read out slowly over
  AXI-Lite needs no bursts and unblocks all offline DSP immediately.

Also: HaLow's SIFS is ~160 µs, ten times legacy. ACK generation still has to
live in fabric, but "hard real time in the PL, policy in the BEAM" is far more
plausible than it would be for 11n.

## Timeline

The user reckons a prototype within a month. I said multi-year for a full 2x2
PHY+MAC and I stand by that — but a receive-only, 1 MHz, MCS0, single-stream
decoder of one real beacon in a month is genuinely plausible, and that is the
right first milestone.

Bring-up went fast because bring-up is bounded: make the hardware do what the
datasheet says, unambiguous pass/fail. A receiver is "make maths work against a
noisy channel", where things half-work for weeks. Different animal. Don't read
the pace of the last twelve hours as predictive of the next phase.

## Environment

- Board: usb0 `172.31.248.125`. eth0 down.
- Firmware: `bar-silver`, slot B, validated.
- `mix test` in ehdl needs `ERL_FLAGS="+t 8000000"`; ~41 pre-existing failures.
- Bitstream builds need `--seed 2`.
- ADI reference: `~/src/no-OS` (sparse checkout, AD9361 tree only, 1.9 MB).
- Schematic: `~/src/ehdl/zynqsdr_rev5.pdf`.
- There is an `erl_crash.dump` in `~/src/ehdl/_to_delete/` — the device bridge
  cannot unlink files on mounted folders, so it needs deleting by hand.


## Correction (session 2) — the LVDS front end is not receiving

The previous handoff read `STATUS3` once, got `12224`, and recorded it as
"non-zero captured data". `12224` is `0x2FC0`: `frame_pair = 0b10`,
`sample_word = 0xFC0`. It is a constant, and it is the *specific* constant that
means nothing is toggling. 40,000 reads across five different AD9363 BIST
states returned `0xFC0` every single time — one distinct value out of 4096.

    rise_d0..d5 = 0.0   (every rising-edge capture, every lane, always 0)
    fall_d0..d5 = 1.0   (every falling-edge capture, every lane, always 1)

Three things were established, each by measurement rather than inference:

1. **The AD9363 came up in CMOS mode.** `REG_PARALLEL_PORT_CONF_3` read `0x04`
   — `SINGLE_PORT_MODE`, `LVDS_MODE` clear. The board is wired as seven LVDS
   pairs, so every `IBUFDS` was comparing two unrelated CMOS bus bits.
   `Nervezynq.AD9363.data_port_setup/1` now fixes this, verified by readback.

2. **Fixing it changed nothing.** `STATUS3` stayed at `0x2FC0` with `LVDS_MODE`
   set and confirmed.

3. **The data lanes are not driven at all.** Inverting `RX_FRAME`, `RX1`/`RX2`
   and `DATA_CLK` at the transceiver each left the captured word unchanged.
   Inverting `DATA_CLK` should swap Q1 and Q2 and produce `0x03F`. The only
   thing that preserves the relationship under a clock inversion is data that
   *is* the clock — so the undriven, unterminated pairs are picking up
   `DATA_CLK` by coupling.

So: `DATA_CLK` is genuinely running at 7.679 MHz, and `RX_FRAME` and
`RX_D[5:0]` are dead. The ENSM is not in a receive state and the RX signal path
is not enabled — `bring_up/1` stops after the BBPLL, and the `ENABLE` pin is
still low (`release_reset/0` writes `CTRL1 = 0x01`, RESETB only). Getting real
samples onto the bus needs a good deal more of ADI's `ad9361_setup()`: ENSM
config, RX path enable, the ADC, and the clock chain dividers.

**Note for the DIFF_TERM question.** That undriven pairs pick up an adjacent
clock this cleanly is weak evidence that the missing on-die termination does
matter — a properly terminated 100 ohm pair would resist that coupling far
better. Weak evidence, not a conclusion: it cannot be settled until there is
real driven data to measure.

### `STATUS3` cannot be read coherently, and never could

Independently of all the above: `sample_word` is a 12-bit register in the
`DATA_CLK` domain wired combinationally into the AXI-Lite read path, with no
synchroniser and no capture handshake. Compare `dclk_count`, which was reduced
to a single toggling bit before crossing for exactly this reason. Reads can tear
and are not consecutive samples, so a PRBS check, a decoder or any DSP is off
the table until the fabric grows a snapshot buffer. `mix hw.check`'s
`cdc_crossing` rule did not flag this, which is worth looking into.

`Nervezynq.LVDSProbe` is built around that limitation — per-bit one-fractions
labelled by lane and DDR edge, value histograms, and the response of both to a
commanded change. All order-free, all still meaningful through the tearing.


## Correction 2 (same session) — the fault is in the fabric, not the AD9363

The CMOS-mode finding above was real and worth fixing, but it was not the cause.
The receive path is now fully brought up and the transceiver is demonstrably
doing what it is told:

- `Nervezynq.AD9363.Clocks` computes ADI's divider chain for 4 MSPS and writes
  it; `Nervezynq.AD9363.ENSM` takes the state machine ALERT -> RX.
- `REG_STATE` reads `0x8` (RX). The ENSM is in a receive state.
- The clock chain predicts DATA_CLK = 4 x Fs = **16.000 MHz**. The fabric's
  independent edge counter measures **15.998 MHz**. Two entirely separate paths
  — ADI's divider arithmetic in Elixir, and a counter in the PL — agreeing to
  0.01%.

And `sample_word` did not move. Not approximately: **bit-identical `0xFC0`** at
7.679 MHz and at 15.996 MHz, across all five BIST states, 8000 reads each.

Two independent arguments now put the fault in the fabric:

1. **The clock doubled and not one captured bit changed.** Coupling is
   frequency-dependent and the six lanes have different trace lengths. Anything
   real on those pins — data, crosstalk, noise — would perturb *something*
   across a 2x change on seven pairs. Nothing moved.

2. **Forcing the data port to a static level changes nothing.** Setting
   `USE_DATA_PORT` with `DATA_PORT_HILOW` high and then low both leave `0xFC0`.
   A DC level on the pins cannot produce Q1=0 with Q2=1 — a static input must
   give `Q1 == Q2`. (Caveat: those two bit definitions come from the register
   name in ad9361.h; ADI's driver never writes them, so this test corroborates
   argument 1 rather than standing alone.)

Q1 constant 0 and Q2 constant 1, on all six lanes and on RX_FRAME, regardless of
input, is the signature of **the IDDR outputs not being driven by their input at
all**. That would be a fourth openXC7 gap alongside the two already documented
(`SAME_EDGE_PIPELINED` unsupported, `DIFF_TERM` silently ignored) — and it is
the same failure class as both: it builds clean and is wrong on silicon.

### Next step, and it needs no board

Do not touch the AD9363 again for this. Go at the fabric, and go at it the way
this repo has learned to:

1. Read the **emitted Verilog** for `libresdr_radio` and confirm the `IBUFDS`
   outputs actually reach the `IDDR` `D` inputs and that Q1/Q2 reach
   `rise_word`/`fall_word`. Elaboration silently dropping a connection is
   precisely bug #1 from the original handoff.
2. If the Verilog is right, read the **FASM** and check the `IDDR` sites are
   configured as `IDDR_2CLK`/`ISERDES` with the input path selected — and check
   whether nextpnr routed the `IBUFDS` output anywhere at all.
3. `Hw.Sim` will not catch this. Simulation was right for both previous bugs of
   this shape.

A plausible shortcut worth trying first: the `designs/lvds_spike/` toolchain
probe exists for exactly this and is currently marked "not for loading". Making
it loadable with a known static input would isolate the primitive from
everything else in the radio design.


## Correction 3 — diagnosed: the ILOGIC input flip-flop path

Built `libresdr_radio` through yosys and nextpnr and read the FASM. The
emitted Verilog is correct (`IBUFDS.O -> rx_dN_se -> IDDR.D`, `Q1/Q2` out, all
seven pairs, nothing dropped), so this is not the elaborator.

The fault is that **the ILOGIC combinatorial output works and the ILOGIC input
flip-flops do not**, because prjxray does not characterise the ILOGICE3 input
muxes for RIOI3 (2 of 14 documented; `IFFMUX`, `IMUX`, `D2OBYP_SEL`,
`D2OFFBYP_SEL`, `CLKINV`, `CLKBINV` all absent). `DATA_CLK` proves the IOB and
the differential receiver are fine — it has byte-identical IOB configuration to
the six data pairs and is received correctly. The only difference is that the
clock exits its ILOGIC combinatorially and the data exits through Q1/Q2.

Full detail is in `ehdl/AGENTS.md`. Two routes forward, and they are not
exclusive:

1. **Unblock now: DDR capture in fabric.** Two ordinary flops per lane, posedge
   and negedge on `data_clk`. Costs a clock domain and the characterised
   pad-to-register delay; at 16 MHz that is affordable. This is the only path to
   real captured samples that does not begin with fuzzer work, and it makes the
   whole DSP programme reachable.
2. **Fix upstream: write the prjxray ILOGIC mux fuzzer.** Real contribution,
   fixes `IDDR`/`ISERDES` for everyone on 7-series, and is the prerequisite for
   ever running this interface fast. Also the natural place to pick up
   `DIFF_TERM`, since that is the same fuzzer gap in the neighbouring tile.

Note the ordering consequence: the BRAM snapshot buffer and the PRBS/BER work
both sit behind whichever of these lands. Nothing downstream can be measured
until the capture path captures.


## Correction 4 — the Fabric guard is stale after a userspace reconfiguration

`Nervezynq.Fabric`'s moduledoc already said it:

> The state is cached once it reads `operating`, since nothing short of an
> explicit reconfiguration can move it back. **Anything that gains the ability
> to reload a bitstream at runtime must invalidate that cache.**

`native/fabric/src/devcfg.rs` is exactly that thing, and the first time it ran
and *failed*, the next `Fabric.read32/1` hung the CPU — the documented
unrecoverable Zynq hang, requiring a power cycle.

Two separate faults, both mine, both avoidable:

1. **`/sys/class/fpga_manager/fpga0/state` is not evidence.** It reports the
   kernel driver's last operation. A userspace PCAP load never touches it, so it
   still read `operating` while the PL was in whatever state a half-finished
   configuration leaves behind. The guard was answering a different question
   than the one being asked.
2. **A failed load is not a no-op.** `devcfg_load` pulses `PROG_B`, which *wipes
   the running design* before the first byte of the new one is sent. So a load
   that fails at any later step leaves the PL blank, not unchanged. There is no
   "try it and see" here.

Required before `devcfg_load` is used again:

- `Fabric` needs `invalidate/0`, and must refuse all access until something
  positively asserts the PL is configured.
- The only acceptable evidence is `devcfg_load` exiting 0, which it does only
  after observing `PCFG_DONE` from the hardware.
- On a failed load the Elixir side must treat the PL as unusable and *not* read
  the aperture, rather than falling back on the sysfs state.
- `devcfg_load` should reload a known-good bitstream on failure so the board is
  left usable.

### Why the load failed: cache coherency

`devcfg_load` completed the whole `PROG_B` / `PCFG_INIT` handshake and every DMA
transfer with no error flags, then timed out waiting for `PCFG_DONE`. The
configuration engine received bytes and did not accept them as a bitstream.

The likely cause is that the bitstream was still in dirty CPU cache lines. The
kernel driver calls `dma_map_sgtable(..., DMA_TO_DEVICE, 0)` before programming,
which performs a cache clean for exactly this reason; `devcfg_load` writes the
staging buffer with ordinary CPU stores and then hands physical addresses to a
DMA master that reads DDR behind the L2. It faithfully transferred whatever
happened to be in RAM.

Userspace on Cortex-A9 (ARMv7) cannot issue clean-to-PoC cache maintenance --
those operations are PL1-only, and the ARM `cacheflush` syscall only cleans to
PoU, which does not reach past L2. So the fix is to allocate the staging buffer
somewhere already coherent rather than to flush it:

- `/dev/dma_heap/*` if `CONFIG_DMABUF_HEAPS` is enabled (check; a CMA heap would
  also give physical contiguity and remove the pagemap walk entirely)
- `/dev/udmabuf` if `CONFIG_UDMABUF` is enabled
- failing both, a small kernel module, or a `reserved-memory` node in the DT
  mapped uncached through `/dev/mem`

Do not try mapping the same physical pages twice with different cacheability
attributes to dodge this. Mismatched memory attributes are architecturally
unpredictable on ARMv7 and would swap a reproducible failure for an
intermittent one.


## Live PL reconfiguration works — 271 ms, no vendor tools, no reboot

`native/fabric/src/devcfg.rs` -> `devcfg_load <bitstream.bin>` reconfigures the
PL from userspace by driving the DevC/PCAP block directly. Confirmed on
hardware: **`ok 271 ms`**, followed by a correct `magic` (0x45484431), a running
heartbeat, and a full AD9363 bring-up reaching ENSM RX with DATA_CLK predicted
16.000 MHz and measured 15.999 MHz.

That replaces a ~50 s write-to-boot-partition-and-reboot cycle, and it never
touches `/mnt/boot`, so an experimental bitstream can no longer stop the board
booting.

Every register offset, bit position and step is transcribed from mainline
`drivers/fpga/zynq-fpga.c` (`zynq_fpga_ops_write_init`, `zynq_step_dma`,
`zynq_fpga_ops_write_complete`). Several values would have been wrong if
reconstructed from memory: `PCAP_PR` is bit 27, `PCAP_MODE` is bit 26,
`PCFG_DONE` is INT_STS bit 2 (bit 12 is `D_P_DONE`), and the low bit of the DMA
source address is a *last transfer* marker rather than an address bit.

### The cache-coherency finding, and the outstanding debt

The first attempt completed the whole `PROG_B`/`PCFG_INIT` handshake and every
DMA transfer with no error flags, then timed out on `PCFG_DONE`. Adding a cache
eviction pass — and changing nothing else — made it succeed. So the cause is
confirmed: the DevC DMA reads DDR from behind the L2 and does not snoop, which
is exactly why the kernel driver calls `dma_map_sgtable(DMA_TO_DEVICE)` before
programming. Ours was DMAing stale RAM while the bitstream sat in dirty cache
lines.

**The current fix is a probe, not a fix.** Userspace on Cortex-A9 cannot issue
clean-to-PoC (PL1-only; ARM's `cacheflush` syscall only reaches PoU, which does
not get past L2), so `devcfg.rs` walks a 4 MB scratch buffer to force capacity
evictions. That is "probably works" and does not belong here permanently.

Neither easy replacement exists on this kernel — checked: `/dev/dma_heap`
ENOENT, `/dev/udmabuf` ENOENT, debugfs empty. The proper fix is a
`reserved-memory` node with `no-map`, mapped uncached through `/dev/mem`: writes
land straight in DDR, the buffer is physically contiguous, and both the pagemap
walk and the eviction hack disappear. That costs one DTB edit and one reboot,
which is far cheaper than a Nerves kernel rebuild for DMABUF heaps.

### Safety protocol — not optional

`devcfg_load` pulses `PROG_B`, which **wipes the running design before the first
byte of the new one is sent**. A load that fails at any later step leaves the PL
blank, and reading the AXI aperture then hangs the CPU unrecoverably. This
already cost one power cycle.

    Only a `devcfg_load` exit status of 0 authorises AXI access.

`/sys/class/fpga_manager/fpga0/state` is *not* evidence: it reports the kernel
driver's last operation and is untouched by a userspace load. `Fabric` still
needs `invalidate/0` plus a `Nervezynq.PL.reload/1` wrapper that gates access on
the exit status, so the rule is enforced by code rather than by discipline.
Until then: on a non-zero exit, reboot. Do not read the aperture.


## The hardware-oracle sweep rig is built. The oracle is not yet reliable.

`_fuzz/frames.py`, `_fuzz/gen_sweep.py` and `Nervezynq.Sweep` work end to end:
50 candidate bitstreams generated in 25 s, fetched by the board over usb0,
loaded in ~110 ms each, all 50 processed in under a minute. `Fabric.invalidate/0`
+ `authorise/0` + `Nervezynq.PL.reload/1` gate bus access on hardware-confirmed
`PCFG_DONE`, verified on hardware.

**But the run produced no valid measurements.** 48 of 50 candidates failed with
`{:error, {:ensm_timeout, [expected: :rx, got: :alert]}}`, and the 2 that got
through reported `dclk=3.65 MHz` where the clock chain predicts 16.000 -- so even
those were not measuring the thing the oracle assumes. Candidates 047-049 are
byte-identical to the unpatched baseline and failed identically, which proves
this is a bring-up-after-reload reliability problem and has nothing to do with
the candidate bits.

So **the IDDR question is still open.** Nothing in this run is evidence about the
ILOGIC mux encoding.

### Two bugs fixed getting this far, same root cause

`write_verify` was being used on registers whose bit 0 does not read back.
Measured:

    REG_CTRL (0x3DF):        0x01 -> 0x00,  0x03 -> 0x02,  0x0F -> 0x0E,  0x81 -> 0x80
                             (and after RESETB it reads 0x01)
    REG_INPUT_SELECT (0x004): 0x03 -> 0x02,  0x43 -> 0x42

Both are write-only enables. ADI writes both with a plain `ad9361_spi_write`.

**Where ADI uses a plain write, assume there is a reason.** Their driver reaches
for `ad9361_spi_writef` or an explicit readback wherever verification is safe, so
a bare `spi_write` is a signal rather than an oversight. Upgrading them to
verified writes looked like rigour and produced a failure indistinguishable from
a broken SPI path -- it cost a long detour through bitstream seeds,
place-and-route and cache coherency before the readback values (`expected: 3,
got: 2`) made the pattern obvious.

### A reporting bug worth remembering

`Sweep.run/2` originally printed "no single bit changed the oracle -- that is a
real result" after 48 of 50 candidates had failed to produce any measurement at
all. It now distinguishes valid from invalid samples and reports INCONCLUSIVE
when fewer than half succeeded. An absence of hits is only evidence when the
measurements actually happened, and a tool that cannot tell the difference will
eventually talk you into the wrong conclusion.

### Next, in order

1. **Make `Bringup.receive_path/2` reliable after a PL reload.** It reaches ALERT
   and stalls there. `TXNRX_SPI_CTRL` and `mask_synth_ready` are both already
   set, so the remaining suspects are ordering (ENSM_CONFIG_2 is written by
   `set_mode`, `mask_synth_ready` and `select_direction` in sequence -- read back
   between each and see which write does not stick) and settling time after
   reconfiguration.
2. **Make the oracle self-validating.** Treat a bring-up that does not land
   within a few percent of the predicted DATA_CLK as an invalid sample, not as a
   measurement. The two candidates that "succeeded" at 3.65 MHz would otherwise
   have been counted as real negatives.
3. Only then re-run the sweep.

Also note: I skipped a null control -- 50 candidates were generated and run
before ever testing an unpatched bitstream from the same flow. When everything
failed identically the first suspicion fell on the bit flips, then on my own
place-and-route. The null control is what identified it as neither. Generate and
test `baseline.bin` first, every time.


## Why the ENSM stalls at ALERT: POWER_DOWN_RX_SYNTH

Diagnosed by reading `ENSM_CONFIG_1` (0x014), `ENSM_CONFIG_2` (0x015) and
`REG_STATE` (0x017) between every step of `receive_path/2`.

Reads were verified trustworthy first -- `0x015` returns the same value six times
running, and interleaving reads of `0x037` (product ID, `0x0A`) and `0x014` does
not perturb it. So the values below are real.

    at ALERT, before forcing RX:   cfg1=0x09  cfg2=0x0C  state=0x5
    after writing FORCE_RX_ON:    cfg1=0x49  cfg2=0x48  state=0x5   (stuck)

`cfg2 = 0x48` has **bit 6 set: `POWER_DOWN_RX_SYNTH`**. The ENSM is correctly
refusing to enter RX because the receive synthesiser is powered down.

Clearing it by hand does not help — it comes straight back:

    writef(0x015, 0x60, 0)  ->  cfg2 = 0x08     (cleared)
    set_state(:rx)          ->  cfg2 = 0x48     (hardware set it again)

The hardware forces it because **the RX RF PLL has never been programmed.**
`ENSM.mask_synth_ready/1` masks synth *ready*, which is a different bit and a
different question from synth *powered down*; masking ready cannot help when the
synthesiser is off. `ad9361_setup()` powers the synths up as a side effect of
`ad9361_txrx_synth_cp_calib()` and `clk_prepare_enable(phy->clks[RX_RFPLL])`,
both of which the "skip the calibrations" shortcut omits.

**So reaching ENSM RX genuinely requires the RF PLL setup.** That shortcut is
dead. The earlier runs that did reach RX did so on leftover chip state from a
previous session, which is why it looked intermittent.

`ENABLE_RX_DATA_PORT_FOR_CAL` (`ENSM_CONFIG_1` bit 7) does run the receive data
port without entering RX, and `ENSM.set_state/2` already supports it. With it set
and a PRBS injected, DATA_CLK runs (8.001 MHz) but `STATUS3` is still a constant
`0xFC0` — which tells us nothing new, for the reason below.

## The oracle is circular, and that is the real problem

The sweep asks "did this bit fix the IDDR?" and answers it by reading captured
samples — through the IDDR. The instrument is the device under test. On top of
that, the signal it depends on requires most of `ad9361_setup()` before it can be
trusted (DATA_CLK reads 8.0 MHz here where the chain predicts 16.0, another
symptom of the same incompleteness).

That is why the sweep cannot produce clean results, and no amount of fixing
bring-up reliability changes it.

### The fix is to invert the dependency: build the fabric DDR capture FIRST

Replace `Hw.Xilinx.IDDR` with two ordinary fabric flops per lane, one on
`posedge data_clk` and one on `negedge`. The `IBUFDS` combinatorial path is
already proven working (it is how DATA_CLK gets in), so this needs no
undocumented bits and no fuzzer.

Then:

- If capture starts working, the IDDR diagnosis is confirmed on hardware and the
  whole DSP programme is unblocked — snapshot buffer, PRBS/BER, golden model.
- The fabric flops become a **known-good reference instrument**, so the IDDR can
  afterwards be fuzzed against a capture path that demonstrably works, instead of
  against nothing. The sweep rig stays exactly as built; only its oracle improves.
- Whether the AD9363 is really transmitting becomes answerable, which it is not
  today.

Do this before any more work on ENSM RX, the RF PLLs, or the bit search. It is
less work than any of them and it is the only one that removes the circularity.


## MILESTONE: the capture path works. `IDDR` diagnosis confirmed on hardware.

`designs/libresdr_radio` now captures DDR in fabric — two flops per lane, posedge
and negedge on `data_clk` — instead of `Hw.Xilinx.IDDR`. Built with `--seed 1`
(seed 2 fails to route the extra clock-inverter loads), loaded live in 110 ms.

Results, all from changing only the capture logic:

    captured word:  0xFC0 (constant, forever)  ->  0x659 (constant)
    rise_d0..d5  =  1,0,0,1,1,0
    fall_d0..d5  =  1,0,0,1,1,0      <- identical
    DATA_CLK     =  16.004 MHz       (predicted 16.000; was 8.0 before)

`rise == fall` is what a static input must produce. The `IDDR` gave rise=0 /
fall=1 on all seven pairs, which no DC level can produce. **So the IDDR really
was not connected to its pads, and the fabric capture really is sampling them.**
The clock chain also now lands on its predicted 16 MHz.

Also fixed in passing: `status3` was `{pad20, frame_pair, sample_word}` = 34 bits
assigned to a 32-bit register, working only because the emitter truncated the top
two. It is `pad18` now.

### What is still missing: the AD9363 is not driving the data lanes

`0x659` is constant, and it does not respond to `INVERT_DATA_BUS`,
`INVERT_RX1`/`INVERT_RX2` or `INVERT_RX_FRAME` — bits ADI documents and writes.
Inverting a signal that is not being driven does nothing, so the lanes are idle
and `0x659` is the undriven state of the pairs (per-pair bias resolving
differently, which is why it is a pattern rather than all-zeros or all-ones).

That is the same conclusion as `POWER_DOWN_RX_SYNTH` above, now reached with a
working instrument instead of a broken one: **the receive path needs the RF PLL
brought up before it will transmit samples.**

### Next, in order

1. **Transcribe the RX RF PLL path**: `ad9361_txrx_synth_cp_calib()` (ad9361.c:2859,
   58 lines) and `ad9361_rfpll_set_rate()` (7079, 57 lines), plus the
   `RX_REFCLK`/`RX_RFPLL` rate plumbing. That clears `POWER_DOWN_RX_SYNTH` and
   lets the ENSM reach RX. ~115 lines of C and the last thing between here and
   real samples.
2. Then the oracle is trustworthy, and the 50-bit sweep can run for real — with
   the fabric capture as the reference and the IDDR as the thing under test,
   which is the right way round.
3. Then the snapshot buffer, and the `DIFF_TERM` question finally becomes
   measurable — note the fabric capture makes termination effects *more* visible,
   not less, since it lacks the ILOGIC's characterised timing.


## MILESTONE: the LVDS receive path delivers real data. End to end, for the first time.

`Nervezynq.AD9363.RFPLL.synth_cp_calib/3` — 60 lines transcribed from
`ad9361_txrx_synth_cp_calib()` (ad9361.c:2859) — was the missing piece. The
dependency chain from `ad9361_setup()` looked like ~740 lines of C, but the thing
that actually powers the synthesisers up is one write inside the CP calibration:

    ad9361_spi_write(phy->spi, REG_ENSM_CONFIG_2, DUAL_SYNTH_MODE);

`ENSM_CONFIG_2 <- 0x04` clears both power-down bits, and the calibration around it
is straight register writes plus one status poll. Because the BIST injects at the
digital receive control point, downstream of the mixer, the LO does not need to be
*correct* — only powered. So `rfpll_set_rate`, the VCO dividers, the fractional
word, `fastlock_prepare` and the multi-byte SPI write are all still unwritten and
were not needed to get here.

Confirmed on hardware:

    ENSM state            : :rx
    DATA_CLK              : 15.998 MHz  (predicted 16.000)
    rx/tx_synth_powered_down : false
    rx VCO locked         : false        (expected -- LO never programmed)

And the capture, with a PRBS injected:

    distinct = 1476 / 4096 sample words
    rise_d0..d5 = 0.496 0.593 0.617 0.492 0.490 0.505
    fall_d0..d5 = 0.495 0.589 0.493 0.506 0.496 0.499

Ten of twelve captured bits sit at 0.49-0.51, which is what a PRBS must give.

### The commanded-response check, which is what makes it a measurement

    quiet          distinct 337   90% of mass in  96
    tone (Fs/32)   distinct 115   90% in  70     <- periodic: concentrated
    tone ch1 only  distinct  88   90% in  54
    tone ch2 only  distinct  83   90% in  54
    prbs           distinct 793   90% in 393     <- pseudorandom: spread

A period-32 tone occupies a small value set and a PRBS spreads. The ordering holds,
so the fabric is seeing the pattern the transceiver was *told* to send, not noise.
Compare the old state of this table: `distinct = 1` in every row, forever.

### Open questions this immediately raises — all now answerable

1. **`frame_pair` is a constant `3` in every state.** `RX_FRAME` appears stuck
   high. Without it there is no I/Q or channel alignment, so this blocks any real
   sample interpretation even though the data lanes work. First thing to chase.
2. **`rise_d1` and `rise_d2` are biased** (0.593, 0.617) while their neighbours
   sit at 0.49. Two lanes out of six, on the rising edge. **This is exactly the
   signature the missing `DIFF_TERM` would produce** -- marginal capture on
   specific traces -- and it is the first quantitative evidence bearing on that
   question, which has been open since session 1. Sweep `REG_RX_CLOCK_DATA_DELAY`
   (`ad9361_dig_tune` territory) and see whether the bias moves.
3. **The mask partition check still fails** (0.0 / 0.0, predicted ~1.0) and the two
   masked-tone states are nearly identical. So my reading of the BIST mask bits was
   wrong. Harmless -- ADI never writes them -- but the prediction in
   `LVDSProbe.states/0`'s doc should be corrected or removed.
4. `0xFFF` takes 27% of samples in the report's PRBS row where the clean run had
   no such concentration. The difference is that the report leaves channel masking
   set from the previous state. Worth confirming rather than assuming.

### Next, in order

1. `RX_FRAME` -- stuck high blocks alignment.
2. The BRAM snapshot buffer. Now genuinely worth building: there is real data to
   capture, and consecutive samples are what the PRBS fit and all DSP need.
   `STATUS3` remains an unsynchronised crossing, so single reads stay untrustworthy
   for anything order-dependent.
3. Berlekamp-Massey against a real capture -> the actual BER number -> the
   `DIFF_TERM` verdict, with the delay sweep as the lever.
4. The IDDR bit-sweep can now run with the fabric capture as a known-good
   reference, which was the whole point of building it that way round.


## MILESTONE: snapshot capture buffer works. Consecutive samples, with structure.

`designs/libresdr_radio` now has a 1024 x 14-bit capture buffer: write port on
`DATA_CLK`, read port on `AXI_CLK` (`memory :cap, ..., sync_read: :axi_clk`).
yosys infers **1 x RAMB18E1** — a real dual-port BRAM, not LUTs. Built with
`--seed 5` (each design revision has needed a different seed; treat it as a build
input). `LVDSProbe.capture/1` arms via a toggle, polls done, and reads out.

This retires the `STATUS3` CDC hole documented in `ehdl/AGENTS.md`: `STATUS3` now
carries the buffer's read port rather than the live `sample_word`, and readout
only happens after capture halts, so the write port is idle and the contents are
static. No bursts, no DMA, no coherency argument to get wrong.

### First real structure in the data

1024 consecutive words with a BIST PRBS injected, `distinct = 491`:

    3763, 1439, 3763, 2909, 3896, 2924, 3896, 1774, 2588, 1759, 2588, 3543, ...

Quantified over the whole capture:

    lag=2, idx%4==0:  equal 255/256   (99.6%)
    lag=2, idx%4==1:  equal   5/256
    lag=2, idx%4==2:  equal   0/255
    lag=2, idx%4==3:  equal  10/255
    lag=1 and lag=4:  ~0 for every phase

So the stream has a **period-4 frame in which slot 0 and slot 2 carry identical
values**, 255 times out of 256. That is consistent with 2R2T interleaving
(I1, Q1, I2, Q2) with both receive channels fed the same BIST pattern. Whatever
the exact slot mapping, it is a deterministic structure that asynchronous reads
could never have shown — the same data through the old path was just "573
distinct values".

### This unblocks the stuck RX_FRAME

`RX_FRAME` is still constant `3` across all 1024 captured words in level mode
(and it *is* driven — `INVERT_RX_FRAME` flips it to 0, and pulse mode makes it
vary; `R2T2_TIMING` changes nothing). That was going to block I/Q and channel
alignment.

It no longer does. **The period-4 signature identifies slot 0 unambiguously**
without the frame signal, because the 255/256 match rate on one phase class and
~0 on the others is an unmistakable alignment marker. So RX_FRAME drops from
blocker to open question.

### The 1/256 mismatch is the BER signal

255/256 rather than 256/256 on the matching phase, plus 5/256 and 10/256 where 0
is expected, is the first quantitative error-rate evidence available. It may be
real bit errors, or it may be capture-boundary artefacts. Distinguishing them is
exactly what the delay sweep is for — and it is where the `DIFF_TERM` question
finally gets answered. Note `rise_d1`/`rise_d2` were the biased lanes (0.59,
0.62 against 0.49 for their neighbours), so those are the ones to watch.

### Next

1. Sweep `REG_RX_CLOCK_DATA_DELAY` (`ad9361_dig_tune` territory) against the
   255/256 match rate and the per-lane bias. That produces an eye diagram in
   software and answers `DIFF_TERM`.
2. Berlekamp-Massey the captured bit stream to identify the PRBS polynomial and
   get a true BER, per the original plan — now actually possible.
3. RX_FRAME level mode: still unexplained, no longer urgent.
4. The IDDR bit-sweep, with the fabric capture as reference.


## ANSWERED: the missing DIFF_TERM does not limit this interface at 16 MHz

Open since session 1. openXC7 silently ignores `DIFF_TERM`, so the receive pairs
are unterminated, and the question was whether that eats the eye.

`LVDSProbe.eye_sweep/1` sweeps both fields of `REG_RX_CLOCK_DATA_DELAY`
(`DATA_CLK_DELAY` bits 7:4, `RX_DATA_DELAY` bits 3:0) and reports the fraction of
period-4 slots satisfying the `w[n] == w[n+2]` invariant. That is an eye diagram
measured in software, with no vendor tools and no ADI HDL PN checker.

    rows = DATA_CLK_DELAY, cols = RX_DATA_DELAY
           0   1   2   3   4   5   6   7   8   9  10  11  12  13  14  15
      0   99  98  97 100 100 100 100 100 100 100 100 100 100 100 100 100
      4   75  71  91  96  95  96  98 100 100 100 100 100 100 100 100 100
      8   65  77  84  79  80  76  90  96  98  95  96 100 100 100 100 100
     12   81  79  80  75  66  74  84  84  80  78  90  96  98  98  93 100
     15  100  96  87  82  73  73  74  65  82  83  74  83  84  94  98  98

    94/256 cells at 100%

A broad diagonal band, which is the right shape: only the *difference* between the
two delay fields matters, and row 15 wrapping back to 100 at column 0 confirms the
delay is modulo the clock period. That internal consistency is worth as much as
the result — it says the measurement is measuring timing.

Verified at several points inside the plateau:

    clk=0 data=0  (old default) : 253/256 slots   per-bit bias 0.412 - 0.507
    clk=0 data=10               : 256/256 slots   per-bit bias 0.492 - 0.504
    clk=2 data=12               : 256/256 slots   per-bit bias 0.473 - 0.479
    clk=4 data=11               : 256/256 slots   per-bit bias 0.516 - 0.519

**Zero errors, and all twelve captured bits within 0.012 of each other.**

So the conclusion, stated carefully: *at 16 MHz DATA_CLK, with this measurement,
the unterminated pairs have ample timing margin and the missing `DIFF_TERM` is not
limiting.* It may well matter at 61.44 MSPS (245 MHz DATA_CLK); nothing here speaks
to that. For HaLow at 4 MSPS there is enormous margin.

**This also retracts an earlier inference.** The per-lane bias reported when the
capture first worked — `rise_d1` 0.593 and `rise_d2` 0.617 against 0.49 for their
neighbours — was flagged as "exactly the signature the missing DIFF_TERM would
produce". It was not. It was sampling at the eye edge, because the delay default
was 0x00. At the eye centre the lanes are uniform. A per-lane asymmetry is not
evidence of a termination problem until the timing is centred.

`AD9363.data_port_setup/1` now defaults `rx_clk_data_delay` to 0x0A.

### A method note: the oracle had to be made phase-invariant

The first eye sweep produced scattered 100s and 0s that looked like a marginal
interface. The fault was the oracle: `match_rate/1` tested a fixed phase class
(`rem(i, 4) == 0`), but capture begins at an arbitrary point relative to the
transceiver's 4-sample frame, so which class carries the invariant shifts between
captures. Taking the best of all four made the measurement phase-invariant and
the eye appeared immediately. Worth remembering — a plausible-looking bad result
from a subtly wrong oracle is the most expensive kind.


## SOLVED: the sample format. `{current 6 bits, previous 6 bits}` from the same edge

Confirmed on hardware, `iex(45)`, `Fs/32` BIST tone, `rx_clk_data_delay = 0x0A`:

    %{samples: 255, mag_cv: 3.5e-4, mag_mean: 2047.8,
      deg_per_sample: -11.252, predicted_deg: 11.25}

`mag_cv = 3.5e-4` is a constant magnitude to within a third of one LSB, at
`2047.8` — full scale, which is what the BIST tone generator emits. The phase
advances `11.252` degrees per sample against a predicted `360/32 = 11.25`. Three
independent quantities, all landing. This is not a fit; a wrong reading does not
produce a constant magnitude by accident.

### The mapping

From ADI's `library/axi_ad9361/xilinx/axi_ad9361_lvds_if.v` (note the `xilinx/`
subdirectory — the path without it 404s):

    adc_data_p[23:12] <= {rx_data_1, rx_data_1_s};
    adc_data_p[11: 0] <= {rx_data_0, rx_data_0_s};

`rx_data_0` / `rx_data_1` are the two DDR edges, 6 bits each. `_s` is the same
edge's value registered from the *previous* DATA_CLK cycle. So:

**A 12-bit sample is `{current 6 bits, previous 6 bits} from one edge`, and the
two edges carry two different samples in parallel.** Each sample takes two
DATA_CLK cycles to arrive; both edges deliver one sample each per two cycles.
`DATA_CLK = 4 x Fs` therefore yields 4 twelve-bit values per `Fs` period = I and
Q for two channels, as the bit budget always said.

### What the design got wrong, and why it looked right

`designs/libresdr_radio/top.ex` builds `sample_word = {fall_q, rise_q}`: the top
six bits from the falling edge and the bottom six from the rising edge of the
*same* cycle. That is half of one sample glued to half of a different one. Every
12-bit word in every capture so far has been two half-samples spliced together.

It looked entirely plausible — 491 distinct values, a clean period-4 structure,
`slot0 == slot2` at 255/256, a 94-cell eye at 100% match. None of it decoded, and
nothing about the data said why. This is the project's recurring failure mode: a
wrong reading that is not obviously wrong. The eye sweep and the match-rate oracle
were measuring the *interface* correctly the whole time; only the semantics were
off, and no amount of interface characterisation could have surfaced that.

The earlier note "reversing the bit order within each 6-bit half halves the mean
delta (1787 -> 918)" was a red herring produced by the wrong metric. Retracted.
Bit order within a half is `{d5..d0}`, MSB first, exactly as emitted.

### The decode, and the sign

`Nervezynq.SampleFormat.decode/1` re-splits the mis-assembled words in software:

    rise = word &&& 0x3F        # bottom half, rising edge
    fall = word >>> 6 &&& 0x3F  # top half, falling edge
    I = pair(rise, phase: 1)    # {cur, prev} within the rise stream
    Q = pair(fall, phase: 0)    # ditto within the fall stream

The opposite pair-phase on the two streams is the one-cycle offset the design's
own realignment introduces; it is an artefact of the mis-assembly, not of the
AD9363. Results are then decimated by two because both receive channels carry the
same BIST pattern, so each value appears twice.

`deg_per_sample` comes out **negative**: `-11.252`. The magnitude and rate are
exact, so this is a convention, not an error — either the BIST tone at index 0 is
`-Fs/32`, or this `(I, Q)` assignment is the conjugate of ADI's. Do not "fix" it
by swapping I and Q on the strength of a sign; settle it against a known
off-centre real signal once the RF path is up, since a conjugated spectrum
mirrors every subsequent frequency estimate and will otherwise be discovered
during OFDM equalisation, at maximum cost.

### Consequence for `RX_FRAME`

`RX_FRAME` stuck at a constant `3` in level mode was downgraded from a blocker on
the strength of the period-4 signature. That signature came from mis-assembled
words. Since a sample now spans two DATA_CLK cycles, `RX_FRAME` in level mode
should be a *two-cycle* square wave, and a constant means it is either not
enabled or captured on the wrong edge. It is worth re-opening now that the frame
period is known to be 2, not 4 — pairing phase is currently inferred from the
data, which will not survive a real signal that lacks the BIST tone's structure.

### DONE in the fabric: `top4.v` / `pairfmt.bin`

`sample_word` is gone. `designs/libresdr_radio/top.ex` now carries `rise_q_d` and
`fall_q_d` and assembles two real samples per DATA_CLK cycle:

    sample_a = {rise_q, rise_q_d}   # 12 bits, rising edge
    sample_b = {fall_q, fall_q_d}   # 12 bits, falling edge
    cap_sample = {frame_pair, sample_b, sample_a}   # 26 bits
    status3    = {pad5, cap_done_sync, cap_word}    # 5 + 1 + 26 = 32

Both pair parities are written and the alignment is chosen at readout rather than
in fabric, deliberately: `RX_FRAME` is still unexplained, so there is no marker to
pick it in hardware, and guessing would bake a wrong choice into a bitstream
instead of leaving it visible in the data.

`LVDSProbe.capture/1` now masks 26 bits and polls the done flag at bit 26.
`capture_frame/1` shifts by 24. `capture_pairs/1` is new. `SampleFormat.decode2/1`
and `validate2/1` are the current path; `decode/1` and `validate/1` remain only
for re-reading pre-`top4` captures.

Verified on hardware over seven consecutive captures — three cached from before
the reload, four fresh:

    mag_cv 3.4e-4 .. 3.5e-4     mag_mean 2047.8
    deg_per_sample -11.252      predicted 11.25
    parity_b = parity_a - 1 in every single capture

That last line is the substantive finding rather than a fitting detail: **Q's
assembly window sits one DATA_CLK cycle earlier than I's.** The two DDR edges do
not carry I and Q of the same instant. See `Nervezynq.SampleFormat.decode2/1` for
the two intermediate wrong answers and why each was informative — a smooth
magnitude ripple at `2f` is a *fractional-sample skew*, not bit errors, and its
amplitude gives the skew directly.

### The build: 1 seed in 377

`--seed` was already known to be a build input rather than a constant. This
revision sharpened that considerably. The capture memory going 14 -> 26 bits wide
takes it from one RAMB18 to two, and after that:

    seeds 1..23   all fail
    seeds 24..400 exactly one succeeds -- seed 25

Every failure is the same: `Failed to route arc N of net 'axi_clk', from
BUFGCTRL_X0Y16/O to SITEWIRE/SLICE_X33..34,Y106..113/CLKINV_OUT`, preceded by
`routing clock 'axi_clk' ... failed to find a route using dedicated resources`
two or three times. A successful run shows zero of those lines. So the pass
criterion is visible in the log before the router even starts, and a sweep can
be cut short on it.

A run is ~3 seconds, so `seq 24 400 | xargs -P 4` costs about five minutes total
and is the right way to do this. But 1-in-377 is not seed luck any more, it is a
capacity wall: nextpnr-xilinx's global clock router cannot reliably reach that
slice region from `BUFGCTRL_X0Y16` once the design is this size. **Anything added
to the AXI clock domain from here should be expected to fail to route outright.**
That makes global clock routing the top vendor-free toolchain gap, ahead of
`-nocarry` — see `ehdl/AGENTS.md`.

### Still open on the receive interface

- `RX_FRAME` reads a constant `3` in level mode. Now more interesting, not less:
  a sample spans two DATA_CLK cycles, so level mode should give a *two-cycle*
  square wave. A constant means it is not enabled or is captured on the wrong
  edge. Alignment is currently inferred from the data, which will not survive a
  real signal that lacks the BIST tone's structure — so this has to be settled
  before any off-air decode.
- `deg_per_sample` is negative. Magnitude and rate are exact, so it is a
  convention: either tone index 0 is `-Fs/32` or this `(I, Q)` is ADI's
  conjugate. Do not swap I and Q on the strength of a sign. Settle it against a
  known off-centre real signal once the RF path is up; a conjugated spectrum
  mirrors every frequency estimate downstream and would otherwise surface during
  OFDM equalisation, at maximum cost.
- `LVDSProbe.match_rate/1` and `eye_sweep/1` score `w[n] == w[n+2]`, which was an
  artefact of splicing half-samples and does not hold now. `SampleFormat.tone_cv/1`
  replaces them and is a better oracle anyway — low is good where high was good.
  `eye_sweep` has not been re-run against it; `rx_clk_data_delay = 0x0A` is
  carried over from the old sweep and is giving `3.4e-4`, so it is not urgent.

## MILESTONE: the RX LO programs and locks. First real synthesiser control.

`Nervezynq.AD9363.RFPLL.set_lo/2` and `SynthLUT` transcribe
`ad9361_rfpll_int_set_rate` (ad9361.c:6848), `ad9361_calc_rfpll_int_divder`
(:6727), `ad9361_rfpll_vco_init` (:1744), `ad9361_to_refclk_scaler` (:6313) and
`ad9361_ref_div_sel` (:5329). Measured, commanding WiFi channel 1:

    reference : %{ref_clk_hz: 80000000, scaler_code: 3, lut_range: 80}
    lo        : %{requested_hz: 2412000000, actual_hz: 2412000000,
                  integer: 120, fract: 5033156, vco_div: 1,
                  vco_hz: 9648000000, lut_vco_mhz: 9631, vco_locked: true}

`actual_hz` is exact and `integer`/`fract` match a hand computation from ADI's
maths done independently of the code. The LO retunes and relocks on demand across
700–3500 MHz.

### Two things this fixed that were previously flagged and unfixed

- **The reference divider had never been programmed.** `RFPLL`'s own moduledoc
  said `synth_cp_calib/2` was passing 80 MHz "because that is what
  `ad9361_ref_div_sel` returns" while the divider itself was untouched, and that
  this was the first thing to suspect. `set_ref_clk/2` now programs it: scaler
  code 3 (mult 2, div 1) into `RX_REF_DIVIDER_MSB` (0x2AB[0]) and
  `RX_REF_DIVIDER_LSB` (0x2AC[7]). The reference really is 80 MHz now.
- **The SynthLUT block is chosen by reference frequency, not crystal.**
  `ad9361_rfvco_tableindex` keys off the RFPLL reference, so a 40 MHz XO with the
  doubler on needs the **80** block. Picking by crystal would have used the 40
  block, which at 9648 MHz differs in charge-pump current (33 vs 42) and two
  loop-filter components — a PLL that locks and is quietly noisy.

The tables were **generated, not typed**: 6 blocks x 53 rows x 13 integers parsed
out of `ad9361.c` by script, asserting 53 rows per block, 13 fields per row, and
the `vco_mhz` column identical across all six blocks and strictly descending.

Also added: `AD9363.write_multi/2`, the descending multi-byte SPI transaction the
frequency word requires. The synthesiser latches on the write to the lowest
address, so five single-byte writes would present four intermediate frequencies
to a live PLL.

## OPEN: we still cannot claim we are receiving RF

The LO locks. The ADC produces non-constant data. **That is not the same as
receiving a signal, and the band test says we are not — yet.**

Alignment-free RMS (each 12-bit field summed independently of pairing), 10
captures per frequency, ambient indoor environment:

     700 MHz  837        2412 MHz  554
    1000 MHz  573        2437 MHz  676
    1500 MHz  362        2462 MHz  809
    2000 MHz  671        2600 MHz  467
    3000 MHz  434        3500 MHz  635

If this were ambient WiFi, the three 2.4 GHz channels would stand clearly above
the out-of-band frequencies. They do not — 700 MHz reads higher than any of them.
So the varying level is most likely the receiver's own noise, and its frequency
dependence is a clue: **`ad9361_load_gt()` is not transcribed, and the RX gain
table is band-dependent.** An unloaded, band-wrong gain table is exactly what
produces a noise floor that changes with LO.

### Two false positives caught on the way, both worth remembering

1. **26x "burstiness" that was an artefact of our own decoder.**
   `SampleFormat.decode2/1` chooses its sample alignment by *minimising*
   `mag_cv`, the coefficient of variation of magnitude. That oracle was built for
   the constant-magnitude BIST tone and is actively wrong for anything else — for
   noise it picks whichever alignment looks most constant, and it produced
   impossible IQ pairs (Q pinned at -1 for three consecutive samples while I
   swung full scale) and a spurious 26x spread. Measuring RMS per 12-bit field,
   independent of alignment, gave 1.7x. **The BIST-tone alignment oracle must not
   be used on real signals.** This is the concrete form of the warning already in
   this file: alignment is inferred from the tone's structure and will not
   survive a real signal. `RX_FRAME` is the thing that should provide it, and
   `RX_FRAME` is still unexplained.
2. **A 1.7x bimodal level that looked like traffic** (≈590 quiet / ≈890 busy) and
   did not survive a control sweep across ten frequencies. Checking in-band
   against out-of-band cost one command and prevented recording a wrong result.

### Next, in order

1. `ad9361_load_gt()` — the RX gain table, band-selected (`TBL_1300_4000_MHZ` at
   2412 MHz). This is inside ADI's LO-set path and we skipped it. Most likely the
   single reason the noise floor tracks the LO.
2. `ad9361_gc_setup()` plus an actual manual gain index. With MGC and no index
   written, gain is whatever reset gives.
3. `ad9361_load_mixer_gm_subtable()` — mixer Gm table, currently unprogrammed.
4. `ad9361_rx_bb_analog_filter_calib()` then `ad9361_rx_adc_setup()`, in that
   order — the latter depends on `rxbbf_div` set by the former (ad9361.c:2495).
5. Only then re-run the band sweep. The oracle stays the same and it is a good
   one: in-band must exceed out-of-band, and the 2.4 GHz channels must respond to
   traffic.

### A process note about the board

Every module except `Nervezynq.AD9363` had been living in the BEAM as
`Code.compile_file` hot-loads from earlier sessions. The VM restarted and all of
it vanished — `ENSM`, `Clocks`, `RFPLL`, `Bringup`, `LVDSProbe`, `SampleFormat`,
`PL`. Firmware `safe-wild` (slot A) now contains the lot. **Build and upload
firmware rather than hot-loading**; `mix firmware && mix upload` is ~60 s and the
board is back in ~18 s.

## WRITTEN BUT UNTESTED: RX gain table, mixer Gm, manual gain control

`Nervezynq.AD9363.Gain` and `Nervezynq.AD9363.GainTable` transcribe
`ad9361_load_gt()` (ad9361.c:1432) and `ad9361_load_mixer_gm_subtable()` (:1591),
plus the `REG_AGC_CONFIG_1` gain-control mode field. `Bringup.rf_receive_path/3`
now does, in ADI's order: LO → mixer Gm sub-table → band gain table → MGC →
gain index. `Bringup.retune/2` reloads the gain table on retune, because a sweep
that crosses 1300 or 4000 MHz with a stale table is comparing two receivers.

**None of it has run on hardware.** The board went unreachable immediately after
the firmware upload that contained it — see below.

### Registers and protocol worth knowing

The gain table is a clocked indexed port, not a register block: address to 0x130,
three data words to 0x131/0x132/0x133, then toggle `WRITE_GAIN_TABLE` (0x04) with
`START_GAIN_TABLE_CLOCK` (0x02) in 0x137, then **two dummy writes to 0x134** which
ADI comments as "delay 3 ADCCLK/16 cycles" and "delay ~1u". Those are pacing, not
data, and they are reproduced rather than replaced with a sleep. The whole load is
bracketed by clock-start and clock-stop, with a clear-write step before the stop.

`RECEIVER_SELECT(x) = (x & 3) << 3`, `GT_RX1 = 1`, `GT_RX2 = 2`, so both = 3.
Manual index goes in 0x109 / 0x10C bits 6:0. Mode is 0x0FA bits 1:0 (RX1) and 3:2
(RX2), `RX_GAIN_CTL_MGC = 0`.

The Gm sub-table is written with a **descending** address — ADI walks `i` up while
`--addr` counts down from 16, so entry 0 lands at address 15 — and there is a bias
word of 0 per entry between the gain and control words that is easy to miss.

### The tables were generated, and the invariants caught a real error

693 gain bytes and 231 abs-gain values parsed from `ad9361.c` by script, asserting
3 blocks x 77 rows x 3 bytes, every byte in 0..255, every abs-gain inside `int8_t`,
and each band's abs-gain column monotonically increasing.

The first parse reported band 1's abs gain as `-3 .. 2300`, which is impossible for
an `int8_t` — it was reading the `/* 2300 MHz */` block comments as data. The
`int8_t` assert is what caught it. Strip C comments before parsing tables. A hand
transcription absorbs that error silently, and a wrong abs-gain column makes every
gain-in-dB request a lie.

Bands from `ad9361_adi_gt_info[]`, matched `(start < f) && (f <= end)`:
band 0 ≤1300 MHz (−1..73 dB), band 1 ≤4000 MHz (−3..71 dB), band 2 ≤6000 MHz
(−10..62 dB). 2412 MHz is band 1. Band 2 is unreachable on an AD9363 (3800 MHz max).

## BOARD DOWN — needs a power cycle

After `mix upload` wrote firmware to **partition B** and the board rebooted, it
never came back. Evidence gathered:

- `ping 172.31.248.125` — 100% loss, sustained over ~5 minutes of retries
- `arp -an` — `(172.31.248.125) at (incomplete) on en11`, so no ARP reply
- `system_profiler SPUSBDataType` — **no USB gadget present at all**
- `en11` on the host still shows `172.31.248.126` and `status: active`, which is a
  stale host-side interface, not evidence the board is alive

The USB device being absent means the board is not running far enough to bring up
the gadget. That needs a physical power cycle; it cannot be recovered from here.

**Recovery path if partition B does not boot:** partition A holds firmware
`safe-wild`, which was verified working this session — the whole LO-lock experiment
ran on it. The only difference in B is the `Gain`/`GainTable` modules and the
`rf_receive_path` changes, none of which run at boot. So a boot failure caused by
B's *contents* is unlikely on the face of it, and the cause is not established.
Do not assume the firmware is at fault without evidence; the board had also been
running for hours and had its USB link drop once earlier in the session.

## The gain table works. The gain-table hypothesis was wrong.

Retraction first: the "board down, needs a power cycle" note above was **wrong**.
The board was up the whole time. `mix upload` had brought `eth0` up
(192.168.217.57) and the usb0 gadget re-enumerated, leaving a stale `en11` on the
host still holding 172.31.248.126 — so pings went out a dead interface and ARP
never completed. `mix nerves.discover` found it immediately. **Use discovery, not
a failed ping, to decide whether the board is alive**; a stale host interface
looks exactly like a dead target.

### The gain table is confirmed loaded, by measurement

Running on firmware `motion-kid` (slot B). Read back from the chip after
`Gain.load/2`: `full_gain_table: true`, `max_index: 76`, both receivers
`:mgc` at index 15. And the decisive one — RMS against commanded gain at
2412 MHz:

    gain_db  idx    rms
          0    5    1.0
         10   15    1.0
         30   35    1.0
         50   55    1.0
         60   65  363.2
         70   75  552.2

**Gain now controls the datapath**, with a clean threshold where the noise floor
crosses one LSB. Before the table was loaded, gain was pinned at whatever reset
gave and RMS sat near 600 regardless of the index. That is a real measurement of a
real fix, and it retires the "gain is at reset" item.

### But it did not explain the missing band selectivity

Alignment-free RMS at 70 dB, gain table reloaded per band via `Bringup.retune/2`:

     700 MHz  787      2412 MHz  601
    1000 MHz  352      2437 MHz  659
    1500 MHz  293      2462 MHz  704
    2000 MHz  541      2500 MHz  613
    2350 MHz 1003      2600 MHz  572
                       3000 MHz  562
                       3500 MHz  593

Still no WiFi peak. **2350 MHz is the strongest point in the sweep** and 700 MHz
is second; the three WiFi channels are indistinguishable from 2500/2600/3000/3500.
Those two peaks look like internal spurs, not signals.

An RX-port sweep (`ENSM.rf_port_setup/1`, 0..7) measuring 2437 against 2600 gave
best ratios of 1.21 / 1.25 / 1.28 on ports 0, 3 and 4, and below 1.0 on ports 1,
2, 5 and 7. Absolute levels differ by port, so the switch does something — but no
port shows in-band energy standing above out-of-band.

So the hypothesis was clean, testable, and **false**. Loading the band gain table
was necessary and is not sufficient.

### Two candidates left, in order

1. **`ad9361_rx_adc_setup()` and `ad9361_rx_bb_analog_filter_calib()` are still
   not transcribed.** Without them the sigma-delta ADC is configured for the wrong
   clock and the baseband filter corner is arbitrary. If the ADC is mis-clocked,
   the samples need not represent the analogue input at all, which would explain a
   receiver that responds correctly to every *control* we exercise while showing
   no band selectivity. Transcribe in that order — `rx_adc_setup` depends on
   `rxbbf_div`, which `rx_bb_analog_filter_calib` sets (ad9361.c:2495).
2. **Is an antenna actually connected, and to which SMA?** This cannot be
   determined from software and has never been confirmed in any session. Ports 1,
   2, 5 and 7 read 250–400 while 0, 3 and 4 read 540–690, which is consistent with
   some inputs being unconnected — but that is a guess, and the schematic
   (`zynqsdr_rev5.pdf`) plus a look at the board would settle it in seconds.

Do not transcribe further calibration until (2) is answered. An unconnected
antenna reproduces every symptom above and no amount of ADC setup will fix it.

## RX analogue chain written; board unreachable after the `network-dry` upload

`Nervezynq.AD9363.RxAnalog` transcribes `ad9361_rx_bb_analog_filter_calib()`
(ad9361.c:2691), `ad9361_rx_tia_calib()` (:2633) and `ad9361_rx_adc_setup()`
(:2476), wired into `rf_receive_path` in ADI's required order. Antennas are
confirmed connected on TX1/RX1/TX2/RX2, so the "no antenna" hypothesis is dead.

### Why the order is a dependency

`rx_adc_setup` recovers the baseband bandwidth by inverting the filter
calibration's own formula, `BBBW = (BBPLL / rxbbf_div) * ln(2) / (1.4 * 2PI)`, and
ADI's comment says it outright: *"We assume ad9361_rx_bb_analog_filter_calib() is
always run prior"*. `rxbbf_div` is written by the filter calibration. Reversed,
the ADC gets forty coefficients computed for a bandwidth the filter does not have.

### C integer semantics had to be emulated, not translated

`rx_adc_setup` is mixed-width, mixed-signedness integer arithmetic feeding forty
registers. Two hazards, handled explicitly:

- **Unsigned wraparound is load-bearing.** `data[13]` starts from
  `-3 * (invrc_tconst_1e6 >> 1) + ...` and can go negative. In C that is
  `uint64_t`, so it wraps to a huge positive value and `min(255, tmp)` clamps to
  255. Elixir integers are arbitrary precision, so the same expression stays
  negative and `min/2` yields a **negative byte**. `u64/1` masks at each point C
  would have; `u32/1` where the C expression is 32-bit.
- `no_os_do_div` is truncating division on unsigned values. After masking it
  agrees with `div/2`; before masking it does not.

All forty bytes are range-checked against `0..255` before any is written, because
forty registers of silently-wrong ADC configuration is exactly this project's
recurring failure and the check is free.

### Board state — power cycle needed, and this time the evidence is good

After `mix upload` wrote firmware `network-dry` to **partition A** and the board
rebooted, it did not come back. Unlike the previous false alarm, this was checked
with the right tool:

    mix nerves.discover        -> "No devices found"
    ping 172.31.248.125        -> no reply, 6 polls over 90 s
    ping 192.168.217.57        -> no reply, 6 polls over 90 s
    dns-sd -B _ssh._tcp        -> no nerves host

Last time discovery found the board instantly while ping failed on a stale host
interface. This time discovery finds nothing, which is a genuinely different
result. **Do not diagnose board liveness with ping.**

Partition B holds `motion-kid`, which ran correctly this session — the gain-table
and LO measurements were taken on it. If A will not boot, B is the fallback.
Cause is again not established: `RxAnalog` does not run at boot, and nothing in
the diff touches networking.

### Also: scp to the board is broken

`scp` to the Nerves sftp server truncates at 11294 bytes and exits -1, so the
hot-load loop (`scp` + `Code.compile_file`) is unavailable for files larger than
that. `mix firmware && mix upload` is ~45 s and works. Use it.

## RX analogue chain runs. Still no signal — and the spectrum says why we were guessing.

`RxAnalog.setup/3` executed on firmware `network-dry`:

    filter : %{bb_bw_hz: 2000000, rxbbf_div: 41, bbbw_mhz: 2}
    tia    : %{cbbf_ff: 740, ctia_ff: 8666, r2346: 73200, regs: [224, 64, 26, 64, 26]}
    adc    : %{bb_bw_hz: 1968040, rxbbf_div: 41}

The filter calibration self-cleared, the TIA took the `CTIA_fF > 2920` branch, and
all forty ADC bytes validated. **The bandwidth round-trips**: 2.000 MHz commanded
-> `rxbbf_div` 41 -> 1.968 MHz recovered by `rx_adc_setup`'s inversion, the 1.6%
gap being the `DIV_ROUND_UP` quantisation of the divider. That is a real
self-consistency check on the transcription, not just "it ran".

Effect on the band sweep at 70 dB: the floor rose from ~600 to ~900 and went
**flatter than before** — 879, 859, 924, 901, 905, 919, 903, 901, 895, 890, 935
across 700–3500 MHz, with 2350 MHz still anomalous at 1243. A flat noise floor is
arguably the *correct* outcome of a properly configured ADC and gain table. There
is still no WiFi.

### The measurement that should have come first

RMS is one number. A 256-point DFT of the `sample_a` stream, DC removed, takes one
command and says what the data actually is:

    2437 MHz  dc=351.9   bins 15..96, no structure
    2350 MHz  dc= 51.0   bins 15..157, no structure
    3000 MHz  dc=370.5   bins 13..152, no structure

**Flat, white, no occupied band anywhere — plus a large DC offset.** At 2437 MHz,
RMS 900 decomposes as DC 352 and AC 828.

Two things follow. The DC term is expected — `ad9361_bb_dc_offset_calib` and
`ad9361_rf_dc_offset_calib` are not transcribed — and it is not the problem. The
problem is that the AC part is broadband noise at about -8 dBFS, roughly **28 dB
hotter than thermal noise through a 2 MHz baseband at 70 dB gain has any business
being**, and it carries no signal.

Doing this after four hypotheses instead of before them was the process error of
this stretch. A spectrum distinguishes "no signal", "saturated", "DC-dominated"
and "spur" in one shot; RMS distinguishes none of them.

### Stop transcribing. Get a positive control.

Eliminated by measurement so far: unloaded gain table (gain now moves the floor
with a clean LSB threshold), wrong band table, unconnected antenna (all four are
screwed on), uncalibrated BB filter and ADC. Every one of those was a reasonable
hypothesis and every one was wrong, and the next candidates — DC offset
calibration, RX quadrature — do not explain a missing signal either.

**There is still no measurement in this project that proves the RX analogue path
can receive anything at all.** Every positive result to date came from the digital
BIST, which is injected downstream of the mixer and ADC.

The board can supply its own control: TX1 and TX2 antennas are attached, centimetres
from RX1 and RX2. Bring up TX at 2437 MHz and the receiver should see it at an
enormous level. That is decisive in both directions:

- RX sees its own transmitter  -> the analogue chain works, and the problem is
  sensitivity, gain distribution or noise figure. Chase those.
- RX does not see it           -> the RX chain is dead somewhere between antenna
  and ADC, and no further calibration transcription will help. Chase power-down
  bits and the RX signal path instead.

Cheaper alternatives to check first, in case they avoid a full TX bring-up:
`REG_OBSERVE_CONFIG` (0x3F5) for an internal TX->RX loopback path, and whether the
AD9363 offers any analogue-domain injection. Both are worth ten minutes before
committing to transcribing the TX LO, attenuation and filter calibration.

## FOUND THE SHAPE OF THE FAULT: the noise does not come through the RX gain chain

The bisection that should have been run days ago, and the first result that
actually narrows things.

### Control: the digital path is perfect

With the RX BIST tone re-enabled, on the same firmware, same capture buffer, same
decode:

    ensm         : {:ok, %{state: :rx, raw: 8}}
    data_clk_mhz : 16.017
    BIST TONE    : mag_cv 3.4e-4, mag_mean 2047.8, deg_per_sample -11.252

Identical to the best result this project has ever produced. **LVDS interface,
capture buffer, sample assembly and format decoding are all proven good**, and the
fault is upstream of wherever the BIST tone is injected.

### The finding: 31 dB of gain buys 3.8 dB of noise

AC RMS (DC removed) against commanded RX gain at 2437 MHz:

    gain_db  idx    dc      ac_rms   ac_dB   step
         40   45   396.4     683.9    56.7
         45   50    33.1     813.9    58.2    1.5
         50   55    13.4     784.0    57.9   -0.3
         55   60   124.4     884.6    58.9    1.0
         60   65   187.8    1061.3    60.5    0.9
         64   69   250.0    1076.2    60.6    0.2
         68   73   234.7    1090.2    60.8    0.1
         71   76   246.5    1060.0    60.5   -0.1

**Noise entering the antenna and passing the gain chain must track gain 1:1.**
Thirty-one dB of commanded gain should multiply the output by 35. It multiplies it
by 1.55, and above 60 dB it stops responding entirely.

So the ~-5.7 dBFS of broadband noise filling the ADC is **not arriving through the
LNA, mixer and baseband amplifier**. It is injected at or after the ADC, or the
ADC is generating it. That also explains every failed experiment above at a
stroke: no gain table, band table, filter calibration or ADC coefficient set can
reveal a signal that is not reaching the converter.

### What is verified in silicon, so not the cause

- ADC coefficients read back as written: 0x200=0x00, 0x201=0x00, 0x207=0x22 (our
  `data[7]`=34), 0x21C=0x83 (our `data[28]`=131)
- TIA config 0x1DB=0xE0 as written; tune circuits correctly powered down
  (0x1E2=0x1E3=0x03) after the calibration
- Gain table loaded, `max_index` 76, MGC, index tracking commands
- LO locked, exact
- **RX FIR is bypassed** — `rx_fir_field: 0`, and ad9361.c:4685 sets that field to
  `!bypass_rx_fir`, so 0 means bypassed. Uninitialised FIR coefficients were a
  plausible suspect and are ruled out.

### The clock chain, and the leading suspect

    rx: [bbpll 1_024_000_000, adc 32_000_000, r2 16_000_000,
         r1 8_000_000, clkrf 4_000_000, rx_sampl 4_000_000]

**The ADC runs at 32 MHz** against a part whose ADC is specified up to 640 MHz.
That is at the very bottom of its range, and `rx_adc_setup`'s coefficients are
computed from `adc_sampl_freq` — `scaled_adc_clk_1e6` is 50000 and
`inv_scaled_adc_clk_1e3` is 20000 here, far from the values ADI's expressions were
shaped around. A sigma-delta modulator biased for the wrong clock can absolutely
sit there generating full-scale noise regardless of its input.

### Next, in order — and stop adding calibration code

1. **Raise the ADC clock.** One command, no new code: bring up at a higher sample
   rate so the ADC lands in the hundreds of MHz, and see whether the noise
   character changes. Constraint: `DATA_CLK = 4 x Fs`, and the fabric capture is
   characterised at 16 MHz, so 8 Msps (DATA_CLK 32 MHz) is the safe first step and
   anything above that risks confounding the result with interface errors. Check
   the BIST tone still decodes at the new rate *first* — that is the interface
   control, and it is cheap.
2. If the noise still ignores gain at a sane ADC clock, the RX signal path is not
   powered or not connected, and the answer is in the power-management ADI does in
   `ad9361_setup` that we have skipped — not in more calibration.
3. Only then TX-based over-the-air positive control.

Note `ad9361_bist_loopback` mode 1 is a **digital** TX->RX loopback
(`DATA_PORT_LOOP_TEST_ENABLE` in `REG_OBSERVE_CONFIG`), not an analogue one. It
would not test the mixer or ADC and is no use as a positive control here.

## ADC clock ruled out. And a gap in our own gain work.

Brought up at 8 Msps to double the ADC clock:

    planned rx chain : [bbpll 1_024_000_000, adc 64_000_000, r2 32_000_000,
                        r1 16_000_000, clkrf 8_000_000, rx_sampl 8_000_000]
    interface        : predicted 32.0 MHz, measured 31.997, agrees

### Bonus: the LVDS interface is good at 32 MHz DATA_CLK

Interface control before trusting anything else — BIST tone at the new rate:

    mag_cv 3.4e-4, mag_mean 2047.8, deg_per_sample -11.252, match_rate 255/255

Identical to 16 MHz, at the **same** `rx_clk_data_delay = 0x0A`. So the eye is
wider than the 16 MHz characterisation established, the fabric DDR capture handles
32 MHz without a re-centre, and 8 Msps is available whenever the datapath needs it.

### The result: doubling the ADC clock changed nothing

    ADC=64MHz  gain_db  ac_rms   ac_dB   step
                    30   825.9    58.3
                    40   799.4    58.1   -0.3
                    50   864.8    58.7    0.7
                    60  1045.3    60.4    1.4
                    68  1024.2    60.2   -0.1
                    71  1069.9    60.6    0.4

41 dB of commanded gain buys 2.3 dB — the same flat, gain-independent noise as at
32 MHz. **The ADC clock is not the cause.** That was the leading hypothesis and it
is dead.

### The gap: `ad9361_gc_setup` was never transcribed

Reading `ad9361_setup` end to end (ad9361.c:5348) against what we have:

    auxdac_setup            skipped     gpo_setup              skipped
    set_dcxo_tune           skipped     set_ref_clk_cycles     skipped
    auxadc_setup            skipped     ctrl_outs_setup        skipped
    setup_ext_lna           skipped     gc_setup               SKIPPED  <--
    load_mixer_gm_subtable  done        rx_bb_analog_filter    done
    rx_tia_calib            done        rx_adc_setup           done
    bb_dc_offset_calib      skipped     rf_dc_offset_calib     skipped
    tx_quad_calib           skipped     tracking_control       skipped

Two turns ago the stated plan was *"load_gt, **gc_setup** plus an actual manual
gain index, the mixer Gm sub-table, then rx_bb_analog_filter_calib ->
rx_adc_setup"*. What was actually built was the gain-control **mode bits** in
`REG_AGC_CONFIG_1` and the manual index in 0x109/0x10C — not `gc_setup`. That is
341 lines writing ~38 registers, and it is the best remaining explanation for a
commanded gain index that reads back correctly and does nothing:

    REG_AGC_CONFIG_1/2/3        REG_RX1_MANUAL_LPF_GAIN
    REG_DIGITAL_GAIN            REG_RX1_MANUAL_DIGITALFORCED_GAIN
    REG_PEAK_WAIT_TIME          REG_GAIN_STP1 / STP_2 / STP_CONFIG1 / STP_CONFIG_2
    REG_SMALL/LARGE_LMT_OVERLOAD_THRESH, REG_ADC_*_OVERLOAD_THRESH, ...

In manual gain control the full-table index is only one of three gain terms; the
**LPF gain and digital gain have their own manual registers**, and the gain-update
and peak-detector timing that makes a written index take effect lives in this
block. Writing the table index while leaving all of that at reset is not "manual
gain control", it is one register of it.

`REG_AGC_CONFIG_2` also carries `DIG_GAIN_EN`, and `ad9361_setup` writes
`FORCE_PD_RESET_RX1/RX2` into `REG_SMALL_LMT_OVERLOAD_THRESH` specifically when
the channel is in MGC — which is exactly our configuration.

### Next

1. Transcribe `ad9361_gc_setup` (ad9361.c:3707). Needs the default `gain_ctrl`
   values from ADI's init struct, not invented ones.
2. Re-run the gain sweep. **The prediction is sharp**: commanded gain should move
   the noise floor roughly 1 dB per dB across the table. If it does, the RX chain
   is alive and the earlier "no WiFi" results were all taken through a receiver
   whose gain was pinned at reset. If it still does not move, the signal genuinely
   is not reaching the ADC and the remaining candidates are the power-management
   and `ext_lna` items above.
3. Only then revisit the band sweep.

## `gc_setup` was not the answer either — and the gain is provably applied

Checked the chip before transcribing 341 lines, which was the right order:

    AGC_CONFIG_1     = 0xE0   bits 3:0 = 0  -> MGC on both receivers
    AGC_CONFIG_2     = 0x08   full gain table on; MAN_GAIN_CTRL_RX1/RX2 = 0 (SPI,
                              not pin control); DIG_GAIN_EN = 0
    AGC_CONFIG_3     = 0x03   PEAK_WAIT_TIME = 0x44
    RX1_MAN_LMT_FULL = 0x4C   = 76, exactly the index commanded
    RX1_MAN_DIGFORCED= 0x00
    GAIN_RX1 (0x2B0) = 0x4C   <-- the chip's APPLIED gain word

Every MGC-relevant bit `gc_setup` would write is already at the value it would
write, from reset plus what `Gain` sets. **And `REG_GAIN_RX1` — the gain actually
in force — reads back the commanded index.** The gain control path works end to
end; the gain is applied; the output does not change. `gc_setup` is not the fault,
and transcribing it would have cost 341 lines to learn nothing.

The remaining `gc_setup` content is AGC threshold and Fast-AGC configuration,
irrelevant under manual gain control, and its defaults are not in the no-OS tree
anyway (`AD9361_InitParam` is supplied by the project, and no project in this tree
defines one). Inventing AGC thresholds would have been reconstruction.

## Eliminated: RF port selection, GPO, CTRL_OUT

Toggling `REG_GPO_FORCE_AND_INIT` across 0x00/0x0F/0xF0/0xFF and
`REG_CTRL_OUTPUT_ENABLE` across 0x00/0xFF moves RMS between 1001 and 1077 — noise.
Neither drives anything that matters here.

The better port test, using gain-response rather than level as the discriminator —
the connected port should be the one whose noise *tracks gain*:

    port  rms@30dB  rms@71dB  delta_dB
       0     749.8    1109.3       3.4
       1     864.1     956.9       0.9
       4     768.2    1062.7       2.8
       7     764.0     966.1       2.0

**No port passes signal.** 41 dB of commanded gain buys 0.9–3.4 dB on every one of
the eight. The earlier reading of "ports 1/2/5/7 are quieter so probably
unconnected" was not just unproven, it was the wrong axis entirely.

## Synthesiser is powered and locked, so it is not a missing LO

    ENSM_CONFIG_1 = 0x49   FORCE_RX_ON | LEVEL_MODE | TO_ALERT
    ENSM state    = 0x08   RX
    RX_CP_LOCK    = 0x02   locked
    synth_pd      = rx_synth_powered_down: false, tx_synth_powered_down: false

`mask_synth_ready` was the suspicion — a leftover hack from the ALERT stall, and an
item on this file's own open list. It is not hiding anything: the RX synth is
powered, the charge-pump lock bit is set and `vco_locked?` agrees.

## Where this leaves it

Established by measurement, not inference:

    digital path (LVDS, capture, decode)   WORKS  (BIST tone, mag_cv 3.4e-4)
    LO synthesis and lock                  WORKS  (exact, 700-3500 MHz)
    gain command -> applied gain word      WORKS  (GAIN_RX1 == commanded index)
    baseband filter, TIA, ADC config       APPLIED and self-consistent
    ADC clock 32 MHz vs 64 MHz             NO DIFFERENCE
    RX port selection, GPO, CTRL_OUT       NO DIFFERENCE
    applied gain -> output level           **DOES NOTHING**

Every controllable stage responds correctly except the one that matters. The ADC
sees ~-6 dBFS of gain-invariant broadband noise and nothing else, which means the
RX signal path is not delivering the antenna to the converter.

Remaining candidates, and none of them is another calibration:

1. **Board RF topology.** What sits between the RX SMAs and the AD9363 has never
   been established. `zynqsdr_rev5.pdf` is on disk but its text is outlined, so
   extraction yields 280 words; only `RX2A_P`/`RX2A_N` survive, which does at least
   confirm the balanced A ports are used for RX2. **The schematic needs reading
   properly** — connect the `ehdl` folder to Cowork and the PDF can be staged and
   read as pages, or answer directly: is there a switch, filter or LNA between the
   SMA and the transceiver, and what drives it?
2. Remaining unskipped `ad9361_setup` items: `setup_ext_lna`, `bb_dc_offset_calib`,
   `rf_dc_offset_calib`, `tracking_control`. Worth doing eventually; note that
   every previous member of this list was eliminated rather than being the cause,
   so the prior on the next one is not good.
3. A hardware fault on the RX path. Not yet distinguishable from (1).

**The next action is not more transcription.** Four hypotheses in a row have been
killed by measurement, and the measurements keep saying the same thing: the chip
is configured correctly and nothing arrives. That points at the board, and the
board is the one thing in this system nobody has looked at.

## The board's external RF network: documented at last, and it is passive

The question "are we certain we understand the electrical network outside the
FPGA" was worth asking, because the honest answer had been *no*. Now partly yes.

### Provenance

`zynqsdr_rev5.pdf` — the schematic sitting in `~/src/ehdl` — comes from
**`github.com/hz12opensource/libresdr`**, an unofficial PlutoSDR port for the
LibreSDR / ZynqSDR: a **PlutoSDR clone with a Zynq 7020**, running the AD936x in
**LVDS mode for 2T2R**. That confirms what this project has been assuming about
the digital interface, from the vendor of the design rather than from inference.

### The RF front end (from the ADALM-Pluto RevB schematic, which this clones)

    SMA -> 0.1uF DC block -> 330nH series L + 18pF matching -> TCM1-63AX+ balun
        -> AD9363 RX1A_P / RX1A_N

**No RF switch. No LNA. No PA. No active component of any kind in the RX path.**
TX is the mirror image into TX1A_P/N. The product page for the LibreSDR confirms
the same balun family ("the balun ... TCM1-63AX+").

So the "unconfigured RF switch fabric" hypothesis — the one this was about to
spend a session on — **is dead**. There is nothing outside the chip to enable, and
`rf_port_setup(0)` (A_BALANCED) is the correct and only sensible port. The user's
PDF yields `RX2A_P`/`RX2A_N` on text extraction, consistent with RX2 also being on
its A port.

### Where LibreSDR is NOT Pluto, and therefore still unverified

- **Oscillator.** Pluto uses a 40 MHz *crystal* on XTALN (internal oscillator
  active). LibreSDR's product page says **VCXO**, with PPS / 10 MHz taming — an
  active oscillator driving the pin, which is what `xo_bypass = true` expects. Our
  configuration is consistent with the VCXO and the BBPLL locks with DATA_CLK
  exact, so the reference is demonstrably fine.
- **2x2.** Pluto is 1x1. The second RX/TX chain and its baluns are LibreSDR's own
  and are not covered by the Pluto schematic.
- The board schematic is on disk but its text is outlined; extraction yields 280
  words. **It needs to be read as pages** — connect the `ehdl` folder to Cowork and
  it can be staged and viewed.

## Everything else eliminated this session

    ENABLE pin (fabric ctrl1 bit 1)   was 0 the whole time; set to 1 -> 2.6 dB
                                      becomes 2.9 dB. Not it.
    REG_BIST_CONFIG      0x3F4 = 0x00
    REG_OBSERVE_CONFIG   0x3F5 = 0x00   RX_MASK 0, OBSERVATION_POINT 0,
                                        DATA_PORT_LOOP_TEST 0
    REG_BIST_DATA_PORT   0x3F6 = 0x00

No masking, no loopback, no diverted observation point. The digital receive path
is carrying whatever the ADC gives it.

## What is left, honestly

There is no software-side hypothesis left that this session can generate. The
chip is configured correctly by every register that can be read back, the front
end is passive by design, and the ADC sees gain-invariant broadband noise.

**The LO is the one thing asserted but never independently verified.** The RX
RFPLL reports charge-pump lock and the frequency word is provably correct, but
"locked" is an indicator bit — nothing has confirmed the LO is at 2437 MHz or that
it reaches the mixer. That cannot be established from software.

### The decisive next test needs no new code and no test equipment

**Hold a 2.4 GHz transmitter against the RX1 antenna.** A phone hotspot, touching
the whip. At 70 dB of gain with a working receiver that is an overload-level
signal; if the ADC's gain-invariant -6 dBFS noise does not move at all with a
transmitter at zero range, the RX path is definitively not connected to the
antenna, and the remaining question is hardware, not firmware.

Run it as: bring up at 2437, watch RMS continuously, move the phone in and out.
The oracle is a *change*, so it needs no calibration and no absolute reference —
which is exactly what every measurement in this project has lacked.

## MILESTONE: off-air RF reception. The receiver works.

First confirmed reception of a real signal in this project's history. Phone
hotspot and a laptop client beside the board; 200 captures per frequency at
8 Msps, gain 71 dB, alignment-free RMS:

    freq   min   median   max     p99    n>1.3x median
    2412  814.9  873.5  1366.6  1365.2   18
    2437  814.5  874.7  1419.9  1416.5   26
    2462  811.1  872.1  1422.4  1410.5   18
    2600  824.8  867.4   914.5   909.4    0     <-- control

Confirmed across gain:

    gain  freq   median    max    n>1.3x median
      40  2437    658.4    900.8   9
      40  2600    736.5    774.6   0
      55  2437    820.9   1344.7   2
      55  2600    796.1    879.8   0
      71  2437    947.4   1426.8  27
      71  2600    939.4    986.3   0

**Six for six.** Every WiFi channel shows bursts at every gain; the out-of-band
control shows none, ever. The medians are identical everywhere, so this is not a
level difference — it is *structure* appearing only in occupied channels.

The whole chain is therefore proven: antenna -> balun -> LNA -> mixer -> baseband
-> ADC -> LVDS -> fabric capture -> sample decode.

### Why four previous band sweeps missed it

**The mean is the wrong statistic for a bursty signal.** Every earlier sweep
averaged 6-12 captures and reported the mean. A capture is 512 words at 32 MHz
DATA_CLK — a **16 microsecond** window — and WiFi occupies a few percent of the
air. Bursts land in roughly 10% of captures and lift them ~1.6x; averaged into a
mean over ten captures that is a few percent, indistinguishable from drift.

Two hundred captures and the **max**, or a count above a threshold, separates it
cleanly. The signal was present in the very first measurement after the gain table
went in; the statistic hid it.

That is the third time this project has been misled by a summary statistic — after
the phase-pinned eye oracle and `decode2`'s `mag_cv` alignment search. The pattern
is the same each time: a number that is correct on average and blind to the thing
being looked for.

### What is actually wrong now: sensitivity, not connectivity

The noise floor is ~870-950 RMS (about -6 dBFS) and **does not move with gain**,
while the signal rides ~1.5x above it. So there is a large additive noise source
downstream of the gain stages, and it is costing essentially all the dynamic
range. A WiFi transmitter at ~30 cm should be enormous, not 3.5 dB.

Candidates, in order:

1. **The RMS above mixes both receive channels.** `sample_a` and `sample_b` are
   different channels' samples; the measurement concatenates them. If RX2 is noisy
   or unterminated and RX1 is clean, every number in this file has been the
   average of a good channel and a bad one. **Measure the two streams separately
   first** — it is one command and could halve the apparent noise.
2. `ad9361_bb_dc_offset_calib` and `ad9361_rf_dc_offset_calib`, still not
   transcribed. The DC term was measured at 350-400 earlier.
3. `ad9361_tracking_control` and RX quadrature calibration.
4. The ADC at 64 MHz is still low for the part; higher sample rates are now known
   to work at the interface (32 MHz DATA_CLK decodes perfectly).

### Method note worth keeping

The oracle that finally worked has three properties the earlier ones lacked: it
compares **in-band against out-of-band** rather than against an absolute level, it
uses a **burst-sensitive statistic** rather than a mean, and it was **repeated
across gain** so a one-off could not pass. Any of the three alone would have been
weaker; together they gave a 6/6 discrimination with no ambiguity.

## The noise floor was an artefact. Real SNR is ~29 dB.

Splitting the capture into its four interleaved sub-streams — `sample_a` and
`sample_b`, each at even and odd positions — and **ranking them within each
capture** changes the picture completely:

    freq  rank      median     max    bursts(>2x)
    2437  quietest   120.2   1021.4   24
    2437  2nd        379.3   1118.0   20
    2437  3rd       1168.0   1737.0    0
    2437  loudest   1204.5   1880.2    0
    2600  quietest   107.1    121.0    0     <-- control, tight
    2600  2nd        368.3    386.3    0
    2600  3rd       1155.6   1245.0    0
    2600  loudest   1196.2   1289.2    0

Four stable, very different noise floors: **~110, ~370, ~1160, ~1200**, consistent
across frequency. **Only the two quiet ones carry the WiFi bursts**; the two loud
ones never burst at all. Ranking is required because the capture starts at an
arbitrary point in the 4-sample frame, so which physical sub-stream lands in
`a_even` shifts from capture to capture — an unranked split showed the same
sub-stream at 119 in 63 captures and 1155 in the rest.

### The receiver responds to gain properly

Quiet sub-stream only, floor measured at 2600 MHz and peak at 2437 MHz:

    gain   floor@2600   peak@2437   SNR
      30         33.1        51.6    3.9 dB
      40         34.6       161.2   13.4 dB
      50         19.4       546.7   29.0 dB
      60         50.9      1048.0   26.3 dB
      71         70.8      1032.7   23.3 dB

The **signal** rises 51.6 -> 1048 across 30 dB of gain (+26 dB) while the **floor**
stays between 19 and 71. That is a working receiver with a working gain chain.
Peak SNR **29 dB at 50 dB gain**, and the roll-off above that is the signal
approaching full scale, not the floor rising.

### What this retracts

Everything in this file about a "gain-invariant noise floor at -6 dBFS" was
measuring the **average of two good sub-streams and two junk ones**. The junk
dominates, does not respond to gain, and produced every misleading number in this
investigation: the flat band sweeps, the 2.3 dB gain response, the "31 dB of gain
buys 3.8 dB" result. The receiver was never broken.

The genuine noise floor is **19-71 RMS out of 2048**, which is a sensible figure
for a 12-bit converter, and the real dynamic range was there all along.

### Open: what are the two loud sub-streams?

Stable at ~1160 and ~1200 regardless of frequency and gain, and never carrying
signal. Candidates: the second receive channel misconfigured or its input
unterminated; or an artefact of the fabric's sample assembly putting something
other than ADC data in two of the four slots. Note `ENSM.enable_rx(3)` enables
both channels — running 1R1T would be a quick discriminator, as would checking
whether the loud pair tracks `RX2`'s gain index independently.

Practical consequence for the decoder: **select the quiet pair.** They are
identifiable without ambiguity by ranking sub-stream RMS within a capture, and the
selection is stable within a capture.

### Method note, third and clearest instance

The measurement that worked differs from four failed ones in three ways, all
necessary: **in-band versus out-of-band** rather than an absolute threshold,
**burst-sensitive statistics** (max and count above median) rather than a mean,
and **decomposition before aggregation** rather than averaging everything
together. The last is the new lesson: aggregating across four channels of unknown
provenance destroyed a 29 dB SNR down to 3.5 dB, and no amount of care in the
other two dimensions would have recovered it.

## RX_FRAME solved; 2R2T interleave and channel mapping established

Four results, in dependency order.

### 1. Capture start phase is random mod 4 — this invalidated every prior sub-stream measurement

With zero configuration change between captures, 20 back-to-back captures landed in
one of exactly two states, a simultaneous even<->odd swap in both `a` and `b`:

    state A: [ ~1000,   ~19,  ~291,  ~450 ]   (a_even a_odd b_even b_odd)
    state B: [   ~19,  ~950,  ~450,  ~291 ]

The four underlying values are stable; only their labels move. Every earlier gain
sweep averaged over a random mixture of phases, which is why the RX1/RX2 gain table
was incoherent (RX1=20/RX2=20, the lowest gain in the sweep, produced the single
loudest reading). Any per-slot statistic taken without frame alignment is void.

### 2. RX_FRAME level mode is aliased to DC; pulse mode works

Level mode reads constant `3` in 512/512 words, always. This is not a dead pin:
one cap word is written every two DATA_CLK cycles and level-mode RX_FRAME has a
period of two DATA_CLK cycles, so it is sampled at the same phase forever.

Setting RX_FRAME_PULSE_MODE (`0x010` bit 3; `0xC0` -> `0xC8`) yields a clean
period-4 cycle in the frame bits:

    [3, 1, 0, 2] repeating, histogram exactly 128/128/128/128 over 512 words

with a rotating start phase across captures. Rotating each capture so the frame
sequence starts at `3` makes the slot decomposition stable and reproducible.
This is the alignment marker that was missing. Pulse mode should become part of
standard bringup.

### 3. The correct decomposition is 8 slots, not 4

Frame period 4 words x {a,b} = 8 slots. Frame-aligned, under real RF at 2600 MHz,
exactly four of the eight carry signal and they strictly alternate a/b:

    a0~7   b0~400   a1~330   b1~7   a2~7   b2~370   a3~350   b3~7

The time-ordered valid sample stream is `b0, a1, b2, a3` — four samples per frame
period, i.e. I1 Q1 I2 Q2. Consecutive 12-bit words complete on alternating DDR
edges, which is why validity alternates between the fall-derived and rise-derived
half. This resolves task #42: the "junk sub-streams" are not junk and not an RX2
analogue fault — they are the half-cycles on which the `{current 6, previous 6}`
assembly does not complete a word. top.ex:501-506 predicted exactly this.

### 4. BIST is not a valid test of the 2R2T interleave

Frame-aligned under BIST tone, all eight slots are hot with a period-2 pattern:

    [1448, 1295, 1295, 1448, 1448, 1295, 1295, 1448]

No period-4 structure at all. The BIST tone is injected identically into every
slot, so it cannot distinguish channels or validate framing. This retracts the
earlier inference that "BIST yields four healthy slots, therefore the sample
assembly is correct" — BIST would have looked healthy regardless. Do not use BIST
to reason about interleave, channel assignment, or I/Q pairing.

### 5. Channel mapping: b0,a1 = RX1 and b2,a3 = RX2

Frame-aligned, writing RX1 and RX2 gain indices separately (`0x109`/`0x10C`):

                      b0     a1     b2     a3
    RX1=76 RX2=20 -> 1185   1165    128    168

A 19 dB separation falling exactly on the pair boundary. So:

    ch1 = b0 + j*a1     ch2 = b2 + j*a3

Caveats. The other rows of the sweep are muddied: RX1=76/RX2=76 saturates all four
at ~1180 (= 4096/sqrt(12), full-scale uniform), and RX1=20/RX2=20 leaves b0,a1 at
671/1194 when both should be quiet — RX1's pair reads hot in 3 of 4 conditions,
suggesting `0x109` is not actually controlling RX1's gain the way `0x10C`
controls RX2's. Worth settling, but it does not affect the mapping, which rests on
the clean (76,20) row.

Still open: which rotation of [b0,a1,b2,a3] is I1 (the frame pulse indexes the
start, but `frame_pair` has no `_d` delay stage while the data lanes do, so the
frame bits are one DATA_CLK cycle newer than the oldest half of the sample word —
a possible off-by-one). Conjugate/sign ambiguity also still unresolved.

## Cross-checked against ADI axi_ad9361_lvds_if.v — one correction, two confirmations

Source: `github.com/analogdevicesinc/hdl`, `library/axi_ad9361/xilinx/axi_ad9361_lvds_if.v`
(not vendored anywhere on disk; cloned sparsely to read). This is the canonical
LVDS front end and it settles the framing questions directly.

### CORRECTION: the level-mode aliasing explanation in the previous section is wrong

ADI's delineation state machine (lines ~222-243):

    case ({rx_r1_mode, rx_frame_s, rx_frame})
      5'b01111: begin                                  // 2R2T, frame high 2 cycles running
        adc_valid_p <= 1'b0;
        adc_data_p[23:12] <= {rx_data_1, rx_data_1_s};
        adc_data_p[11: 0] <= {rx_data_0, rx_data_0_s};
      end
      5'b00000: begin                                  // 2R2T, frame low 2 cycles running
        adc_valid_p <= 1'b1;
        adc_data_p[47:36] <= {rx_data_1, rx_data_1_s};
        adc_data_p[35:24] <= {rx_data_0, rx_data_0_s};
      end

`rx_frame` is `rx_frame_s` delayed one `l_clk`. Requiring both to be `11`, then
both `00`, means the frame is HIGH for two full DATA_CLK cycles then LOW for two —
**period 4 DATA_CLK cycles**, not 2. So the earlier claim that level mode aliases
to DC because "the frame period equals the cap-word period" does not hold, and
constant `3` in level mode remains genuinely unexplained. What is now established
is that **one cap word = one DATA_CLK cycle** (our observed period-4 frame in words
= ADI's period-4 frame in cycles), and that the pulse-mode sequence we measured,

    [3, 1, 0, 2]  ->  half-cycle stream 1,1, 1,0, 0,0, 0,1

is 4 half-cycles high / 4 low — exactly the waveform ADI's decoder expects. Pulse
mode is also what LibreSDR ships: `patches/linux.diff:318-323` sets
`adi,rx-frame-pulse-mode-enable`, `adi,pp-rx-swap-enable`, `adi,pp-tx-swap-enable`,
`adi,lvds-mode-enable` with `adi,2rx-2tx-mode-enable`. Level mode is a dead end;
use pulse mode and stop investigating the constant.

Note also a bit-order difference in our capture vs ADI: ADI has
`rx_frame_s[1] = posedge`, `[0] = negedge`; our `frame_pair = {fall, rise}` is the
reverse. Harmless as long as we stay self-consistent, but it matters when reading
ADI's case values against our captures.

### CONFIRMED, and it was inverted: 12-bit word = {previous 6, current 6}

ADI builds each word as `{rx_data_N, rx_data_N_s}` — registered (previous cycle)
in the MSBs, combinational (current cycle) in the LSBs, both from the same edge.
That is the opposite of the `{current, previous}` order recorded earlier in this
document. Tested directly, extracting the raw 12-bit field and optionally swapping
the two 6-bit halves, under BIST tone:

    nibswap=false  mag={1714.6, cv 0.37565}   lag1_roughness_I = 0.843
    nibswap=true   mag={2047.8, cv 0.00034}   lag1_roughness_I = 0.176

The swapped order gives a textbook constant-magnitude phasor at exactly full scale.
**ADI's order is correct; the prose note saying `{current 6, previous 6}` was wrong.**
`SampleFormat` already produces the right answer (its `validate2` returns the same
`mag_mean 2047.8 / mag_cv 3.5e-4`), so this is a documentation fix, not a code bug —
but any new code extracting the raw field must swap. Cleanest fix is in fabric:
`sample_a = {rise_q_d, rise_q}`, `sample_b = {fall_q_d, fall_q}`.

The AD9363 sends the MSB nibble first, so at the cycle where a word completes the
current 6 bits are the LSBs and the previous 6 are the MSBs. ADI's order is the
physically correct one.

### CONFIRMED twice: channel pair boundary

Frame-aligned, RX1=76 / RX2=20 throughout, toggling `0x010` bit 6 (PP_RX_SWAP_IQ)
and bit 4 (RX_CHANNEL_SWAP):

    0x010=0xC8  iq=1 ch=0 -> [1176, 1180,  136,  169]
    0x010=0xD8  iq=1 ch=1 -> [ 136,  169, 1171, 1184]
    0x010=0x88  iq=0 ch=0 -> [1178, 1176,  168,  127]
    0x010=0x98  iq=0 ch=1 -> [ 175,  132, 1159, 1180]

RX_CHANNEL_SWAP cleanly exchanges the two pairs, and PP_RX_SWAP_IQ cleanly
exchanges the two members within each pair (136,169 -> 168,127). So the pair
boundary is real, the members are I and Q, and with RX_CHANNEL_SWAP=0:

    ch1 = b0 + j*a1     ch2 = b2 + j*a3      (slot order b0, a1, b2, a3)

This is the second independent confirmation, and unlike the gain sweep it does not
depend on any assumption about the gain registers.

### Established receive chain, end to end

    RX_FRAME pulse mode (0x010 bit 3) -> frame bits [25:24] give period-4 cycle
    rotate capture so frame sequence starts at 3   -> stable slot identity
    one cap word = one DATA_CLK cycle
    per cycle one 12-bit word completes, alternating fall- and rise-derived
    word = {previous 6 bits, current 6 bits}, same edge
    four words per frame = I1 Q1 I2 Q2 = slots b0, a1, b2, a3

Still open: which member of each pair is I vs Q in absolute terms (both swap
states are self-consistent; needs a known-sideband signal), the conjugate/sign
ambiguity, and the RX1 gain-register asymmetry (`0x109` appears not to control RX1
the way `0x10C` controls RX2 — visible in the muddied rows of the gain sweep, not
in the swap test above).

## MIMO receive chain closed out — all three open items resolved

### I/Q assignment and conjugate sign: RESOLVED

BIST tone, frame-aligned, correct nibble order, measuring mean
arg(z[n+1] * conj(z[n])) against the predicted +11.25 deg/sample:

    reg_iqswap=1  ch1(s0=I,s1=Q)=+11.25  ch2(s2=I,s3=Q)=+11.25
                  ch1(s1=I,s0=Q)=-11.25  ch2(s3=I,s2=Q)=-11.25
    reg_iqswap=0  ch1(s0=I,s1=Q)=-11.25  ch2(s2=I,s3=Q)=-11.25
                  ch1(s1=I,s0=Q)=+11.25  ch2(s3=I,s2=Q)=+11.25

With PP_RX_SWAP_IQ = 1 (`0x010` bit 6 — which is what LibreSDR ships,
`adi,pp-rx-swap-enable`), the assignment **s0=I, s1=Q gives exactly +11.25 on both
channels**: correct rotation direction, no conjugation, both channels in agreement.

    I1 = b0    Q1 = a1    I2 = b2    Q2 = a3
    ch1 = b0 + j*a1        ch2 = b2 + j*a3

The conjugate ambiguity is therefore not a real ambiguity — it was the I/Q
assignment. Note `SampleFormat.validate2` reports `deg_per_sample = -11.252`,
i.e. it uses the opposite assignment and returns a conjugated signal. **That sign
should be fixed in `SampleFormat` so it agrees with the above.**

### RX1 gain register asymmetry: DOES NOT EXIST

Writing `0x109`/`0x10C` and reading back the applied gain at `0x2B0`/`0x2B5`:

     idx   0x2B0  0x2B5
      10     10     10
      20     20     20
      30     30     30
      40     40     40
      55     55     55
      66     66     66
      76     76     76

Perfectly symmetric; both channels track their own register exactly. The suspected
asymmetry was an artefact of the CHID3 sweep having been run with the WRONG NIBBLE
ORDER, which scrambles amplitude (cv 0.376 vs 3.4e-4). Retract the suspicion.

### Verification: gain sweep with the corrected chain

                      I1(b0) Q1(a1) I2(b2) Q2(a3)
    RX1=20 RX2=20 -> [  2,     2,     2,     3 ]
    RX1=40 RX2=40 -> [  2,     2,     2,     3 ]
    RX1=55 RX2=55 -> [  5,     5,     6,     6 ]
    RX1=66 RX2=66 -> [ 13,    14,    17,    17 ]
    RX1=76 RX2=76 -> [ 43,    42,    56,    56 ]
    RX1=76 RX2=20 -> [ 45,    47,     2,     3 ]
    RX1=20 RX2=76 -> [  2,     2,    55,    54 ]

Monotonic in gain, I and Q balanced within each channel to ~1 count, the two
channels independently controllable with clean isolation in the cross rows
(45,47 vs 2,3). RX2's noise floor sits ~2.3 dB above RX1's at max gain — a real
but unremarkable board asymmetry. Every anomaly previously attributed to a broken
RX2 analogue path, junk sub-streams, or asymmetric gain application was in fact
the missing frame alignment plus the inverted nibble order.

## Canonical receive procedure (use this)

    1. Bringup.rf_receive_path(freq, fs, gain_db: g)
    2. AD9363.writef(0x010, 0x08, 1)          # RX_FRAME pulse mode
       PP_RX_SWAP_IQ (bit 6) = 1, RX_CHANNEL_SWAP (bit 4) = 0
    3. capture N+8 words; read frame bits [25:24] of word 0
    4. rotate so the frame sequence starts at 3  (cycle is [3,1,0,2])
    5. per word: raw12 = field; sample = swap_nibbles(raw12) then sign-extend
       word phase 0 -> bits [23:12] -> I1        word phase 1 -> bits [11:0] -> Q1
       word phase 2 -> bits [23:12] -> I2        word phase 3 -> bits [11:0] -> Q2
    6. ch1[n] = I1 + j*Q1,  ch2[n] = I2 + j*Q2,  one sample pair per 4 words

Sample rate per channel = DATA_CLK / 4.

## Remaining work (not blockers, now well-posed)

1. Fix `sample_a`/`sample_b` nibble order in fabric to `{rise_q_d, rise_q}` /
   `{fall_q_d, fall_q}` so software does not have to swap. Requires a rebuild —
   note only seed 25 of 377 routed, so budget for reseeding.
2. Fix the `deg_per_sample` sign in `SampleFormat.validate2`.
3. Add the `_d` delay stage to `frame_pair` for phase consistency with the data
   lanes (cosmetic now that alignment works, but it removes a known off-by-one).
4. **Capture depth is now the single blocker to a real beacon.** 512 words = 128
   samples/channel = 16 us at 8 Msps. A beacon needs far more. This is the
   reserved-memory no-map buffer + DMA work, colliding with the clock-router
   capacity wall.
5. Level-mode RX_FRAME constant-3 remains unexplained. Do not chase it; pulse mode
   is what LibreSDR ships and it works.

## Capture depth: the current structure is unroutable, and ADI shows the way out

### What was tried, and the numbers

    geometry      BRAM   INV    seeds tried   routed
    1024 x 26       1      1        377          1   (seed 25, shipping bitstream)
    8192 x 26       6    120        242          0
    8192 x 28       7    185          1          0
    4096 x 26      ~4    121        229          0

471 seeds have now failed across the two depth variants. This is not bad luck.

### Why

Yosys emits a per-bit write enable for the capture array (`_EN[25:0]` in the
synthesis log). While the array fits a single RAMB36 that enable is one signal.
The moment it does not, the array is cascaded in depth and every BRAM in the
cascade needs its own address-decoded enable *for every bit*. That decode is the
inverter cloud, and nextpnr fails in SLICE set/reset muxing -- the first reported
failing net was literally a NotGate.

Two hypotheses were tested and both were WRONG. Recorded so they are not retried:

  * **Padding to a native RAMB geometry.** 28 x 8192 is 7 x (8192 x 4), which
    tiles exactly. It made things worse (185 INV): the cost is in the depth
    cascade, not the width tiling.
  * **Halving the depth.** 4096 gave 121 INV against 8192's 120 -- no improvement
    at all. The cost is binary: one BRAM versus more than one.

`--nocarry` was re-examined and must stay. Enabling CARRY4 saves ~90 LUTs but
adds 161 inverters (282 total), which is the wrong direction.

### The fix, from ADI's axi_ad9361

ADI does delineation **in fabric**, not on the host. `axi_ad9361_lvds_if.v`
watches the frame across two cycles and emits a complete 48-bit sample quad with
a valid strobe:

    case ({rx_r1_mode, rx_frame_s, rx_frame})
      5'b01111: adc_data_p[23: 0] <= ...   // frame high 2 cycles -> channel 0
      5'b00000: adc_data_p[47:24] <= ...   // frame low  2 cycles -> channel 1,
                adc_valid_p <= 1'b1        //   quad complete

and `axi_ad9361_rx.v` wires those bits to channels:

    adc_data[11: 0] -> I0     adc_data[23:12] -> Q0
    adc_data[35:24] -> I1     adc_data[47:36] -> Q1

Cross-referencing the lvds_if assignments, **I comes from the negedge lane and Q
from the posedge lane**. In our naming that is I = sample_b, Q = sample_a --
exactly the mapping measured on hardware (I1 = b0, Q1 = a1, I2 = b2, Q2 = a3).
Independent confirmation of the empirical result from the reference source.

The consequence for the buffer is the point. We store 4 words x 26 bits = 104
bits per sample quad, because we keep both edge streams every DATA_CLK cycle and
sort it out on the host. ADI stores 48 bits for the same quad. That is a 2.2x
saving, and more importantly it allows:

    memory :cap1, width: 24, depth: 1024    # I1,Q1 -- one RAMB36, no cascade
    memory :cap2, width: 24, depth: 1024    # I2,Q2 -- one RAMB36, no cascade

Two independent single-BRAM arrays, each with a simple enable. No depth cascade,
no per-bit address decode, no inverter cloud -- and 1024 samples per channel,
4x the current effective depth and 1.02 ms at the 1 Msps HaLow target.

### Plan

  1. Add `frame_pair_d` and the two-cycle frame comparison in the DATA_CLK block.
  2. On the frame-high pair latch {sample_a, sample_b} as channel 1; on the
     frame-low pair latch channel 2 and pulse valid.
  3. Write the two 24-bit words to `cap1`/`cap2` on valid, sharing one address
     counter.
  4. Read back via a bank-select bit in ctrl2 reusing status3.
  5. Re-verify with `Nervezynq.MIMO`. The host decode simplifies enormously since
     the fabric now delivers aligned samples; keep `frame_integrity` as the check
     that fabric delineation is locked.

This bakes the parity choice into the bitstream, which the old `top.ex` comment
warned against. That warning was right when the format was unknown; it is now
measured, confirmed against ADI's source, and verified on hardware at mag_cv
3.4e-4, so the objection no longer applies.

## Diagnosis: it is a nextpnr-xilinx control-path weakness, and EHDL walks into it

### The two facts that settle it

**1. Utilisation is 0.89%.**

    LUTs 471 / 53200 = 0.89%      FFs 385 / 106400 = 0.36%      BRAM 3 / 140 = 2.1%

A design occupying under one percent of the part cannot fail to route for
congestion. Everything blamed on "the design got bigger" was wrong.

**2. Every failure is at the same site mux.** Across all 643 failed seeds:

    642  CEUSEDMUX_OUT
      1  SRUSEDMUX_OUT

Not scattered. One structure: the slice clock-enable mux.

### The correlation

    netlist                       FFs   CE_real   SR_real   routes?
    _emit/top4.json (shipping)    383         0         0   yes, seed 25
    re-synth of top4.v            383       180       275   no (5 seeds)
    current design                385       245       275   no (643 seeds)

The bitstream we are running has **zero** flops using the CE or SR pins. Every
netlist synth_xilinx produces has 180-270 of each, and none of them route.

No flag combination reproduces CE=0/SR=0 -- tried `-abc9`, `-dff`, `-retime`,
`-nowidelut`, `-nosrl`, `-nodsp`, `-nocarry` and combinations. So either the
shipping netlist came from a flow we have not reconstructed, or `_emit/top4.v`
was regenerated after `_emit/top4.json` was built and is no longer its source.
Worth resolving, but it does not change the conclusion.

### Verdict

**Primarily a nextpnr-xilinx / prjxray weakness, not EHDL and not yosys.**
Routing 0.89% occupancy should be trivial; the router instead fails on one
specific control path. This is the same family of defect already documented here:
prjxray characterises only 2 of 14 ILOGICE3 site muxes for RIOI3, which is why
IDDR is unusable. The slice control paths (CE, SR) are under-modelled in the same
way, so the router has far fewer legal routes than the silicon actually has. That
also explains the 1-in-377 hit rate: success requires placement to happen to land
every CE-driven flop where a modelled CE path exists.

Not yosys: the same version and the same `-abc9` built the working bitstream.
The missing `-abc9` in `build.exs` was a real bug of mine (184 INV vs 3) but it
was necessary, not sufficient.

**But EHDL holds the cheapest lever.** EHDL lowers every `if` inside a clocked
block to a Verilog `if`, which yosys infers as a clock-enable flop. On a device
where CE routing is the broken path, that is precisely the construct to avoid.
Emitting a D-side feedback mux instead:

    always @(posedge clk) q <= cond ? d : q;     // plain FD, no CE
    instead of
    always @(posedge clk) if (cond) q <= d;      // FDRE with real CE

moves the conditional from the control path into the datapath. It costs LUTs --
of which we are using 0.89%. `synth_xilinx` already tries this via
`xilinx_dffopt`, which absorbs CE/SR into the D-side LUT when that LUT has spare
inputs; abc9 packs full LUT6s and leaves no room, which is why it rarely fires.
Doing it at emission time does not depend on that luck.

### Recommendation

Add a lowering mode to EHDL -- call it `ce_as_mux` -- that expresses conditional
register updates as D-input muxes rather than clock enables, and takes power-up
state from the FF INIT attribute rather than a routed reset net. On this
toolchain that should be the default for anything targeting openXC7. Expected
effect: CE_real and SR_real go to ~0, and routing stops being a lottery.

This is the highest-leverage open item in the project. It is worth more than any
amount of further seed sweeping.

## Root cause found: nextpnr-xilinx cannot route SLICE clock-enable pins at scale

Everything in the preceding two sections about BRAM cascades, INV clouds and
capture depth was chasing a symptom. The real defect is in place & route, it is
reproducible in 20 lines of Verilog with no EHDL involved, and it explains the
entire history of this project's bitstream builds.

### The reproducer

`ehdl/_cetest/` -- `gen3.py` generates N flops with a chosen number of distinct
CE and SR nets; `iso2.sh` runs the matrix with a live throbber. 252 flops on an
xc7z020 is **0.24% of the device**, three IO pins, no BRAM, no DSP, no EHDL.

    mode   FFs   CE_real  SR_real   routed/3
    none    252        0       0      3/3
    ce      252      252       0      0/3
    sr      252        0     252      3/3
    both    252      252     252      0/3

Constant control pins route. A fanout-252 set/reset routes. Clock enables do not.

### It is the CE path specifically, not control nets in general

      nCE  nSR   FFs   routed/3
        1    0   252     2/3
        2    0   252     1/3
        4    0   252     0/3
        0    1   252     3/3
        0    2   252     3/3
        0    4   252     3/3
        1    1   252     1/3
        2    2   252     1/3

Distinct SR nets scale perfectly -- 1, 2 and 4 all route 3/3. Distinct CE nets
degrade monotonically from the very first one. Same flop count, same fanout, same
placement pressure, opposite behaviour. So this is **not** "multiple control sets
collide in a CLB" (that hypothesis is dead: 4 SR nets are fine) and **not** a
packer legality bug (the xc7 control-set check in `arch_place.cc` correctly
enforces one CLK/SR/CE per half-tile). The CE input path is simply modelled with
far fewer legal routes than the SR path.

Failure signature, always the same shape:

    ERROR: Failed to route arc 0 of net 'cectr[10]',
           from SITEWIRE/SLICE_X110Y58/CQ to SITEWIRE/SLICE_X106Y64/CEUSEDMUX_OUT

### Why this explains everything

  * The shipping bitstream (`_emit/top4.json`) has **zero** flops using CE or SR.
    It is the only netlist that ever routed, and now we know why.
  * The 1-in-377 seed hit rate: success required placement to happen to land
    every CE flop where a modelled CE route exists.
  * The 755 seeds that failed on the deeper capture buffer: those netlists have
    245 real CE sinks. They were never going to route, at any depth, with any
    BRAM geometry. Depth was never the problem.
  * "The clock-router capacity wall" recorded earlier in this document is this
    same defect, misattributed.

### What does NOT work as a workaround

Emitting `q <= cond ? d : q` (a D-side feedback mux) instead of
`if (cond) q <= d` does not help: yosys re-infers the clock enable from the mux
and produces an FDRE with a real CE either way. Verified directly --
`_cetest/noce.v` synthesises to `CE_real=1`. Any fix at the EHDL emission level
has to survive `opt_dff`, and this one does not.

The viable workarounds are, in order of preference:

  1. **Fix nextpnr-xilinx.** Establish why the CE site pin has fewer legal
     arcs than SR and widen it. Build tree is ready: `~/src/openxc7/nextpnr-xilinx`,
     branch `stable-backports` @ 62839b3, Release CMake cache already configured,
     so iteration is `cmake --build build`.
  2. **Force yosys to emit no CE at all** -- `dfflegalize` to a cell set without
     enables, pushing the enable into the D-side LUT. This is what the working
     bitstream effectively had. Costs LUTs, of which we use 0.89%.

Option 2 is the fast unblock and needs no C++; option 1 is the real fix and
helps every openXC7 user. They are independent and can be pursued in parallel.

## The fix: `dffunmap`, and a routed 4096-deep bitstream

### Workaround for the CE defect

Splicing `dffunmap` into the yosys script immediately before FF mapping pushes
the enable back out of the flop and into D-side logic, AFTER yosys has finished
inferring it:

    synth_xilinx <opts> -run begin:map_ffs
    dffunmap
    synth_xilinx <opts> -run map_ffs:

Measured on the 4-CE-net reproducer (252 FFs):

    variant       CE_real   LUT   FF    routed/3
    baseline          252   339   260     0/3
    dffunmap            0   338   260     3/3
    dfflegalize         0   338   260     (same)

0/3 to 3/3, and it costs ONE LUT -- the mux collapses into the existing D-side
LUT. On the real design it takes `CE_real` from 245 to 0 and `SR_real` from 275
to 0, exactly matching the profile of the only bitstream that ever routed.

Doing this in RTL does NOT work: `q <= ce ? d : q` is re-inferred straight back
into an FDRE with a real CE (verified, `_cetest/noce.v`). It has to happen after
inference, which is why it belongs in the yosys script and not in EHDL.

This is in `designs/libresdr_radio/build.exs` with a comment explaining it is a
workaround, not an optimisation. Remove it when nextpnr learns to route CE pins.

### After the fix, the failure moved

    before:  Failed to route arc ... to SITEWIRE/SLICE_X.../CEUSEDMUX_OUT   (642/643)
    after:   Failed to route arc 264 of net 'axi_clk',
             from SITEWIRE/BUFGCTRL_X0Y16/O to SITEWIRE/SLICE_X34Y111/CLKINV_OUT

Different defect, same family -- this is the "clock-router capacity wall" already
noted earlier in this document, now the binding constraint. Not yet diagnosed.

### PRJXRAY_DB was never populated

`$OXC7/prjxray/database/zynq7/` contains only `settings.sh` -- the prjxray-db
submodule was never checked out, so `fasm2frames` fails with "Mapping file
.../zynq7/mapping/devices.yaml does not exist". The populated database is a
separate repo, now cloned to `$OXC7/prjxray-db`, and `scripts/openxc7-env.sh`
points there. The `fasm2frames` shim also needs `PYTHONPATH=$OXC7/prjxray`
because the `prjxray` python package lives in the repo, not the venv.

Both of these were silent until the very last step of the flow. Anyone
reproducing this build needs `scripts/openxc7-env.sh`; the paths are not
discoverable.

### Current state

A routed 4096-deep bitstream EXISTS: `ehdl/designs/libresdr_radio/build/r.bin`
(4,045,564 bytes), from seed 1765. Caveat worth knowing: seed 1765 routed the
PRE-`dffunmap` netlist -- the background wide sweep found it before the rebuild
overwrote the JSON. It implements the same RTL, so it is a valid bitstream, but
it is NOT reproducible from the current build.exs (seed 1765 fails on the current
netlist). The post-`dffunmap` netlist has not yet had a successful seed found.

Deployed into the firmware overlay as `/root/radio4096.bin` and uploaded
(partition A). Verification pending -- the board did not re-enumerate over USB
after reboot and needs a physical replug, same as earlier in this session.

To verify once it is up:

    {:ok,_} = PL.reload_and_verify("/root/radio4096.bin")
    {:ok,_} = Bringup.rf_receive_path(2_600_000_000, 8_000_000, gain_db: 50)
    AD9363.writef(0x010, 0x08, 1)
    {:ok,w} = LVDSProbe.capture(512)
    MIMO.frame_integrity(w)   # expect {:ok, 1.0}
    MIMO.validate(w)          # expect +11.25 deg/sample, mag_cv ~3e-4 both channels

NOTE: `LVDSProbe` still has `@cap_depth 1024`. Raise it to 4096 to actually use
the new buffer -- that needs another firmware build, so it was left for after the
bitstream is confirmed working at the old depth.

## The CE defect corrupts bitstreams, it does not only block routing

`r.bin` (seed 1765, the PRE-`dffunmap` netlist) loads and half-works:

    PL.reload_and_verify("/root/radio4096.bin")  ->  :ok, magic_ok, heartbeat running
    AD9363.read(0x037)                           ->  {:ok, 0}      (should be 0x0A)
    Bringup.rf_receive_path(...)                 ->  readback_mismatch, expected 14 got 0

Same board, immediately after, on the old bitstream:

    PL.reload_and_verify("/root/pairfmt.bin")    ->  :ok
    Bringup.rf_receive_path(...)                 ->  :ok
    AD9363.read(0x037)                           ->  {:ok, 10}     (correct)

So the board is fine and `r.bin` is functionally broken: the AXI interface,
magic register and heartbeat all work, but the SPI master does not. The SPI FSM
is built from conditional registers -- i.e. CE-driven flops -- and that netlist
had 245 real CE sinks.

**Conclusion: when nextpnr does manage to "route" CE pins, the result can be
electrically wrong rather than merely rare.** A seed that routes is not
sufficient evidence of a good bitstream when CE nets are present. This retires
seed 1765 and reinforces that `dffunmap` is mandatory, not an optimisation.

### The toolchain flow itself is verified

Worth recording, because it eliminates a whole class of suspicion. Rebuilding the
known-good `_emit/top4.fasm` through the freshly-cloned prjxray-db:

    fasm2frames -> xc7frames2bit -> Bit2Bin  ==  _fuzz/out/pairfmt.bin

byte-for-byte identical (4,045,564 bytes). So the new prjxray-db checkout, the
`fasm2frames` shim, `xc7frames2bit` and `Bit2Bin` are all correct, and any future
bitstream fault is in synthesis or place & route, not in the back end.

### Getting a bitstream onto the board

`/root` is a writable mount that SHADOWS the read-only rootfs, so a file placed
in `rootfs_overlay/root/` never appears -- `mix firmware && mix upload` will not
deliver a bitstream there. What works, with the board's usb0 peer being the host
at 172.31.248.126:

    # host
    cd <build dir> && python3 -m http.server 8099 --bind 172.31.248.126
    # board
    :inets.start()
    {:ok,{{_,200,_},_,body}} = :httpc.request(:get, {~c"http://172.31.248.126:8099/r.bin", []},
                                              [], [body_format: :binary])
    File.write!("/root/radio4096.bin", body)

Verified: 4,045,564 bytes transferred intact.

## WHERE the CE defect actually lives (device-database evidence)

Traced through the openXC7 prjxray-db for zynq7. Every slice control pin is fed
by a named tile wire (`tile_type_CLBLL_L.json`, site_pins):

    site pin CE   -> CLBLL_LL_CE   <- driven by exactly 1 pip: CLBLL_FAN7
    site pin SR   -> CLBLL_LL_SR   <- driven by exactly 1 pip: CLBLL_CTRL1
    site pin CLK  -> CLBLL_LL_CLK  <- driven by exactly 1 pip: CLBLL_CLK1
    (slice L uses CLBLL_FAN6 / CLBLL_CTRL0 / CLBLL_CLK0)

Those CLB wires continue into the INT tile (`tile_type_INT_L.json`), and the two
paths are NOT symmetric:

    INT_L family    #wires   in-degree(min/med/max)   out-degree(med)
    FAN_L                8        1 /  1 /  1                0     <- CE path
    FAN_ALT              8       25 / 25 / 25                2
    CTRL_L               2       16 / 16 / 16                0     <- SR path
    CLK_L                2       16 / 16 / 16                0
    IMUX_L              48       25 / 25 / 25                0     <- LUT inputs

**SR** is driven directly out of general routing -- 16 different wires
(`BYP_BOUNCE4`, `EE4END2`, `ER1END2`, ...) can drive `CTRL_L0/1`.

**CE** is not. It must traverse a strictly 1:1 chain:

    FAN_ALT<n>  ->  FAN_L<n>  ->  CLBLL_FAN<n>  ->  slice CE

Every hop is one-to-one -- `FAN_L<n>` has in-degree exactly 1, and its sole
driver is `FAN_ALT<n>` of the same index. The only routing freedom is at
`FAN_ALT<n>` (25 sources). And the index is hardwired by which slice you are in:
slice L must use FAN6, slice LL must use FAN7.

That is precisely the asymmetry measured in `_cetest/`: a fanout-252 SR net
routes 3/3, while CE nets route 2/3, 1/3, 0/3 as their count rises.

### So what is broken, and where

**yosys: nothing.** Inferring clock-enable flops is correct behaviour and saves
LUTs on a normal flow. Our missing `-abc9` was our own bug. `dffunmap` is a
workaround for the *target*, not a yosys defect.

**nextpnr-xilinx: the placer.** `xilinx/arch_place.cc` correctly enforces one
CLK/SR/CE control set per half-tile -- that part matches silicon. What is absent
is any model of FAN-path contention: nextpnr does not know that reaching a
slice's CE pin consumes a specific, single-path, index-fixed resource
(`FAN_ALT<n>`/`FAN_L<n>`) which other signals also compete for. So it produces
placements whose CE demand is unroutable, and only finds out during routing,
where there is no path back to fix placement. Hence: fails on most seeds,
succeeds when placement happens to be satisfiable.

**prjxray-db: probably correct, not proven.** The 1:1 FAN chain looks like real
7-series silicon (control inputs come from dedicated CTRL/CLK/FAN muxes, not the
general IMUX). Vivado copes because its placer is CE-resource-aware. We have NOT
proven the FAN network is fully characterised, and that is the one open question:
if prjxray is missing FAN pips, the fix is a fuzzer/db problem instead.

### What to implement, in order of cost

1. **`dffunmap` in the yosys script (DONE).** Sidesteps the whole thing by
   emitting no CE at all. Took the seed hit rate from ~1/1600 to 1/17.
2. **Freeze placement.** `nextpnr --write placed.json` emits BEL attributes;
   re-reading them hits the "fully-frozen tile fast-path" already in
   `arch_place.cc`. Turns P&R into deterministic replay -> 1/1 builds for an
   unchanged netlist. Requires no C++.
3. **Teach the placer about FAN contention.** The real fix: model
   `FAN_ALT<n>`/`FAN_L<n>` occupancy per INT tile as a placement constraint or
   cost term, so CE-bearing flops are only placed where their CE can actually be
   routed. This is the patch worth upstreaming.

Note `xilinx/xdc.cc` understands only `create_clock`, `get_nets`, `get_ports`
and `set_property` -- there is no `create_pblock`, so floorplanning cannot be
expressed via XDC. Any manual placement has to go through per-cell BEL attrs.

## Seed 15 bitstream: routes, works, but captures dirty

`r15.bin` / `/root/radio4096b.bin` (4096-deep, dffunmap, seed 15) is functionally
alive -- SPI `prodid` reads 10, bring-up succeeds, `frame_integrity` is 1.0 -- but
the captured data is degraded.

Direct A/B, same board, same AD9363 config, same `MIMO` code, only the bitstream
swapped:

    pairfmt.bin    (1024-deep, old)  cv: [3.4e-4, 3.4e-4, 3.5e-4, 3.4e-4, 3.4e-4]
    radio4096b.bin (4096-deep, new)  cv: [0.06113, 0.06137, 0.06056, 0.00774, 0.06043]

### Hypotheses tested and eliminated

  * **Decode / alignment.** Exhaustive 4x4x2x2 grid (I word, Q word, I half,
    Q half) over one capture: best achievable is 0.00763. No alignment reaches
    3.4e-4, so this is not the `pb = pa - 1` class of bug.
  * **Internal timing.** Seed 15 reports `data_clk 377.93 MHz (PASS at 50.00)`
    against an actual DATA_CLK of 32 MHz. Not close to marginal.
  * **Input capture margin at the pads.** Dropping Fs 8 -> 4 Msps (DATA_CLK
    32 -> 16 MHz) gives an identical cv distribution. If setup/hold at the IOB
    were marginal, halving the rate would have helped. It did not.
    (Fs = 2 Msps is unreachable: `{:error, {:no_suitable_dividers, 2000000}}`.)

cv takes only two discrete values, 0.0077 and 0.061 -- never intermediate. That
pattern says a discrete wrong-word substitution, not analogue noise.

### Prime remaining suspect: the 4096-deep capture memory

It is the only substantive fabric change besides the nibble order, and the nibble
order is proven correct (deg_per_sample 11.25, mean ~2044). Yosys cascades
4096x26 across ~4 BRAMs with an address-decoded read mux; a marginal or
mis-decoded readout would substitute whole words, which matches the discrete cv
levels and the alignment-independence.

**Next experiment, and it is a clean isolation:** rebuild at depth 1024 keeping
`dffunmap` and the new nibble order. If that returns 3.4e-4, the depth increase
is the culprit and the capture buffer needs to be built as explicitly banked
single-BRAM arrays (the `top.ex.banked` variant, which is preserved) rather than
left to yosys's cascade. If it still reads 0.06, the fault is elsewhere in the
seed-15 placement and the answer is to select seeds on measured hardware cv, not
merely on "routed".

Until then **`pairfmt.bin` remains the only trustworthy bitstream**, and the
board should be left loaded with it.

## Silicon knowledge inventory: what is established vs what is guessed

Three tiers, deliberately separated. Conflating them is what cost most of a day.

### TIER 1 -- measured on hardware (highest confidence)

  1. **Fabric DDR capture works without IDDR, IDELAY or DIFF_TERM.** Two ordinary
     fabric flops on opposite edges of DATA_CLK sample the AD9363 LVDS bus at
     32 MHz DATA_CLK (8 Msps) with `mag_cv = 3.4e-4` -- effectively bit-perfect.
  2. **DIFF_TERM is not needed at these rates.** nextpnr silently drops it (no
     FASM bits emitted) and the board has no external termination. Link is clean.
  3. **Fabric speed is not a constraint.** 377.93 MHz reported on `data_clk`
     against 32 MHz actual.
  4. **Occupancy is trivial**: 0.89% LUT, 0.36% FF, ~2% BRAM on xc7z020.
  5. **Bitstream load via PS7 devcfg works.** AXI reads before
     `/sys/class/fpga_manager/fpga0/state` reads `operating` hang the CPU with no
     recovery short of power cycle.
  6. **CE nets are the routing blocker.** 252 FFs at 0.24% occupancy: distinct SR
     nets route 3/3 at 1, 2 and 4 nets; distinct CE nets route 2/3, 1/3, 0/3.
  7. **A CE-bearing design that DOES route can still be functionally wrong.**
     `r.bin` loads, AXI/magic/heartbeat all fine, SPI master dead (`prodid` 0 vs
     0x0A). A successful route is not evidence of a correct bitstream.
  8. **Removing CE (dffunmap) moves the hit rate from ~1/1600 to 1/17.**
  9. **Halving DATA_CLK does not improve capture quality** (8 -> 4 Msps identical),
     so the current capture regression is not IOB setup/hold margin.

### TIER 2 -- read from the openXC7 device database (a MODEL of silicon)

  1. Each slice control pin has exactly one tile wire:
     `CE <- CLBLL_FAN6/7`, `SR <- CLBLL_CTRL0/1`, `CLK <- CLBLL_CLK0/1`.
  2. `FAN_ALT<n> ->> FAN_L<n>` is **hardwired**, not a mux: prjxray writes it with
     `->>`, and there are **zero** segbits for any `FAN_L` destination. The
     configurable point is upstream, at `FAN_ALT<n>`.
  3. `FAN_ALT<n>` has **25** sources; `CTRL_L<n>` has **16** (and 32 segbits).
  4. Both draw from general-routing END wires in all directions. CE additionally
     has 3 `LOGIC_OUTS_L` sources (direct slice outputs) that SR does not.
  5. The FAN network is **well characterised**, not under-fuzzed: 308 segbit
     entries for FAN pips vs 30 for CTRL.
  6. `IMUX_L` (LUT inputs): 48 wires, 25 sources each.
  7. prjxray characterises only 2 of 14 ILOGICE3 site muxes -> IDDR unusable.
     That is a DATABASE gap, not a silicon limitation. The silicon has IDDR.

### TIER 3 -- NOT known

  1. **Why CE fails and SR succeeds.** This is the important one, and the earlier
     explanation in this document is WRONG -- see the retraction below.
  2. Whether prjxray's INT_L pip list is complete. Well-fuzzed is not proven-complete.
  3. Whether IDELAY / ISERDES are usable. Untested; likely the same class of gap
     as IDDR, but that is an assumption.
  4. The actual setup/hold margin of the LVDS capture. It works; by how much is
     unmeasured, and with no usable IDELAY it is also untunable.
  5. The clock-region topology of xc7z020, and whether region crossing is what
     produced the `axi_clk -> CLKINV_OUT` routing failure on some seeds.
  6. Whether the 4096-deep BRAM cascade readout is correct in silicon or
     mis-modelled. Current open bug.
  7. Whether nextpnr's timing model covers IOB input paths at all.

### RETRACTION: "the CE path is starved" was wrong

Earlier in this document I concluded that CE fails because its routing path is
resource-starved -- `FAN_L` having in-degree 1 while `CTRL_L` has 16. That
reading was wrong. `FAN_L`'s single driver is a HARDWIRED continuation, not a
mux; the real mux sits one hop upstream at `FAN_ALT<n>`, which has 25 sources --
**more** than SR's 16, and including direct slice outputs SR cannot reach.

So the database does not show CE as the poorer path. The measured asymmetry is
real and reproducible, but its mechanism is UNEXPLAINED.

Leading hypothesis, explicitly not established: only 2 of the 8 FAN wires per
tile can reach CE (FAN6 -> slice L, FAN7 -> slice LL, fixed by geometry), and the
FAN network also carries data-path signals, so CE contends with logic for a
shared resource -- whereas `CTRL_L0/1` are dedicated control wires nothing else
uses. Testable by instrumenting a failing route to see what actually occupies
`FAN_ALT6/7` at the point of failure.

Everything downstream of "CE is the problem" still stands -- that is measured.
Only the mechanism is open.

## SOLVED: why CE fails and SR does not (static graph census, Phase 0)

Answered from the device database alone -- no builds, no seeds, exhaustive over
every INT tile. This supersedes both earlier attempts at an explanation.

### The mechanism

    FAN_ALT6  --> FAN_L6 --> CLBLL_FAN6 --> slice L  CE pin   (CLBLL_FAN6 drives NOTHING else)
    FAN_ALT6  --> FAN_BOUNCE6 --> 6x IMUX_L (LUT data inputs), BYP_ALT1, 2x FAN_ALT

    FAN_ALT7  --> FAN_L7 --> CLBLL_FAN7 --> slice LL CE pin
    FAN_ALT7  --> FAN_BOUNCE7 --> 12x IMUX_L, 2x BYP_ALT, 2x FAN_ALT

    CTRL_L0/1 --> slice SR      in=16, out=0   TERMINAL, dedicated
    CLK_L0/1  --> slice CLK     in=16, out=0   TERMINAL, dedicated

`FAN_BOUNCE<n>` has in-degree 1 -- its only source is `FAN_ALT<n>`.

So **the wire that carries a clock enable into a slice is the same wire that
serves as the bounce/feedthrough into that tile's LUT data inputs.** A wire
carries one net. Therefore:

  * any data signal routed through `FAN_BOUNCE6` to reach a LUT input consumes
    `FAN_ALT6`, and slice L's CE becomes unroutable in that tile -- and vice versa;
  * only 2 of the 8 `FAN_ALT` wires per tile can reach a CE pin at all, and which
    one is fixed by geometry (FAN6 -> slice L, FAN7 -> slice LL);
  * SR and CLK never contend with anything: `CTRL_L`/`CLK_L` are terminal wires
    with 16 sources and no other consumers.

### This explains every observation

  * SR at fanout 252 routes 3/3; CE at 1/2/4 nets routes 2/3, 1/3, 0/3.
  * 0.89% device occupancy does not help: the collision is **per-tile and
    structural**, not global congestion. Spreading logic out does not avoid it,
    because every tile hosting logic may need its own FAN bounce.
  * Seed dependence: whether a build routes depends on whether the placer
    happened to co-locate CE flops with logic needing that tile's bounce path.
  * Why nextpnr cannot see it: `arch_place.cc` validates control sets per
    half-tile (correct), but nothing models "using this tile's FAN bounce
    forecloses this tile's CE".

### Correcting the earlier retraction

The first explanation ("CE path is starved, in-degree 1 vs 16") was wrong.
The retraction that followed ("CE has MORE sources, 25 vs 16, mechanism unknown")
was right to retract but incomplete. The accurate statement is:

  **CE's path is CONTENDED. SR's path is DEDICATED.**

Source count was never the issue; exclusivity is.

### Consequences

1. **`dffunmap` is not merely a workaround -- it is the correct strategy for this
   silicon under an open toolchain.** A clock enable costs a scarce, contended,
   per-tile resource. The equivalent D-side mux costs one LUT input, of which
   each tile has 48 richly-connected `IMUX_L` wires. Trading CE for LUT is
   trading a bottleneck for an abundance.
2. **The upstream nextpnr fix is now precisely specifiable:** model `FAN_ALT<n>`
   as shared between the CE path and the bounce network. Either reserve
   `FAN_ALT6/7` in any tile hosting a CE-driven flop (forbidding bounce routing
   through it), or add a placement cost that discourages co-locating CE flops
   with logic that needs that tile's FAN bounce.
3. Phase 2 (the fabric-slam bitstream) is no longer needed to answer this
   question. It remains worth building as a *bitstream correctness* harness --
   a separate, demonstrated gap (`r.bin` routed with a dead SPI master).

## RETRACTION 2: the FAN-bounce contention theory is also wrong

Tested directly using the existing `NEXTPNR_PIP_BLACKLIST` env knob (no rebuild
needed -- `arch.cc:417` reads a file of `TILETYPE.DST.SRC` lines). Blacklisted
`FAN_ALT<n> -> FAN_BOUNCE<n>`, surgically (4 pips, only the CE-capable 6/7) and
broadly (all 16):

    variant        nCE nSR  routed/5
    none             4   0   0/5
    bl_ce.txt        4   0   0/5
    bl_all.txt       4   0   0/5
    none             2   0   1/5
    bl_ce.txt        2   0   1/5
    bl_all.txt       2   0   1/5

Identical, seed for seed, with the same failing nets and the same failing arcs.
The blacklist demonstrably loaded (`pip blacklist: 4 entries from ...`). Removing
those pips changes nothing, so FAN-bounce contention is NOT the binding
constraint. The Phase 0 conclusion is retracted.

### What the route dump actually shows

`nextpnr --write` on a design with ONE CE net and 252 sinks (routes on seed 1).
The CE net's own route:

    1565 hops total
    FAN_ALT        269      CEUSEDMUX_OUT  172
    FAN_L          126      FAN_BOUNCE      27
    plus EEBEG/NRBEG/NLBEG/WWEND/... general routing

So the FAN network is **CE's own distribution tree**, not a competitor for it:
`FAN_ALT -> FAN_BOUNCE -> FAN_ALT` is how a CE net hops between tiles. I had the
relationship inverted -- blacklisting the bounce removes CE's own transit path,
which is why it could never have helped.

Note also `FAN_ALT` (269) is used about twice as often as `FAN_L` (126): most
FAN_ALT hops are transit, not termination.

### Where that leaves it -- honestly

Established, and not in doubt:

  * CE distribution uses a dedicated FAN network, structurally separate from
    SR/CLK (which use terminal `CTRL_L`/`CLK_L` wires) and from LUT data (IMUX).
  * That is why SR never contends and CE does.
  * Degradation with CE net count is monotonic and reproducible.
  * `dffunmap` avoids the whole thing and is the right default here.

NOT established: the precise resource that runs out when a second CE net is
added. Two mechanisms have now been proposed and both were falsified by direct
test. No third mechanism should be asserted without evidence from an actual
failing route.

### The experiment that would settle it

The blacklist knob and `--write` together make this cheap. Take the 2-CE-net
design, find the seed that routes, dump it, and tabulate FAN wire occupancy per
INT tile. Then take a failing seed and dump the partial state. The question is
narrow and answerable: at the moment of failure, what net owns the `FAN_ALT6/7`
of the tile whose CE could not be reached? Everything so far has been inference
from aggregate statistics; that would be direct observation.

## THERE ARE TWO CE BUGS, NOT ONE -- and one of them is not a routing bug

Direct observation, via `nextpnr --write` on both a routing and a failing seed of
the same 2-CE-net design. This is the first evidence in this whole investigation
that is observation rather than inference, and it overturns the framing.

### Failure-mode census across every `_cetest` nextpnr log

    total failing runs : 43
    routing failures   : 32   ("Failed to route arc ... CEUSEDMUX_OUT")
    FASM control-set   : 11   (see below)
    other              :  0

**The second mode is not a routing failure at all.** Seed 2 places AND routes
completely, then dies in bitstream generation:

    ERROR: FASM: FF '$auto$ff.cc:337:slice$3878' (type FDRE) at bel SLICE_X108Y64/CFF
    disagrees with its half-slice on 'is_ceused' (tile CLBLM_R_X69Y64)
    -- control-set contention in the placement

Re-running that seed with `--force` completes with a fully routed design. So the
placer put one FF with a real CE net and another whose CE was disconnected as
const-VCC by `pack_ffs()` into the same half-slice. Each is legal alone;
`CEUSEDMUX` is per-slice, so the pair cannot be encoded.

### What the routed-CE dump shows

One CE net, 252 sinks, routed:

    1565 hops;  FAN_ALT 269   FAN_L 126   FAN_BOUNCE 27   CEUSEDMUX_OUT 172

`FAN_ALT -> FAN_BOUNCE -> FAN_ALT` is CE's own inter-tile distribution tree.
FAN_ALT is used ~2x more than FAN_L, i.e. mostly transit rather than termination.

### Patch attempted, result INCONCLUSIVE -- do not cite as a fix

`_cetest/ctrlset_always_check.patch` hoists the xc7 half-tile control-set scan
out of the `lts.halfs[i].dirty` gate, so it can never reuse a stale cached
`valid` (the same treatment the SLICEM guard already received, per its comment).
Rebuilds in ~5s.

    nCE   stock        patched
      1   2/3          4/8   (route-fail 0, fasm-ctrlset 4)
      2   1/5          4/8   (route-fail 0, fasm-ctrlset 4)
      4   0/5          0/8   (route-fail 8, fasm-ctrlset 0)

Suggestive but NOT significant at n=8: routing failures vanish at nCE<=2 and the
residue is entirely the FASM bug, while nCE=4 is unchanged and entirely routing.
It may only be redistributing failures. **The tree has been reverted to stock**
so downstream libresdr builds are not sitting on an unvalidated toolchain; the
patch is saved and re-appliable.

### Where this actually leaves the two bugs

  1. **FASM `is_ceused` half-slice disagreement** -- a placement-legality hole.
     Precisely located, cheaply reproducible, and the check that should catch it
     is `arch_place.cc:~796` comparing `ff->ffInfo.ce`. Why a mismatched pair
     survives that comparison is still unexplained and is the next thing to
     instrument (log the two `ffInfo.ce` values at the offending bel).
  2. **Routing to CEUSEDMUX at higher CE-net counts** -- unchanged by the patch,
     dominant at nCE=4, still unexplained.

Three mechanisms have now been proposed for the routing bug and all three were
falsified by direct test. Do not assert a fourth without a dump.

`dffunmap` avoids BOTH bugs and remains the correct default.

## External corroboration (re-appended; earlier write hit a 502)

### AMD UG474 confirms the silicon model exactly

  * "There are eight storage elements per slice."
  * "The control signals clock (CLK), clock enable (CE), and set/reset (SR) are
    common to all storage elements in one slice."
  * "When one flip-flop in a slice has SR or CE enabled, the other flip-flops
    used in the slice also have SR or CE enabled by the common signal."
  * "A CLB element contains a pair of slices."

The `is_ceused` FASM error therefore encodes a REAL constraint, and nextpnr's
per-half-tile granularity is correct (one `lts.halfs[i]` = 8 FFs = one slice).

### `dffunmap` is AMD's own recommended technique

UG949 "Reduce the Number of Control Sets" lists **"Pushing the Logic from the
Control Pin to the Data Pin"**. UG904 documents Vivado doing this automatically
via `CONTROL_SET_REMAP` (ENABLE / RESET / ALL / NONE=default): "maps the
set/reset and/or CE logic to the D-input of the register", because "designs with
fewer control sets have more options and flexibility in terms of placement".

We independently rediscovered `CONTROL_SET_REMAP = ALL`. Stop calling it a
workaround; it is a control-set reduction and should be this flow's default.

What is openXC7-specific is SEVERITY: Vivado degrades gracefully, nextpnr-xilinx
fails outright, because it has no control-set-aware placement cost. The FASM
guard is upstream (`xilinx/fasm.cc:663`), so the maintainers already know
placement can produce unencodable combinations. No public issue matches either
of our failure modes.

## How to get silicon ground truth WITHOUT Vivado

The premise to discard: that Vivado is the reference. It is not -- it is another
model. **The chip is the oracle, and we have one.** What has been missing all
session is not a reference tool but an OBSERVATION CHANNEL: every conclusion so
far has been inferred from tool logs, which is why three mechanisms were proposed
and all three falsified.

### Ground-truth sources, ranked by authority

  1. **Behavioural probing of the part.** The only true oracle for "does this
     configuration actually work". Requires an in-design observation channel.
  2. **Configuration readback (PCAP/devcfg).** Confirms the frames we intended
     are the frames in config memory -- catches fasm2frames / segbit-mask /
     masking errors. Does NOT establish semantics: readback returns what we
     wrote, so it cannot discover what a bit MEANS.
  3. **AMD documentation.** Authoritative for architectural rules (UG474 already
     settled the control-set question). Use before experimenting.
  4. **prjxray-db.** A model derived from Vivado by third parties. Treat as
     hypothesis, never as truth -- it has already been wrong for us once (IDDR).
  5. **Tool logs.** Inference only. Necessary, never sufficient.

### The rig: a self-validating fabric probe

Design rules, all of which today's failures argue for:

  * **Trusted base.** Build only from primitives already proven on silicon by
    `pairfmt.bin`: LUT, FF, BRAM, IBUFDS, BUFG, PS7/AXI. The trusted set grows
    only when a primitive is hardware-proven, never by assumption.
  * **Per-cell observability.** A scan chain, not an OR-tree: every DUT reports
    independently, so one bitstream yields thousands of facts instead of one.
  * **BEL-pinned placement** (`BEL` attrs, honoured by the frozen-tile path in
    `arch_place.cc`) so a failing scan bit names a physical slice, and the result
    is a map of the die rather than an aggregate.
  * **In-design golden reference.** Each DUT compared against a known-good twin
    on the same die, same bitstream, same clock -- so a discrepancy is the DUT,
    not the environment.

### Three experiments, in value order

  1. **CE census.** Per slice: one CE-driven counter plus one free-running
     counter, CE driven at a known duty (say 1-in-4). Scan both out. For every
     slice: CE correct / stuck-on / stuck-off / miscounting. This measures
     CEUSEDMUX semantics directly, and -- by deliberately placing mixed-CE flops
     in one slice using `--force` past the FASM guard -- turns UG474's prose into
     a measured fact for THIS part.
  2. **Eye scan.** We now have MMCME2/PLLE2 wrappers. Generate a phase-shifted
     capture clock, sweep phase across 360 deg, and measure BIST `mag_cv` at each
     step. That maps the actual LVDS data eye on silicon -- something no
     datasheet or tool log gives us -- and would almost certainly explain the
     4096-deep `mag_cv 0.061` regression, which is currently blocking a
     trustworthy capture bitstream.
  3. **Pip-existence probe.** Route a known toggling signal through one candidate
     pip into a scanned capture flop. Confirms or refutes individual routing-graph
     entries. Incremental and slow; use it only on pips a failure implicates, not
     as a survey.

### Honest limits

Behavioural probing validates hypotheses; it does not enumerate an unknown space.
The routing graph is far too large to survey exhaustively this way -- prjxray
needed Vivado as a generator for that reason. What this rig gives us is the
ability to settle any SPECIFIC question about the part definitively, which is
exactly what today lacked. It also requires a routable bitstream to bootstrap,
so the trusted base must stay small and CE-free (`dffunmap`).

## SOLVED: the 4096-deep capture regression is a BRAM PARITY-BIT bug in openXC7

Found by measurement on silicon in ~20 minutes, after a day of inference got
nowhere. This is the first experiment of the "chip is the oracle" plan and it
worked exactly as intended.

### Experiment 1: eye scan (no rebuild required)

The AD9363 has programmable delays on its own side of the LVDS link --
`REG_RX_CLOCK_DATA_DELAY` (0x006), `DATA_CLK_DELAY` in [7:4], `RX_DATA_DELAY` in
[3:0]. ADI's own `ad9361_dig_interface_timing_analysis()` sweeps this 16x16 to
build an eye. We replicated it using `mag_cv` as the quality metric. **No fabric
change, no rebuild, no seed hunt** -- pure SPI writes.

    pairfmt.bin (1024, good)        radio4096b.bin (4096, bad)
     0 |  ...###########|            0 |  ....++.++..++.|
     1 |   ...##########|            1 |    ..+.+..++++.|
     2 |    ...#########|            2 |    .......+++++|
     3 |     ...########|            3 |     ...++...+..|
       (# = cv<1e-3, + = cv<1e-2, . = cv<1e-1)

The good bitstream has a wide open eye. The bad one has **no eye anywhere** in
all 256 delay combinations -- degraded at every sampling phase, and speckled
rather than a clean region. That eliminates the entire "input capture timing
margin" class of explanation, which was my leading hypothesis and was wrong.

### Experiment 2: per-bit census

Captured 2048 words under BIST tone on each bitstream, compared the 1-fraction of
every one of the 26 bits:

      8  a8       50.0   25.0   -25.0  <<<
     17  b5       53.1   26.6   -26.5  <<<

**Exactly two bits differ. The other 24 are identical to the decimal.**

### Root cause

Bits 8 and 17 are 9 apart. Checking the synthesised primitives:

    RAMB36E1 cap.0.0 / cap.0.1 / cap.0.2
      WRITE_WIDTH_A = 9,  READ_WIDTH_B = 9   (4096 x 9 mode, three BRAMs)
      ports: DIADI 32, DIPADIP 4, DOADO 32, DOPADOP 4

A RAMB36E1 in x9 mode carries **8 data bits on DI plus 1 PARITY bit on DIP**:

    BRAM 0: word bits 0-8   -> 0-7 on DI,  bit 8  on DIP
    BRAM 1: word bits 9-17  -> 9-16 on DI, bit 17 on DIP
    BRAM 2: word bits 18-25 -> 18-25 on DI (bit 26 would be DIP, unused)

The corrupted bits are precisely the two parity-bit positions that are in use.
**openXC7 mishandles the RAMB36E1 DIP/DOP parity path in x9 width mode.**

This explains everything the inference could not:
  * why 1024 x 26 was fine -- it fits a x36 mode where 26 bits land entirely on
    the 32 data pins and no parity bit is used;
  * why exactly two bits, and exactly those two;
  * why no sampling phase helped (the fault is after sampling);
  * why no alignment grid could recover it.

### Fix

Keep every capture array inside a single BRAM in a data-only width mode. That is
exactly the **banked** variant already written and preserved as
`ehdl/designs/libresdr_radio/top.ex.banked` -- four explicit 1024 x 26 arrays.
It was written for the wrong reason (a since-falsified INV theory) and discarded;
it is the correct design for the right reason. 1024 x 26 maps to x36 (32 data
pins), so no parity bit is ever touched.

Alternative if a single deep array is wanted: constrain the width so no slice
lands on a DIP pin, or force a x18/x36 mapping. Banking is simpler and proven.

### Method note

Two hardware experiments, roughly twenty minutes, zero rebuilds, and the answer
is exact and mechanistic. Compare with the preceding day: three proposed
mechanisms for the CE bug, all falsified, none resolved. **Measure the part.**

## CORRECTION: the BRAM bug is an unrouted upper-half parity OUTPUT, not width/2

The `width / 2` arithmetic is a red herring. openXC7 already handles the odd-width
case deliberately (`fasm.cc`, `write_bram_half`):

    // Widths 1 and 9 are odd and cannot be split evenly: prjxray encodes the
    // leftover bit (for width 9 that bit is the parity bit) with a RAMB36-scope
    // feature.  Without it the block silently behaves as width 8, and every
    // DIP/DOP bit reads back as 0.
    if (w == 1 || w == 9) write_bit("BRAM36_" + pname + "_1");

and our FASM DOES contain `BRAM36_WRITE_WIDTH_A_1` and `BRAM36_READ_WIDTH_B_1`.
So the per-half `_4` plus the RAMB36-scope leftover bit is the INTENDED encoding,
and it is present. The `_9` feature existing in the db is not evidence of a bug.

### The real defect, localised by address parity

A RAMB36 in a narrow mode interleaves its two 18Kb halves on the address LSB
(prjxray names them `L` = lower and `U` = upper). Measured on hardware:

    bit  8:  even-addr ones = 53.1%   odd-addr ones =  0.0%   <- parity
    bit 17:  even-addr ones = 53.1%   odd-addr ones =  0.0%   <- parity
    bit  7:  even-addr ones = 53.1%   odd-addr ones = 59.4%   <- data, fine
    bit 16:  even-addr ones = 53.1%   odd-addr ones = 53.1%   <- data, fine

Parity is perfect in one half and stuck at zero in the other. The FASM says why --
the entire routing of the read-parity output is:

    BRAM_L_X22Y105.BRAM_LOGIC_OUTS_B4_1.BRAM_FIFO36_DOPBDOPL0
    BRAM_L_X22Y110.BRAM_LOGIC_OUTS_B4_1.BRAM_FIFO36_DOPBDOPL0

Two entries, both `DOPBDOP**L**0`. There is no `DOPBDOP**U**0` anywhere in the
file. (Two entries is correct -- only two of the three BRAMs carry a used parity
bit; the third's would be word bit 26, which does not exist.)

**The upper half's parity output is never routed, so every access landing in the
upper half returns 0 for that bit.** Data pins are unaffected because both their
L and U wires are routed (192 `DIADI`/`DIBDI` entries against 26 parity ones).

### Where the fix belongs

This is a bel-pin / site-wire modelling issue, not arithmetic: the RAMB36E1 site
presents `DOPBDOP[3:0]` as single pins, but a 36Kb block in a parity-using narrow
mode needs BOTH the `L` and `U` tile wires driven/read. Either the chipdb maps the
site pin to only the L wire, or nextpnr does not know to bind both. That is the
thing to inspect next -- `xilinx/python/xilinx_device.py` bel-pin construction for
RAMB36E1, and whether `DOPBDOPU*` appears in the chipdb at all.

**No patch has been attempted.** The previous turn's proposed `width/2` fix would
have been wrong and is withdrawn. The visual artifact `bram-parity-bug` explains
the width/parity relationship correctly but attributes the cause to the
arithmetic; panels 4 and 6 need revising to this finding.

The workaround is unchanged and still correct: keep every capture array inside a
single BRAM in a data-only width mode (`top.ex.banked`), so no parity bit is ever
used.

## BRAM parity: precise localisation (supersedes both earlier BRAM sections)

### The site model

prjxray maps the RAMBFIFO36E1 site's pins alternately across the two 18Kb halves:

    DOBDO0 -> DOBDOL0    DOBDO1 -> DOBDOU0    DOBDO2 -> DOBDOL1  ...
    DOPBDOP0 -> DOPBDOPL0   DOPBDOP1 -> DOPBDOPU0
    DOPBDOP2 -> DOPBDOPL1   DOPBDOP3 -> DOPBDOPU1

A RAMB36 at x9 is built as TWO RAMB18 halves at x4 each (hence the per-half
`WIDTH_4` -- `width/2` is CORRECT, not a bug), giving 8 data bits, plus a
RAMB36-scope feature for the 9th (parity) bit.

### What our bitstream actually routes

    data  (8 bits):  DOBDOL0 U0 L1 U1 L2 U2 L3 U3   -- BOTH halves, all routed
    write parity  :  DIPADIPL0 U0 L1 U1             -- all four wires
    read  parity  :  DOPBDOPL0                      -- ONE wire, lower half only

Data is read from both halves and is perfect at every address. Parity is read
only from the lower half, and measures correct on even addresses, 0 on odd.

### Therefore

The 9th bit of a x9 RAMB36 does NOT live solely on `DOPBDOP[0]`. The hardware
alternates it between the lower and upper halves by address, while yosys and
nextpnr both treat `DOPBDOP[0]` as "the" parity bit and route only that wire.
Every odd-address access returns 0 for it. This is a **site/pin-model defect**,
not arithmetic and not the `width/2` line.

### Two fixes, and only one is ready

1. **Immediate and implementable now: make it fail loudly.** openXC7 already has
   the precedent (`fasm.cc:663`, the `is_ceused` guard) of erroring rather than
   emitting a bitstream it cannot encode. The same treatment applies: when a
   RAMB36 is configured in a parity-using width (x9 / x18 / x36) and not all of
   the required L/U parity wires for the used bits are bound, `log_error` instead
   of writing the bitstream. That alone delivers what a user dev needs -- they
   never get a silently-wrong bitstream -- and it needs no new architectural
   knowledge.
2. **The real fix needs one more measurement.** We do not yet know the exact
   L/U-by-address rule for the parity bit, and I will not guess it again. The
   experiment that settles it: build a capture design that stores BOTH
   `DOPBDOP[0]` (L0) and `DOPBDOP[1]` (U0) into separate word bits, then check
   whether the expected value appears on L0 for even addresses and U0 for odd. If
   it does, the fix is to bind both wires for a single logical parity bit in x9
   mode, and the rule generalises to x18/x36. That is a small design change plus
   one seed hunt.

Do NOT ship a speculative pin-mapping change. Three mechanisms have already been
proposed and falsified across this investigation; this one is localised but its
semantics are not yet measured.

## nextpnr BRAM x9 parity guard: IMPLEMENTED AND WORKING

`xilinx/fasm.cc`, in the RAMB36 block of `write_bram_half`. Original preserved as
`fasm.cc.orig`. Rebuild is ~5s (`cmake --build build -j6`).

### Three attempts, two of which silently did nothing

  * v1 looked up `DOPBDOP[0]` -- the LOGICAL bus name. Result: 41 seeds,
    `routed_clean=7 guard_fired=0`. Seven corrupt bitstreams still emitted.
  * v2 looked up `DOPBDOPL0` / `DOPBDOPU0` -- the SITE WIRE names. Same result:
    `routed_clean=7 guard_fired=0`.
  * v3 uses the actual packed port names, obtained by dumping a routed design
    with `--write` instead of guessing: **`DOPBDOP0`, `DIPADIP0`** -- no bus
    brackets, no L/U suffix. The L/U split lives only in the site-pin map.

The lesson is the same one this whole investigation keeps teaching: a guard that
compiles is not a guard that fires. Both no-op versions would have shipped
looking like a fix.

### v3 verified

    ERROR: FASM: RAMB36E1 'cap.0.1' uses READ_WIDTH_B = 9 with parity bit
    DOPBDOP0 in use (net '_cat_26339[17]').

It names bit **17** -- one of the exact two bits measured corrupt on hardware.

No false positive: the banked design maps to 4x RAMB36E1 at **x36** (26 bits fit
the 32 data pins, parity port unused) and the guard stays silent.

### The PORT_IN theory is also dead

`get_bram36_ul_pins()` filters to `PORT_IN`, which looked like the bug. It is
not: the packed cell has ports `DIPADIP0..3` / `DOPBDOP0..3` and NO L/U
duplication is applied to either direction. The four parity pins are four
independent pins that the site map assigns alternately to the two halves. Do not
"fix" `PORT_IN` -- that was hypothesis four, and it is falsified.

What remains unexplained is the same narrow question as before: what the correct
L/U-by-address rule is for the 9th bit. The guard makes that safe to leave open.

### Banked design status

`top.ex` is now the banked variant (4 x 1024x26); the cascaded version is saved
as `top.ex.deep4096`. It routes far more easily -- **seed 5, first batch of six**,
against ~17 seeds for the cascaded one -- because four independent single-BRAM
arrays place more freely than one cascade.

    designs/libresdr_radio/build/bank.bin   4,045,564 bytes   (seed 5)

Built and served, but NOT yet verified on hardware: the board dropped its USB
link mid-verification (`No route to host`, `en11` still up at .126) and needs a
physical replug. The pending check is the eye scan -- `#` (cv<1e-3) should return
across a wide delay window, matching `pairfmt.bin`, if the parity theory is right.

## CONFIRMED ON HARDWARE: the parity theory is correct, and we have a working 4096-deep bitstream

`bank.bin` (banked variant, seed 5) loaded and measured:

    dl:        {200, 4045564}
    pl:        :ok
    PRODID:    {:ok, 10}
    integrity: {:ok, 1.0}
    ch1: %{deg_per_sample: 11.25, mag_cv: 3.5e-4, mag_mean: 2047.8}
    ch2: %{deg_per_sample: 11.25, mag_cv: 3.5e-4, mag_mean: 2047.8}

`mag_cv` 3.5e-4 -- identical to the 1024-deep reference -- on a 4096-deep buffer.
Both channels exact, full scale, perfect frame lock.

Eye scan, against the two references:

    bank.bin (4096, banked)     pairfmt.bin (1024, good)     radio4096b.bin (4096, x9)
     0 |  ...###########|        0 |  ...###########|          0 |  ....++.++..++.|
     1 |   ...##########|        1 |   ...##########|          1 |    ..+.+..++++.|
     2 |    ...#########|        2 |    ...#########|          2 |    .......+++++|

The banked build reproduces the good bitstream's eye exactly. The x9 build had no
`#` anywhere in 256 delay combinations.

### The chain, fully closed

  1. yosys maps a 4096x26 array to three RAMB36E1s at **x9**;
  2. x9 puts the 9th bit on the PARITY port, and the site map sends
     `DOPBDOP0` to the LOWER half only;
  3. the 9th bit alternates halves by address, so it reads correctly on even
     addresses and 0 on odd -- exactly bits 8 and 17 of our word;
  4. banking into four 1024x26 arrays maps to **x36**, where 26 bits fit the 32
     data pins and the parity port is never used;
  5. result: bit-exact capture at 4x the depth.

### Deliverables from this line of work

  * `xilinx/fasm.cc` guard (v3) -- fires on the broken configuration, names the
    offending cell and net, stays silent on the banked design. Original saved as
    `fasm.cc.orig`.
  * `top.ex` is now the banked variant; cascaded version kept as `top.ex.deep4096`.
  * `bank.bin` -- working 4096-deep capture bitstream, seed 5.
  * Routing is also much easier banked: seed 5 in the first batch of six, against
    ~17 seeds for the cascaded version.

### Note on the visual artifact

`bram-parity-bug` explains the width/parity relationship correctly but attributes
the cause to the `width / 2` arithmetic. That was wrong -- `width/2` is correct,
and openXC7 already handles the odd-width leftover bit deliberately. The true
cause is the site-pin map sending index 0 to the lower half only. Panels 4 and 6
need revising.

## MILESTONE: full 4096-deep capture verified bit-exact

    words:     4096
    integrity: {:ok, 1.0}      -- perfect frame lock across the WHOLE buffer
    samples:   1023            -- per channel
    ch1: %{deg_per_sample: 11.25, mag_cv: 3.4e-4, mag_mean: 2047.8}
    ch2: %{deg_per_sample: 11.25, mag_cv: 3.4e-4, mag_mean: 2047.8}

**1023 samples per channel** -- 4x the old depth. At the 1 Msps HaLow target that
is 1.02 ms, long enough for a beacon. The capture-depth blocker is closed.

### Outstanding: the firmware @cap_depth bump did not take

`LVDSProbe.capture/1` still guards at `n <= 1024` on the running image.
Diagnosis: `mix upload` wrote partition A, but the board rebooted into B, still
holding the old firmware (`nerves_fw_active = "b"`, uuid
3bd8f67c-1d46-5348-daf6-417d1d04c224 = the previous build). Source and beam are
both correct at 4096, so the image is fine -- it simply is not the active one.

Worked around by driving the capture registers directly, which is also worth
keeping as a debug primitive:

    cap4096 = fn ->
      {:ok, c2} = Fabric.read32(0x14)
      arm = bxor(c2 >>> 16 &&& 1, 1) <<< 16
      :ok = Fabric.write32(0x14, arm); Process.sleep(5)
      for a <- 0..4095 do
        :ok = Fabric.write32(0x14, bor(arm, a))
        {:ok, v} = Fabric.read32(0x28)
        v &&& 0x3FF_FFFF
      end
    end

Fix properly by re-uploading and confirming `nerves_fw_active` flips, or by
validating the new partition explicitly. Cosmetic -- the hardware is proven.

### State of the tree

  * `top.ex` = banked variant (4 x 1024x26, maps to x36, no parity port).
    Cascaded version preserved as `top.ex.deep4096`.
  * `bank.bin` (seed 5) on the board at `/root/bank.bin` -- the good bitstream.
  * `pairfmt.bin` remains as the 1024-deep reference.
  * nextpnr carries ONE local change: the x9 parity guard in `fasm.cc`
    (`fasm.cc.orig` is stock). Everything else is upstream.
  * `_cetest/` holds the CE reproducers, the blacklist experiment, the eye-scan
    and bit-census scripts, and `ctrlset_always_check.patch` (unvalidated,
    not applied).

### Next on the SDR critical path

Capture depth is no longer the blocker. Back to the beacon: tune to a live 2.4 GHz
channel at 1 Msps, capture 1023 samples/channel, and run the HaLow decode. The
MIMO decode path (`Nervezynq.MIMO`) is verified end to end on both channels.

---

## Register map DSL: one spec, two languages (DONE)

`ehdl/designs/libresdr_radio/regmap.exs` is now the single source of truth for
every fabric register offset and bit position. Nothing else may state one.

    %{
      ctrl0:   [{:spi_tx_data, :rw, 8}, {:spi_cs_hold, :rw, 1}, {:spi_go, :wtoggle, 1}],
      ctrl1:   [{:ad9363_resetb, :rw, 1}, ...],
      ctrl2:   [{:cap_rd_addr, :rw, 12}, {:_pad, :rw, 4}, {:cap_arm, :wtoggle, 1}],
      status0: [{:spi_rx_data, :ro, 8}, {:spi_done, :ro, 1}, {:spi_tx_ready, :ro, 1}],
      ...
    }

Fields pack LSB-first in declaration order. `Hw.RegMap.fields/1` is the ONLY
place an offset is ever computed.

Two consumers:

  * `Hw.RegMap.to_ehdl/1` emits the fabric-side slice lines.
  * `Nervezynq.RegMap` (a `use` macro) emits driver-side typed accessors:
    `Regs.put_cap_rd_addr/1`, `Regs.pulse_cap_arm/0`, `Regs.cap_word/0`,
    `Regs.spi_done/0`, `Regs.dump/0`. `@external_resource` on the spec means
    editing `regmap.exs` recompiles the driver.

### Drift check against `top.ex` -- PASS

`to_ehdl` output vs the hand-written slices, field by field:

    spi_tx_data   ctrl0[7..0]     spi_tx_data = ctrl0[7..0]        match
    spi_cs_hold   ctrl0[8..8]     spi_cs_hold = ctrl0[8..8]        match
    spi_go        ctrl0[9..9]     go_bit      = ctrl0[9..9]        match
    ad9363_*      ctrl1[0..3]     identical                        match
    cap_rd_addr   ctrl2[11..0]    cap_rd_addr = ctrl2[11..0]       match
    cap_arm       ctrl2[16..16]   cap_arm_bit = ctrl2[16..16]      match
    status0/1/2/3 pack order      identical                        match

Only local signal *names* differ (`go_bit`, `cap_arm_bit`, `done_toggle`,
`rx_data_reg`, `cap_done_sync`). Every position and width agrees. Zero drift.

### Shadow state, and why `sync_shadow/0` exists

A `ctrl*` word is written as a whole, so setting one field is a
read-modify-write. RW state is mirrored in an Agent (Maia SDR makes the same
choice). The mirror starts empty, so `sync_shadow/0` reads the control words
back from the AXI slave first -- without it the first `put_*` would zero every
other field in that word. `LVDSProbe.capture/1` and `AD9363.release_reset/0`
both call it before their first write.

`Regs.put/1` composes several fields into ONE bus write, which is what the SPI
inner loop needs -- three `put_*` calls would be three AXI round trips per byte:

    Regs.put(ctrl0: [spi_tx_data: byte, spi_cs_hold: cs], toggle: [:spi_go])

### Call sites migrated

  * `LVDSProbe.capture/1`  -- `Fabric.write32(0x14, arm ||| addr)` is gone;
    now `Regs.pulse_cap_arm/0` + `Regs.put_cap_rd_addr/1` + `Regs.cap_word/0`.
  * `LVDSProbe.await_done/1` -- `Regs.cap_done/0`.
  * `LVDSProbe.data_clk_mhz/1` -- `Regs.dclk_count/0`.
  * `AD9363.release_reset/0`, `enable_chip/0`, `xfer/2`, `await/2`.
  * `Pl.reload_and_verify/1` heartbeat -- `Regs.heartbeat/0`.

Deliberately NOT migrated: `Fabric.read32(0x00)`, the fixed ID word. It has to
be readable *before* any register map is trusted, so it stays a literal.
`LVDSProbe.sample/1` keeps `@status3 0x28` -- it is the legacy raw-read path
retained only so the historical statistics stay reproducible.

### Verification

Compiled against a stub `Fabric` that logs every bus access; all nine
predictions matched exactly:

    sync_shadow from CTRL2=0x0001_0123  -> cap_rd_addr 291, cap_arm 1
    pulse_cap_arm                       -> ONE write {0x14, 0x123}   (addr preserved)
    put_cap_rd_addr(0xAB)               -> ONE write {0x14, 0x0AB}   (arm preserved)
    put(ctrl0: data 0x37, cs 1, ^go)    -> ONE write {0x0C, 0x337}
    same again                          -> ONE write {0x0C, 0x137}   (go flips back)
    STATUS0 0x33A5                      -> {rx 0xA5, done 1, ready 1}
    STATUS3 0x43AB_CDEF                 -> {cap_word 0x3ABCDEF, cap_done 1}
    put_cap_rd_addr(4096)               -> ArgumentError, 12-bit overflow

NOTE: `MIX_TARGET=host mix compile` cannot be used to check this tree -- the
Rust `devcfg_load` port does not build on macOS (`off64_t`, `mmap64`,
`MAP_POPULATE` are Linux-only). Syntax and macro expansion were checked with
`elixirc` against the stub instead. The board's running firmware still has the
pre-migration modules; these changes go live on the next firmware upload.

---

## ISERDESE2 / IDELAYE2 under openXC7 -- the premise was wrong

The working assumption has been that `axi_ad9361`'s path is closed because
ISERDES/IDELAY are unusable under openXC7, on the grounds that prjxray
characterises only 2 of ILOGICE3's 14 muxes. Measured, that assumption does not
survive. **A full ISERDESE2 + IDELAYE2 bitstream builds today**, end to end,
with no patches to anything.

Reproducers live in `ehdl/designs/iserdes_probe/` (`run.sh <design.v> t1.xdc <seed>`).

### What was measured

    t3_plain.v            IBUFDS -> fabric flops (what the radio does now)
                          ROUTED, seeds 1/7/25
    t2_iddr.v             IBUFDS -> IDDR (ILOGICE3_IFF bel)
                          ROUTED, seeds 1/7/25
    t1_iserdes.v          IBUFDS -> ISERDESE2, IOBDELAY="NONE" (direct D)
                          PNR FAIL, seeds 1/7/25, identical error every time:
                            Failed to route arc 0 of net 'd0',
                            from SITEWIRE/IOB_X1Y66/INBUF_EN_OUT
                            to   SITEWIRE/ILOGIC_X1Y66/DINV_OUT
    t4_iserdes_idelay.v   IBUFDS -> IDELAYE2 -> ISERDESE2, IOBDELAY="IFD"
                          ROUTED, seeds 1/7/25. fasm2frames FAILED on two
                          undocumented pips (see below).
    t5_no_ofb.v           as t4, OFB/OCLK/OCLKB left UNCONNECTED
                          ROUTED; fasm2frames clean, 7802 frames;
                          xc7frames2bit clean, 4045664-byte .bit.

`t5` emits the real thing -- `ISERDES.IN_USE`, `ISERDES.NETWORKING.DDR.W4`,
`IDELAY_Y0.IN_USE`, `IFFDELMUXE3.P0` -- so the config genuinely reaches the
frames rather than being silently dropped.

### The three defects, separated

**1. Direct-D path into ISERDESE2 does not route.** Deterministic, seed
independent. IDDR uses the same `D -> DINV -> DINV_OUT` site pip in the same
site and routes fine, so the site pip is not the problem; the ISERDESE2 site
*variant* is. `ILOGICE3` has three variants (ILOGICE3=0, ILOGICE2=1,
ISERDESE2=2) and `Arch::usp_pip_hard_unavail` gates site-internal pips on
`pd.site_variant > 0 && pd.site_variant != tileStatus[...].sitevariant.at(...)`.
Variant 0 is exempt from that check and the bounds test is `<=` where it should
be `<`. Not yet root-caused to a specific line -- next step is an instrumented
build. WORKAROUND TODAY: use `IOBDELAY="IFD"` and feed the serdes through
IDELAYE2/DDLY. That is not a hack for our purposes; it is the path you want
anyway, because it is the one with a tap-delay eye scan on it.

**2. nextpnr routes tie-offs into unused ISERDES pins.** Tying `OFB`, `OCLK`,
`OCLKB` to `1'b0` makes nextpnr route real nets to them even with
`OFB_USED="FALSE"`, which needs two pips prjxray has not documented:

    RIOI3.RIOI_OLOGIC0_OFB.IOI_OLOGIC0_D1
    RIOI3.IOI_OCLKM_0.IOI_IMUX31_1

fasm2frames then hard-errors. Leaving those pins unconnected avoids it
entirely. These two pips are a genuine prjxray gap, but a two-entry one in the
OFB/OCLK feedback path -- nothing to do with capturing data.

**3. Three documented features nextpnr never emits** (lost capability, not a
correctness bug): `ILOGIC.IFF.INV_OCLK`,
`ILOGIC.ISERDES.DYN_CLK_INV_EN`, `ILOGIC.ISERDES.DYN_CLKDIV_INV_EN`.

### Coverage audit: the database is not the blocker

Every fasm feature nextpnr-xilinx is capable of emitting for these cells
resolves in `segbits_{lioi3,rioi3}.db`:

    ILOGICE3_IFF (IDDR path)                      16/16
    ISERDESE2, all legal INTERFACE_TYPE x         38/38
      DATA_RATE x DATA_WIDTH combinations
    IDELAYE2                                      21/21

IDELAYE2 in particular is fully characterised: `IDELAY_VALUE[4:0]` in both
polarities, all three `IDELAY_TYPE`s, `DELAY_SRC`, `CINVCTRL_SEL`,
`HIGH_PERFORMANCE_MODE`, `PIPE_SEL`, both input inversions. A tap-delay eye
scan is available to us right now.

Cross-family check (artix7/kintex7/spartan7/zynq7 segbits are byte-identical
for these tiles -- same fuzzer, no free coverage) turned up exactly two extras,
both in virtex7's RIOI: `ILOGIC.IFF.DDR_CLK_EDGE.SAME_EDGE_PIPELINED` and
`ILOGIC.IFFDELMUXE3.P1`.

### Where "2 of 14 muxes" actually bites

`site_type_ILOGICE3.json` has 14 site pips: CE1USED, CLKBINV, CLKINV,
D2OBYP_SEL, D2OFFBYP_SEL, DINV, IDELMUXE3, IFFDELMUXE3, IFFMUX, IMUX, REVUSED,
SRUSED, ZHOLD_FABRIC_INV, ZHOLD_IFF_INV. Only IDELMUXE3 and IFFDELMUXE3 appear
in segbits *by that name* -- but DINV, CLKINV and CLKBINV are documented under
their fasm names (`ZINV_D`, `IFF.ZINV_C`, `IFF.ZINV_OCLK`), and nextpnr does not
consult site pips for ILOGIC config at all; it hardcodes the feature strings.
So the undocumented muxes cost us the ZHOLD auto-delay path, the O/IMUX
combinational bypass, and the D2OBYP tristate bypass -- none of which an LVDS
receive path needs.

**Revised conclusion: the ISERDES route is open.** Whether we take it is now an
engineering choice (32 MHz DATA_CLK with a wide-open eye already works on
fabric flops) rather than a toolchain constraint. Feature parity with
`axi_ad9361` is a software problem in nextpnr-xilinx, not a silicon
reverse-engineering problem.

---

## IDELAYE2 on silicon: the toolchain is happy, the lanes are dead

The openXC7 audit said IDELAYE2 is fully characterised (21/21 features resolve
in segbits) and a bitstream builds cleanly. On the board it does not work.

### What was built

`top.ex.idelay` = the known-good banked top with one `IDELAYE2` inserted between
each `IBUFDS` and the capture flops, on all SEVEN receive lanes (six data +
RX_FRAME). DATA_CLK is deliberately NOT delayed -- the tap must move data
relative to the sampling clock, and moving both moves nothing. Tap comes from
`IDELAY_TAP` at build time via a module attribute, because `IDELAY_TYPE` is
FIXED and the tap is therefore a bitstream constant.

Eight bitstreams, taps 0/4/8/12/16/20/24/28, each having won its own seed
lottery (0 to 7 failures before a hit -- consistent with the usual ~1/13). All
eight in `ehdl/designs/libresdr_radio/taps/`. FASM confirms seven
`IDELAY_Y0.IN_USE` + `DELAY_SRC_IDATAIN` + the right `IDELAY_VALUE[4:0]`, and
nextpnr routes the dedicated `RIOI_IDELAY0_IDATAIN.RIOI_I0` pad path rather
than going through the fabric.

### What the silicon says

    control:  /root/bank.bin (no IDELAY)
              samples 256, ch1 deg 11.25, mag_cv 3.4e-4        DECODES

    test:     tap0.bin (IDELAY_VALUE=0, otherwise identical)
              1024 of 1024 capture words are exactly 0x0000000
              ch1/ch2 mag_mean 0.0, mag_cv 999.0               DEAD

    same board, same session, same bring-up, same capture code.

And the discriminator that makes this unambiguous:

    dclk_count over 200 ms  ->  16.16 MHz

DATA_CLK is alive and at the right frequency on the tap0 bitstream. DATA_CLK is
the ONE lane with no IDELAYE2 in it. Every lane that has one reads zero. It is
not bring-up, not the capture path, not the AD9363 -- all three are proven by
the control minutes earlier on the same board.

Tap 0 vs tap 28 makes no difference: all eight taps are equally dead. A delay
that does not vary with the tap value is not a delay.

### Why: no IDELAYCTRL

`IDELAYE2` is not self-contained. UG471 requires an `IDELAYCTRL` fed by a
calibrated 200 MHz reference in the same I/O bank; it continuously calibrates
the tap chain against that reference, and its `RDY` output gates the delay
line. With no `IDELAYCTRL` in the design the chain never calibrates and the
output sits static -- which is exactly what 1024 zero words look like.

This was called out in `Hw.Xilinx.IDELAYE2`'s moduledoc as "the taps are
uncalibrated, so do not quote picoseconds". That was too generous. Uncalibrated
does not mean approximate; it means off.

### The lesson worth keeping

Every static check passed. prjxray documents all 21 features. nextpnr emits them
correctly. fasm2frames resolves every one. The bitstream loads, the magic word
reads back, the heartbeat ticks, DATA_CLK measures 16.16 MHz. The design is
still completely broken, and only the board could say so.

A FASM feature being documented means prjxray knows which bits it sets. It does
not mean the primitive works in isolation, and nothing in the openXC7 stack
models inter-primitive requirements the way Vivado's DRC does. That gap is now
the main risk in every "openXC7 supports primitive X" claim, including the
ISERDESE2 result above -- which has been shown to BUILD, and has NOT yet been
shown to CAPTURE.

### Next

1. `IDELAYCTRL` + a 200 MHz reference. That means `MMCME2_BASE` or `PLLE2_BASE`
   (both already exist as EHDL components) locked to the 50 MHz PS clock, then
   `IDELAYCTRL` with `REFCLK` from it and a reset held until the MMCM's `LOCKED`
   asserts. Re-run the same eight taps. The control point is tap 0 = decodes;
   if it does not, stop and fix that before reading any eye.
2. Only then is the eye scan meaningful, and only then does ISERDESE2 with
   `IOBDELAY="IFD"` mean anything either -- that path runs THROUGH the IDELAY.

### Harness that now exists

  * `Hw.Xilinx.IDELAYE2` -- EHDL component, params IDELAY_VALUE/TYPE/HPM.
  * `designs/libresdr_radio/build_taps.sh` -- one bitstream per tap, per-tap
    seed sweep, cached.
  * `Nervezynq.EyeScan` -- board-side sweep: gunzip, `PL.reload`, bring-up with
    retry, self-contained capture, score against the BIST tone, table output.
    Self-contained capture on purpose: it gets hot-loaded onto firmware older
    than the tree it came from, and a sweep that silently captures 1024 words
    when it asked for 4096 would produce a plausible, wrong eye.
  * Transfer is HTTP over usb0 (`python3 -m http.server 8100 --bind
    172.31.248.126`), not scp -- scp truncates at 11294 bytes. Bitstreams gzip
    from 4,045,564 to ~34 kB, so all 32 taps would fit in ~1.1 MB.

### Two bugs found in the harness itself, both worth remembering

  * `AD9363.bist_tone/4` returns `{:ok, reg}`, not `:ok`. Matching `:ok` in a
    `with` sent every tap into the retry path and printed a uniformly closed
    eye -- indistinguishable from a real closed eye. A sweep needs a control
    point whose answer is already known, or it cannot tell its own bugs from
    its measurements.
  * 50 ms after `PL.reload` is not enough before the first SPI transaction;
    the readback comes back as zeros and looks like a dead chip. 200 ms works.

---

## The CMT does not lock. Neither PLL nor MMCM, at any multiplier.

Getting `IDELAYE2` working needs `IDELAYCTRL`, which needs a 200 MHz reference,
which needs a CMT. So the CMT went under the oracle first, and it failed.

### First, a free measurement

`heartbeat` is a free-running 24-bit counter in the `axi_clk` domain, already in
STATUS1. Read it twice against the wall clock and it reports the fabric clock
with no new hardware:

    window   20 ms -> 100.276 MHz
             50 ms ->  99.991
            100 ms ->  99.990
            150 ms ->  99.994

**axi_clk = 99.99 MHz**, measured, not assumed. (The first attempt used a
300 ms window and read 44.579 MHz -- a 24-bit counter wraps every 167 ms at
100 MHz. Aliasing, not a slow clock. Keep the window under 150 ms.)

### The probe

`top.ex.pllprobe` / `top.ex.mmcmprobe`: the known-good top plus one CMT, with
`dclk_div` re-clocked from the CMT output instead of DATA_CLK. That means
STATUS2 reads the CMT output frequency through the EXISTING divide-by-512
counter and no AXI register had to change. LOCKED is synchronised into
`axi_clk` and lands in STATUS1 bit 24.

    PLLE2_BASE, CLKIN1 = axi_clk, DIVCLK_DIVIDE=1, CLKOUT0_DIVIDE=5
    VCO = MULT x 100 MHz; PLLE2's legal VCO range 800..1600 gives MULT 8..16.

### Result

    MULT   VCO(MHz)  LOCKED  measured  expected
       8        800       0      0.00     160.0
       9        900       0      0.00     180.0
      10       1000       0      0.00     200.0
      11       1100       0      0.00     220.0
      12       1200       0      0.00     240.0
      13       1300       0      0.00     260.0
      14       1400       0      0.00     280.0
      15       1500       0      0.00     300.0
      16       1600       0      0.00     320.0

    MMCME2_BASE, same probe, MULT_F 10.0, DIVIDE_F 5.0:  LOCKED 0, 0.00 MHz

Nine multipliers, two different primitives in two different site types with two
different nextpnr emitters and two independently fuzzed segbits sets. Zero locks.

### What this rules out

**Not the loop-filter table.** This was the leading hypothesis going in:
`write_pll` in `fasm.cc` computes `LKTABLE[39:0]` from `CLKFBOUT_MULT` (and the
emitted value for MULT=10 is correct -- `0xE73E8FA401`, matching `lk_table[9]`)
but leaves `TABLE[9:0]` hardcoded at `0x1FC` and `FILTREG1_RESERVED` at `0x8`.
A hardcoded loop filter would fail for SOME multipliers and work for others.
All nine failing kills it. The hardcoded `TABLE` is still probably wrong -- the
code's own comment admits the tables "MUST be computed from CLKFBOUT_MULT" and
then computes only one of them -- but it is not what is biting here.

**Not the primitive, the site, or the emitter.** PLLE2_ADV and MMCME2_ADV are
separate sites, separate segbits (362 vs 378 features), separate code paths.

**Not a dead bitstream.** On the MMCM build: magic reads `0x45484431`, heartbeat
runs, and it measures 105 MHz. The fabric is fully alive on the same bitstream
whose CMT is dead. `axi_clk` demonstrably exists.

**Not the design.** `rst` and `pwrdwn` are tied to the `zero` wire, which is
driven (`top.ex:510`), and internal CLKFBOUT->CLKFBIN feedback is present in the
FASM (`CMT_TOP_R_UPPER_T_PLLE2_CLKFBIN.CMT_TOP_R_CLKFBOUT2IN`).

### What is left

The clock does not arrive at CLKIN1, or the CMT is not enabled. The FASM routes
it as fabric-BUFG -> GCLK16 -> BUFH -> HCLK_CMT -> CLKIN1:

    CLK_HROW_BOT_R_X87Y26.BUFHCE.BUFHCE_X0Y0.IN_USE
    CLK_HROW_BOT_R_X87Y26.CLK_HROW_CK_MUX_OUT_L0.CLK_HROW_R_CK_GCLK16
    CLK_HROW_BOT_R_X87Y26.CLK_HROW_CK_BUFHCLK_L0.CLK_HROW_CK_HCLK_OUT_L0
    HCLK_CMT_X8Y26.HCLK_CMT_CK_BUFHCLK0_USED
    HCLK_CMT_X8Y26.HCLK_CMT_MUX_PLLE2_CLKIN1.HCLK_CMT_CK_BUFHCLK0

Every hop is present and every one is documented. It still does not work, which
is the same shape as the IDELAYE2 result: a complete-looking FASM that the
silicon does not honour.

Note `HCLK_CMT_X8Y26` feeding `CMT_TOP_R_UPPER_T_X8Y44`. Worth confirming that
is the correct HCLK_CMT for that CMT and not an off-by-one-region error, since
that class of bug produced the BRAM x9 parity fault.

### Next experiment

Drive CLKIN1 from a clock-capable INPUT PIN rather than from fabric. DATA_CLK is
on N20, `IO_L14P_T2_SRCC_34`, and the FASM already shows a CCIO path exists in
this device (`HCLK_CMT_L_X178Y78.HCLK_CMT_CK_IN0.HCLK_CMT_CCIO2`). If a CMT
locks on the CCIO path and not on the BUFH path, the fault is isolated to the
fabric-clock-into-CMT route, which is a nextpnr routing/enable-bit problem with
a specific address. If it fails there too, the CMT itself is not being enabled
and the search moves to the CMT power/enable bits that neither emitter writes.

### Status of the IDELAY programme

Blocked, and honestly so. The chain is IDELAYE2 <- IDELAYCTRL <- 200 MHz <- CMT,
and the CMT is the first link. No eye scan is possible until a CMT locks. The
hand-rolled fabric-flop receive path remains the only proven way to get samples
off this board, and it still works: control run this session gave
`deg_per_sample 11.25`, `mag_cv 3.4e-4`.

### Artifacts

  * `top.ex.pllprobe`, `top.ex.mmcmprobe` -- CMT probes, `PLL_MULT` env var.
  * `designs/libresdr_radio/build_pll.sh` -- one bitstream per multiplier.
  * `designs/libresdr_radio/pll/mult{8..16}.bin` -- built, all nine routed.
  * `Nervezynq.PllScan` -- board-side sweep and table.
  * `top.ex` is back to the known-good no-CMT, no-IDELAY variant.

---

## CMT: it is category 3. Fifteen bitstreams, zero locks.

Task #57 asked one question: does a CMT lock when CLKIN1 comes from a
clock-capable PIN instead of from fabric? It does not. Neither does anything
else tried.

### The CCIO experiment

`top.ex.ccioprobe`: CLKIN1 wired to `data_clk_raw`, the IBUFDS output BEFORE the
BUFG. N20 is `IO_L14P_T2_SRCC_34`, so this takes the dedicated CCIO route. The
BUFG stayed where it was, so the capture path was untouched. MMCME2 rather than
PLLE2 because DATA_CLK is 16 MHz and PLLE2's minimum CLKIN is 19 MHz.
16 x 50 = 800 MHz VCO, / 4 = 200 MHz -- exactly the IDELAYCTRL reference.

FASM confirms the route changed:

    HCLK_CMT_L_X178Y78.HCLK_CMT_MUX_MMCM_CLKIN1.HCLK_CMT_CCIO2
    HCLK_CMT_L_X178Y78.HCLK_CMT_CCIO2_ACTIVE / _USED

Result: LOCKED 0 before bring-up (correct -- no input clock yet) and LOCKED 0
after. And the control that makes it airtight: capture on the SAME bitstream
after bring-up returned 0 zero-words with `mag_mean 1714.6`. Real toggling data,
so DATA_CLK was demonstrably present at CLKIN1 while the MMCM sat unlocked.

### Everything now ruled out

    2 primitives   PLLE2_BASE, MMCME2_BASE
    2 site types   CMT_TOP_R_UPPER_T (PLL), CMT_TOP_L_LOWER_B (MMCM)
    2 clock routes fabric BUFG->GCLK16->BUFHCE->HCLK_CMT, and dedicated CCIO
                   from a clock-capable pin
    9 multipliers  MULT 8..16, the entire legal VCO range
    3 reserved-bit variants (below)
    ------------------------------------------------------------------
    ~15 distinct bitstreams, 0 locks

Every one with the fabric proven alive on the same bitstream (magic
`0x45484431` + heartbeat), and the CCIO one with the input clock proven present.

### The RESERVED-bit hypothesis, and how it was tested cheaply

Diffing emitted FASM against segbits for the MMCM (58 emitted, 117 documented,
normalising `[n]` and `[hi:lo]`) gives:

  * **emitted but undocumented: NONE.** So unlike the BRAM x9 parity fault,
    nothing is being silently dropped here.
  * documented but never emitted: mostly legitimately-zero fields
    (EDGE/NO_COUNT/MX for our divide values, fractional counters, SS_EN,
    STARTUP_WAIT, ZINV_*). Three stood out as suspicious:
    `LOCKREG1_RESERVED` (6 bits), `LOCKREG2_RESERVED` (1), `FILTREG2_RESERVED`
    (10). nextpnr writes `FILTREG1_RESERVED = 0x8` and `LOCKREG3_RESERVED[0]`
    but leaves those three at zero.

Tested by patching the ROUTED FASM and re-running only fasm2frames ->
xc7frames2bit -> Bit2Bin. No place & route, so each candidate cost seconds
instead of a seed lottery (`designs/libresdr_radio/patch_mmcm.sh`).

    variant  LOCKREG1  LOCKREG2  FILTREG2   LOCKED
    a        0x3F      1         0x000        0
    b        0x3F      1         0x3FF        0
    c        0x00      1         0x000        0

Not it, at least not at those values.

Also checked and NOT the cause: `COMPENSATION`. nextpnr's `write_mmcm` emits
`COMP.Z_ZHOLD`, and the code carries a detailed comment recording that
`COMP.ZHOLD` leaves the MMCM dead while `COMP.Z_ZHOLD` makes it run -- so
someone has had an MMCM running under openXC7 on some device. Our FASM emits
`COMP.Z_ZHOLD` correctly.

Upstream corroboration: gatecat/nextpnr-xilinx issue #77 is about PLLE2_ADV
with `COMPENSATION="ZHOLD"` failing to build, and notes that the INTERNAL
workaround produces a bitstream that "reportedly doesn't function on actual
hardware". So CMT-dead-on-silicon is known anecdotally; it does not appear to
have been characterised.

### Why the usual next step is closed

`mask_cmt_top_l_lower_b.db` does not exist, so there is no "bits that belong to
this tile" set to subtract the 522 documented bits from. The CMT occupies
frames 28-29 at word indices 16..1080, which bounds the space at roughly two
frames' worth -- thousands of bits, not the ~50 that a LOCKED-oracle brute
force would make tractable. Without a mask db, a directed search has no
candidate list to search.

The standard move here is to diff against a known-good vendor bitstream that
uses an MMCM. That is explicitly out of scope for this project, and worth
stating plainly rather than drifting into: we are declining the one cheap
method, and that is a deliberate cost, not an oversight.

### Where this leaves the three weakness categories

  1. **nextpnr software bugs** -- five found, all with addresses: BRAM x9
     parity, SLICE CE routing, ISERDESE2 direct-D site variant, ISERDES
     OFB/OCLK tie-offs, hardcoded PLL `TABLE[9:0]`.
  2. **prjxray database gaps** -- two RIOI3 pips, twelve ILOGICE3 site pips.
     Small, and none on the receive path.
  3. **Bits nothing in the stack knows to write** -- the CMT. Confirmed as a
     distinct category by exhaustion, not inferred. Everything hard-block and
     analogue has failed (CMT, IDELAYE2); everything static and digital has
     worked (LUT, FF, BRAM, IBUFDS, BUFG, BUFHCE, AXI, PS7).

### Consequence for the SDR

Unchanged, and unblocked. The chain IDELAYE2 <- IDELAYCTRL <- 200 MHz <- CMT is
dead at the first link, so there is no eye scan and no ISERDES. None of that was
ever on the critical path. The fabric-flop DDR receive path is proven and was
re-verified again this session at `deg_per_sample 11.25`, `mag_cv 3.4e-4`.

`top.ex` is restored to the known-good variant. Probes preserved as
`top.ex.pllprobe`, `top.ex.mmcmprobe`, `top.ex.ccioprobe`.

---

## Track A: 200 MHz from the PS instead of a CMT — plan and first findings

The CMT was only ever a means to an IDELAYCTRL reference. PS7 exposes
`FCLKCLK[3:0]`; `Hw.Xilinx.PS7` surfaces only bit 0. Taking FCLK1 at 200 MHz
uses ONLY primitives already proven on this board (PS7, BUFG) and sidesteps the
CMT entirely.

It is also the experiment that splits the category-3 claim. "All hard analogue
blocks are dead" currently rests on two data points with a shared dependency:
IDELAYE2 needs IDELAYCTRL needs a clock. If IDELAYE2 works off a PS-sourced
reference, then IDELAYE2 was never broken and the fault is the CMT alone.

### Findings so far

  * No `/sys/class/fclk`, no `/sys/devices/soc0/.../fclk`, no
    `/sys/kernel/debug/clk`. The fclk driver is not present, so there is no
    sysfs route to set the rate.
  * `/dev/mem` exists.
  * **`:file.pread` on /dev/mem at 0xF8000170 returns `{:error, :efault}`.**
    Not a permissions failure (that would be `:eacces`) -- the read() path
    cannot serve a device-memory region on ARM. SLCR must be reached by
    **mmap**, not read/pread.

That is a small extension rather than new work: the existing Rust port already
mmaps the PL aperture at 0x40000000 for `Nervezynq.Fabric`. It needs a second
mapping of the 4 kB SLCR page at 0xF8000000.

### Gated step order (each gate is a stop-and-fix point)

  0. `Nervezynq.SLCR` — mmap 0xF8000000. Unlock with 0xDF0D to offset 0x008.
     FIRST read `FPGA0_CLK_CTRL` (0x170) and solve it against the ALREADY
     MEASURED 99.99 MHz on FCLK0: source select [5:4], DIVISOR0 [13:8],
     DIVISOR1 [25:20]. That pins the actual PLL frequency exactly and validates
     the register decode against a known answer before anything is written.
  1. Program `FPGA1_CLK_CTRL` (0x184) for 200 MHz from the same PLL.
  2. Fabric: surface `fclk_clk1` from `FCLKCLK[1]` in `Hw.Xilinx.PS7`, BUFG it,
     and retarget `dclk_div` to it so STATUS2 reads FCLK1's frequency.
     **GATE: STATUS2 must read 200 MHz before IDELAYCTRL is added at all.**
  3. Add `IDELAYCTRL` with REFCLK from that BUFG; expose its `RDY` in STATUS1
     bit 25. **GATE: RDY must read 1.**
  4. Re-add the seven `IDELAYE2` at tap 0. **GATE: must decode at
     `deg_per_sample 11.25`, `mag_cv ~3e-4` -- identical to the no-IDELAY
     control. If tap 0 does not decode, stop; the eye is meaningless.**
  5. Only then sweep taps 0..28 with `Nervezynq.EyeScan`, which is already
     written and already worked end to end (it correctly reported a closed eye
     when the eye really was closed).

Every gate has a known-answer control. That is the lesson from `bist_tone`
returning `{:ok, 11}` and from the 300 ms heartbeat window: an instrument that
has not been checked against an answer you already know cannot distinguish its
own bugs from its measurements.

### Track A results: 200 MHz obtained, no CMT involved

**No Rust was needed.** `fabric_port` already takes `<base> <len>` as argv, so
SLCR is a second instance of the same binary mapping `0xF800_0000`.
`Nervezynq.SLCR` is that, minus the PL-configured gating `Nervezynq.Fabric`
applies -- gating SLCR would be wrong, since the most useful time to read the
clock registers is when the PL is blank.

**Offset correction.** `FPGA1_CLK_CTRL` is **0x180**, not 0x184. The FPGA clock
block is four registers per FCLK, 16 bytes apart, and 0x184 is FPGA1_THR_CTRL --
a throttle register. The earlier plan in this file said 0x184. Writing a divisor
there would have done something unrelated and hard to diagnose. Caught by
writing the offsets out, not by testing.

**The calibration gate did its job.** `calibrate/1` refused to write:

    predicted 66.667 MHz vs measured 99.99 MHz
    relative_error 0.33326
    verdict: :DECODE_WRONG_DO_NOT_WRITE

The ratio is exactly 1.5 = 50/33.333. `@ps_clk_hz` was assumed to be 33.333 MHz,
the usual Zynq reference-design oscillator. **On the LibreSDR PS_CLK is 50 MHz.**
It appears in no register -- only the PLL multiplier does -- so it cannot be read,
only derived. `calibrate/1` now solves for it from one measured frequency instead
of assuming it:

    derived_ps_clk_mhz  49.995      (assumed 50.0)
    io_pll_mhz          999.9
    relative_error      0.0001
    verdict             :decode_confirmed

Had the gate not been there, a 33.333-based divisor would have been written to a
live clock-control register.

**And the payoff: no SLCR write was needed at all.**

    FCLK   srcsel   div0  div1   predicted
      0    io_pll     5     2     100.0 MHz   (matches the measured 99.99)
      1    io_pll     5     1     200.0 MHz
      2    io_pll    24     1      41.667 MHz
      3    io_pll    24     1      41.667 MHz

The FSBL already configures FCLK1 at exactly 200 MHz. Also note `FPGA0_CLK_CTRL`
raw is 0x200500 with bit 0 clear while FCLK0 is demonstrably running, so bit 0 is
not an enable gate on this part -- FCLKs run whenever the divisors are set.

**GATE 1: PASSED.** `Hw.Xilinx.PS7` now surfaces `fclk_clk1` from `FCLKCLK[1]`.
`top.ex.fclkprobe` BUFGs it and re-clocks `dclk_div` from it, so STATUS2 reads
FCLK1 through the existing divide-by-512 counter with no AXI change. On silicon:

    magic 0x45484431, FCLK1 = 199.97 MHz

**A 200 MHz reference now exists in the fabric, sourced entirely from primitives
already proven on this board.** The CMT is bypassed, not fixed.

### Remaining gates

  2. `IDELAYCTRL` with REFCLK from that BUFG; expose `RDY` in STATUS1 bit 25.
     Needs a new `Hw.Xilinx.IDELAYCTRL` component. **Gate: RDY == 1.**
     prjxray documents `HCLK_IOI3.HCLK_IOI_IDELAYCTRL_REFCLK.*` and nextpnr has
     real IDELAYCTRL packing including IODELAY_GROUP handling and per-bank
     duplication, so the static picture is good -- which, on this project, means
     nothing until the board agrees.
  3. Seven `IDELAYE2` back at tap 0. **Gate: must decode at 11.25 deg / 3e-4,
     identical to the no-IDELAY control.**
  4. Sweep taps with `Nervezynq.EyeScan`.

If gate 2 or 3 fails with a confirmed-good 200 MHz reference, that is a much
sharper result than the current one: it would mean IDELAYE2/IDELAYCTRL are
broken under openXC7 independently of the CMT, and the "all hard analogue blocks
are dead" claim would rest on two INDEPENDENT failures rather than two with a
shared dependency.

`top.ex` restored to known-good; probe kept as `top.ex.fclkprobe`.

### GATES 2 AND 3 PASSED — IDELAYE2 works. RETRACTION follows.

`Hw.Xilinx.IDELAYCTRL` added. Note it CANNOT be built alone: nextpnr hard-errors
with "Found IDELAYCTRL but no I/ODELAYs in group", so gates 2 and 3 share one
bitstream (`top.ex.idelayctrl` = the 7-lane IDELAY top + FCLK1 BUFG +
IDELAYCTRL) while remaining independent measurements. `RST` is wired to
`CTRL1[4]` rather than tied, so tie-low and explicit-pulse are a software
experiment instead of a build-time guess.

**GATE 2: RDY = 1**, both with RST tied low and after an explicit pulse. The
end-of-configuration GSR is sufficient; no reset sequencing is needed.

**GATE 3: tap 0 decodes.**

    seed 11   samples 256, ch1 deg 11.255 cv 0.01129, ch2 deg 11.25 cv 3.4e-4
    seed 18   samples 256, ch1 deg 11.25  cv 3.4e-4,  ch2 deg 11.245 cv 0.01129
    seed 16   deg 62.106 cv 0.376  -- the capture-phase artifact, also seen on
                                      known-good bitstreams; not a failure
    zero-words: 0 on every seed

Compare the same design with NO IDELAYCTRL: 1024 of 1024 words exactly zero on
all eight taps.

### RETRACTION: "everything hard-block and analogue is dead" was wrong

That claim rested on two failures — CMT and IDELAYE2 — and they were never
independent: IDELAYE2 needs IDELAYCTRL needs a 200 MHz clock. Give it a clock
the PS provides and **IDELAYE2 works correctly under openXC7**. It was never
broken. Corrected picture:

  * **CMT (PLLE2/MMCME2): genuinely broken** under openXC7 on this part.
    Unchanged, and now a single isolated failure rather than a pattern.
  * **IDELAYCTRL: works.** RDY asserts and stays asserted.
  * **IDELAYE2: works.** Passes data and decodes to the BIST tone at tap 0.

The generalisation was reached from two data points sharing a hidden
dependency. Worth remembering: "several things in a category fail" is only
evidence for the category when the failures are independent, and here that had
to be engineered rather than assumed.

### Also: a routed bitstream that was functionally broken

Seed 6 routed, loaded, showed correct magic, a running heartbeat and RDY=1 --
and returned AD9363 product ID `0x01` instead of `0x0A`. SPI data was simply
wrong. Seeds 8, 11, 16 and 18 all return `0x0A`. Same class as the CE routing
bug: place & route reporting success while producing a design that does not
work. Any single-seed result on this project needs a second seed before it
means anything, INCLUDING a negative one.

### Now unblocked

The eye scan. `Nervezynq.EyeScan` is already written and already demonstrated it
reports a genuinely closed eye. Rebuild taps 0..28 from `top.ex.idelayctrl`
(which now carries IDELAYCTRL), several routed seeds per tap, and sweep. For the
first time there is a real receive-margin measurement available on this board.

---

## STATE OF PLAY (supersedes anything above it that disagrees)

This file is long and contains several retractions. Where an earlier section
conflicts with this one, this one is current.

### Proven on silicon, this board

    LUT / FF / carry / BRAM                  works
    IBUFDS (LVDS in), BUFG, BUFHCE           works
    PS7, AXI4-Lite slave, capture BRAM       works
    PS FCLK1 as a 200 MHz fabric clock       works  (199.97 MHz measured)
    IDELAYCTRL                               works  (RDY = 1)
    IDELAYE2                                 works  (decodes at tap 0)
    Fabric-flop DDR receive path             works  (11.25 deg/sample, cv 3.4e-4)

### Broken on silicon, this board

    PLLE2_BASE / MMCME2_BASE (any PL CMT)    never locks, ~15 bitstreams

    This is now an ISOLATED failure, not an instance of "hard blocks don't
    work". IDELAYCTRL and IDELAYE2 are hard blocks with analogue content and
    both work. The earlier "everything hard-block and analogue is dead" claim
    is RETRACTED -- it rested on two failures with a shared dependency.

### Not yet tested on silicon

    ISERDESE2   builds clean via IOBDELAY="IFD"; never captured on hardware.
                The IFD path runs through IDELAYE2, which now works, so this is
                unblocked and is the obvious next primitive to prove.

### nextpnr-xilinx defects found, with addresses

  1. BRAM x9 parity port L/U mapping  -- guarded locally in `fasm.cc`
  2. SLICE CE routing                 -- worked around with yosys `dffunmap`
  3. ISERDESE2 direct-D site variant  -- `IOBDELAY="IFD"` avoids it
  4. ISERDES OFB/OCLK tie-off routing -- leave those pins unconnected
  5. PLL/MMCM `TABLE[9:0]` hardcoded   -- real, but not the CMT lock cause

### The rule that keeps being re-learned

Place & route reporting success does not mean the design works. Seed 6 of the
IDELAYCTRL build routed, loaded, showed correct magic, a running heartbeat and
RDY=1, and returned AD9363 product ID `0x01` instead of `0x0A`. Seeds 8, 11, 16
and 18 all returned `0x0A`.

**Any result on this project needs a second seed before it means anything,
including a negative one.** A single bad seed is indistinguishable from a real
hardware failure, and has twice been mistaken for one.

### Board bring-up facts worth not rediscovering

  * `axi_clk` = 99.99 MHz. Measure it with the STATUS1 heartbeat and a window
    UNDER 150 ms -- the counter is 24 bits and wraps at 167 ms.
  * PS_CLK on the LibreSDR is **50 MHz**, not the usual 33.333. It is in no
    register; derive it from a measured FCLK.
  * IO PLL is 999.9 MHz. FCLK0 = /10 = 100 MHz, FCLK1 = /5 = 200 MHz already.
  * `FPGA1_CLK_CTRL` is 0x180. 0x184 is FPGA1_THR_CTRL.
  * SLCR needs mmap; `pread` on /dev/mem returns `:efault` for non-RAM.
  * Allow 200 ms after `PL.reload` before the first SPI transaction.
  * `AD9363.bist_tone/4` returns `{:ok, reg}`, not `:ok`.

---

## First receive-margin measurement on this board

    tap  seed  ok/n  deg/sample  mag_cv    verdict
      0     4   2/2      11.250   3.4e-4   OPEN
      4     0   2/2      11.250   1.1e-2   OPEN
      8     1   2/2      11.250   3.4e-4   OPEN
     12     2   1/2      11.250   1.1e-2   OPEN
     16     1   2/2      11.251   1.1e-2   OPEN
     20     9   1/2      11.252   1.1e-2   OPEN
     24     1   2/2      11.250   3.4e-4   OPEN
     28     0   2/2      11.250   3.4e-4   OPEN

    eye open over every tap sampled, 0..28

16 bitstreams: 8 taps x 2 routed seeds, each tap synthesised separately.

### What it means, and the limit it exposes

The eye does not close anywhere in IDELAYE2's range, and the arithmetic says it
cannot. 31 taps at the datasheet-nominal ~78 ps is about 2.4 ns of sweep. At
4 Msps the AD9363's DATA_CLK is 16 MHz, so one DDR unit interval is
1/(2 x 16 MHz) = 31.25 ns. **The whole delay line covers roughly 8 percent of a
unit interval.** It physically cannot reach an edge at this data rate, so "open
at every tap" is the expected result and not a measurement of the eye's width.

The useful engineering conclusion stands and is now quantified rather than
assumed: **at the 1 Msps HaLow target, receive timing margin is not a risk.**
Sweeping the sampling instant across 8 percent of a UI does not perturb the
decode at all -- `deg_per_sample` stays at 11.25 and `mag_cv` stays at its floor.

To actually measure eye WIDTH the UI has to shrink to the same order as the
delay range. DATA_CLK is 4 x Fs, so:

    Fs 4 Msps    DATA_CLK  16 MHz   UI 31.2 ns   delay covers ~8%
    Fs 8 Msps    DATA_CLK  32 MHz   UI 15.6 ns   ~15%
    Fs 30.72     DATA_CLK 123 MHz   UI  4.1 ns   ~59%
    Fs 61.44     DATA_CLK 245 MHz   UI  2.0 ns   ~118%  <- edges reachable

So a real eye-width number needs the transceiver near its maximum rate. That is
a worthwhile experiment for characterising the board, and completely orthogonal
to the beacon.

Caveat kept in view: taps are uncalibrated in absolute time (IDELAYCTRL trims
against the 200 MHz reference, but nothing here converts taps to picoseconds).
The RELATIVE conclusion -- 31 taps cannot traverse a 31 ns UI -- does not depend
on the calibration.

### Two harness bugs this sweep caught, both of which faked a result

  * **`frame_integrity/1` is not a quality metric and must not gate anything.**
    It reads exactly 0.25 -- chance for a 4-phase cycle -- on captures that
    decode perfectly, because it depends on where in the RX_FRAME cycle the
    capture started, and that is random mod 4. It read 0.25 on the known-good
    `bank.bin` control in the same session it read 1.0 on another run of the
    same bitstream. Gating `decodes?/1` on `integrity > 0.99` declared a fully
    open eye CLOSED at all eight taps. The gate is now `deg_per_sample` and
    `mag_cv`, the two things the BIST tone actually predicts.
  * **`--skip-synth` must not span taps.** `@idelay_tap` is a module attribute
    baked in at elaboration, so reusing the netlist across taps would have
    emitted eight identical bitstreams under eight names and produced a
    perfectly flat, perfectly meaningless eye. Caught before running, by
    reading the build script rather than by testing.

The first of those is exactly the failure the module's own docstring warns
about, written one turn earlier. Writing the warning did not prevent the bug;
the tap-0 control did, because the report says outright not to believe a
closed eye until tap 0 has been shown to decode.

### Multi-seed policy, now in the harness

A tap is OPEN if ANY seed decodes and CLOSED only if EVERY seed fails, with up
to 3 captures per seed to ride out the random start phase. Taps 12 and 20 came
back 1/2 -- one seed decoded, the other did not. Under the old single-seed
method those two would have been notches in the middle of an open eye.

---

## Phase 0 done: the fixes are now on branches, with a harness

### Branches

`openxc7/nextpnr-xilinx` was on `stable-backports` with `fasm.cc` **modified
but uncommitted**, and versioning done by hand-copied `.orig` files. Both
`.orig` files were verified byte-identical to HEAD before deletion, so nothing
was lost — git now holds the stock version as the parent commit.

    stable-backports              upstream + one imported placement backport
    fix/bram-x9-parity-guard      b4349d8, the guard, ALONE and upstreamable
    work/tier1                    build head; the fix branches merge here

`BRANCHES.md` in the nextpnr repo records the convention and the remaining
branch names. One branch per defect, each off `stable-backports`, because these
fixes are worth more to other people than to us and that only works if they are
separable.

Note: the docs commit initially landed on `fix/bram-x9-parity-guard`, which
would have made it unfilable as-is. Moved to `work/tier1` with `git branch -f`.

### `ehdl/scripts/regress.sh`

Asserts a verdict per reproducer, **including the ones expected to fail**:

    control          plain            ok       the path the radio actually uses
                     iddr             ok
    expected FAIL    iserdes_direct   pnr      defect #3, flips when fixed
                     iserdes_ofb      frames   defect #4, flips when fixed
    expected pass    iserdes_ifd      ok

    5 passed, 0 unexpected

Two seeds per reproducer, and a verdict only counts if both agree — seed
disagreement is reported as its own outcome rather than being resolved.

`--slow` adds the full radio build. The footer states what the script does NOT
test: the board. Nothing is finished until the radio still decodes at
`deg_per_sample 11.25`, `mag_cv 3.4e-4`.

### The harness found two bugs in itself before finding any in nextpnr

  1. `local src=$1 seed=$3 base=..._$seed` — bash expands every word of a
     `local` command before performing any of its assignments, so `$seed` was
     still unset. Under `set -u` that aborted the function and every reproducer
     reported an empty verdict: **5 unexpected failures, all fictional.**
  2. The seed-agreement check split a string with a leading space, so the empty
     first field counted as a second distinct verdict and every reproducer was
     reported as seed-dependent — including ones where both seeds plainly
     agreed (`1:ok 7:ok`).

Both would have been read as "the toolchain changed" by anyone who trusted the
first run. This is the fourth instrument on this project to produce confident,
plausible, wrong output before being checked against a known answer, and the
argument for building the expected-FAIL entries in from the start: a harness
that can only report success cannot be caught lying.

### Ready to start

Tier 1, in order: #4 ISERDES OFB/OCLK tie-offs (`pack_io_xc7.cc`, extend
`disconnect_constant_port`), then #6 `ILOGICE3_IFF` mux (`fasm.cc`, write
`IFFDELMUXE3` not `IDELMUXE3`), then file #1a upstream with its reproducer.
`regress.sh` will flip `iserdes_ofb` from `frames` to `ok` when #4 lands, which
is the pass condition.

---

## Tier 1: defects #4 and #6 fixed, regression green, HARDWARE ACCEPTANCE PENDING

### Branches

    stable-backports              upstream + imported placement backport
    fix/bram-x9-parity-guard      b4349d8  #1a  guard only, upstreamable
    fix/iserdes-ofb-tieoff        74ca5e6  #4   pack_io_xc7.cc
    fix/ilogic-iffdelmux                   #6   fasm.cc
    work/tier1                    build head, merges all three

### #4 — disconnect constant OFB/OCLK/OCLKB on ISERDESE2

`pack_io_xc7.cc`. The packer already did this for `CLKDIVP`, and for
`D`/`SHIFTIN1`/`SHIFTIN2` under `IOBDELAY=IFD`; this extends it to the
remaining three. `disconnect_constant_port` only acts on `$PACKER_GND_NET` /
`$PACKER_VCC_NET`, so a genuinely driven `OCLK` (which the MEMORY interface
types use) is untouched, and `OFB` is additionally guarded on `OFB_USED` so the
"tied while OFB_USED=TRUE" case still reaches the existing `log_error`.

Verified: the two undocumented pips are GONE from the t4 FASM
(`RIOI_OLOGIC0_OFB.IOI_OLOGIC0_D1`, `IOI_OCLKM_0.IOI_IMUX31_1`) while the real
`ISERDES.IN_USE` / `NETWORKING.DDR.W4` / `IDELAY_Y0.IN_USE` configuration is
unchanged. `iserdes_ofb` flipped `frames` -> `ok`.

### #6 — ILOGICE3_IFF must configure IFFDELMUXE3, not IDELMUXE3

`fasm.cc`. Writes `IFFDELMUXE3.P0` when an IDELAYE2 drives D, leaves it
implicit otherwise, and writes `IDELMUXE3` only when `O` is actually connected.

**A trap caught before building rather than after.** The obvious symmetric form
is `if (delayed) P0 else P1` — and that would have broken every family except
virtex7. zynq7, artix7, kintex7 and spartan7 document only `IFFDELMUXE3.P0`;
only virtex7 carries `IFFDELMUXE3.P1 = !28_116`. Emitting a literal
`IFFDELMUXE3.P1` would fail to resolve in fasm2frames. P1 is the unwritten
default, so only P0 is ever emitted. The virtex7 entry is what proves the
encoding, which is the one time cross-family comparison has paid off.

### Regression, on work/tier1

    control        plain            ok
                   iddr             ok      <- #6 did not break the IDDR path
    expected FAIL  iserdes_direct   pnr     <- defect #3, still open
    expected pass  iserdes_ifd      ok
                   iserdes_ofb      ok      <- #4 landed

    5 passed, 0 unexpected

`regress.sh` must be run from `work/tier1`. Running it on a fix branch reports
the OTHER fixes as still-broken, because a fix branch is based on
`stable-backports` and does not contain them. That is the harness working
correctly and it is confusing anyway; there is now a comment saying so.

### NOT YET VALIDATED ON HARDWARE

Three radio bitstreams were built on `work/tier1` (seeds 3, 6, 7). Seed 7
captured real data — 0 zero-words, `mag_mean 1714.6` — but decoded at the
capture-phase artifact (62.139 / 0.376) rather than the acceptance criterion.
Seeds 3 and 6 hit the post-reload SPI settle failure. Before the retry sweep
could finish, **the board dropped its network**:

    Read from remote host 172.31.248.125: No route to host

This is the recurring USB-link drop that needs a physical replug; it is not
attributable to the fixes. Neither fix touches the fabric-flop receive path —
#4 only affects designs instantiating ISERDESE2, #6 only designs instantiating
IDDR, and the radio instantiates neither — so the expected result is "no
change". **That expectation has not been confirmed and must not be recorded as
though it had been.**

To finish, once the board is back:

    tier1_s{3,6,7}.bin.gz are already staged on the HTTP server
    load, bring up, capture, and require deg_per_sample 11.25 / mag_cv 3.4e-4
    on at least two of the three seeds

Only then are #4 and #6 done, and only then should #1a/#4/#6 be filed upstream.

### HARDWARE ACCEPTANCE: PASSED. Tier 1 is done.

    seed  7   deg 11.250  cv 3.4e-4   PASS
    seed 10   deg 11.250  cv 3.4e-4   PASS
    seed 15   deg 11.247  cv 1.1e-2   PASS

Three independent `work/tier1` bitstreams of the unmodified radio top, each
loaded, brought up and decoded against the AD9363 BIST tone. Criterion was
`|deg_per_sample - 11.25| < 0.05` and `mag_cv < 0.05`. Defects #1a, #4 and #6
are validated on silicon and ready to file upstream.

### The seed lottery nearly produced a false regression

Seeds 3 and 6 both routed and both returned AD9363 product ID `0x00` — the
transceiver not answering SPI at all. With only those two in hand the obvious
reading was "the Tier 1 patches broke the radio", which would have been wrong
and would have cost a day.

Two things prevented it:

  1. **The control.** `/root/bank.bin`, built before any of these fixes,
     returned product ID `0x0A` on the same board minutes earlier. Board and
     transceiver were fine, so whatever was wrong was per-bitstream.
  2. **The rule.** Checking every seed rather than the first: seed 7 returned
     `0x0A` and went on to pass cleanly.

Final tally on this design: **3 of 6 routed seeds are functionally broken**, all
in the same way (SPI dead, fabric otherwise healthy — magic and heartbeat
correct). That is a far higher rate than previously assumed and it is worth
restating: on this toolchain a routed bitstream has roughly even odds of being
functionally wrong, and the failure is silent everywhere except the one register
you happen to read. This is defect #2's territory and is the strongest argument
yet for prioritising it.

### Network note

The board came back on ethernet as well as usb0; `nerves.local` still resolves
to the usb0 address `172.31.248.125`. The file server is now bound to
`0.0.0.0:8101` and is reachable at both `172.31.248.126` (usb0) and
`192.168.217.63` (ethernet), so a USB drop no longer takes the transfer path
with it. Prefer the ethernet address — usb0 has dropped twice.

---

## Tier 2: defect #3 SOLVED, and it was not the suspected cause

### The instrument first

`tool/router-arc-diag` adds `NEXTPNR_EXPLAIN_ARC` to router2. Before the fatal
"Failed to route arc", it walks backward from the sink reporting for each
uphill pip whether it is usable, occupied, or refused by the architecture --
`checkPipAvail()` collapses the last two, `getBoundPipNet()` separates them --
checks `getPipsUphill`/`getPipsDownhill` symmetry, and runs a forward
reachability search under exactly the router's own availability rules.

That last part is the one that earns its keep. It splits every routing failure
into two cases with different fixes:

    sink reachable    -> model and availability are fine; the fault is in the
                         router's SEARCH
    sink unreachable  -> the router is right to fail; the model or the
                         availability rules forbid every path

### #3: ISERDESE2 direct-D

The standing hypothesis was `usp_pip_hard_unavail`'s site-variant gate --
`pd.site <= size()` looked like an off-by-one and variant 0 is exempt from the
check. **That hypothesis was wrong.** The instrument showed a complete usable
path, source to sink, and forward reachability confirmed the sink 6 hops away.

The actual cause is in `reserve_wires_for_arc`. It walks back from a sink
reserving a forced path and stops when a wire has more than one candidate
predecessor -- but it counted **pips**, not distinct predecessor **wires**.
Several pips routinely join the same wire pair: a site mux reached through both
its true and inverted input, once per site variant. `DINV_OUT` has six uphill
pips and all six come from the same wire `D`, so a chain with exactly one
predecessor read as ambiguous and the walk aborted at the first hop. General
interconnect rarely looks like this, which is why this only ever bit inside
sites and looked like a site or database problem.

One-line fix (`w != next_cursor`). `t1_iserdes.v` now routes on seeds 1, 7 and
25 -- previously 0/3, deterministically.

### #2 is NOT the same bug

The obvious next thought was that CE nets fail the same way -- `CEUSEDMUX_OUT`
also has many parallel uphill pips. Measured before and after on the 252-FF
reproducer, the numbers are **identical**:

    nCE nSR  routed          nCE nSR  routed
      1   0    2/3             0   1    3/3
      2   0    1/3             0   2    3/3
      4   0    0/3             0   4    3/3

Unchanged. Separate defect, separate mechanism, misleadingly similar error text.

### #2 is a SEARCH problem, not a model problem -- and the first answer was wrong

Pointing the instrument at a failing CE arc first reported:

    sink NOT reachable from source over 200003 wires

which would have said "the router is correct to fail; fix the model". That was
the 200k-wire **cap**, not an exhausted search. The instrument now distinguishes
"exhausted" from "hit the cap" and refuses to claim unreachability for the
latter. With the cap raised:

    sink IS reachable in 12 hops over 1729095 wires

So #2 is the same class as #3 -- the graph allows the arc and the router's
search fails to find it -- with a different specific cause. That is a real
constraint on where to look next, and the first, wrong answer would have sent
the search into prjxray instead of into router2.

This is the fifth time on this project an instrument produced a confident wrong
answer before being made to distinguish "I found nothing" from "I stopped
looking".

### Validation

    regress.sh on work/tier1        5 passed, 0 unexpected
                                    iserdes_direct flipped pnr -> ok

    hardware, radio top, work/tier1
      seed  1   deg 11.250  cv 3.4e-4   PASS
      seed 18   deg 11.248  cv 1.1e-2   PASS

A router change touches every design, so the hardware criterion matters more
here than for #4 or #6. Seeds 2 and 13 failed bring-up (SPI dead) -- the same
even-odds seed lottery as before, unrelated to the change.

### Branches

    tool/router-arc-diag              de4edbe  the instrument
    fix/router-reserve-parallel-pips  7274165  #3
    work/tier1                        merges everything

### Next

#2, with a known starting point for the first time: the arc is reachable in 12
hops, the router does not find it, and `reserve_wires_for_arc` is now ruled out.

---

## DRC added; BRAM x9 investigated and my hypothesis did NOT hold

### DRC: an I/ODELAY with no IDELAYCTRL is now refused

`fix/idelay-requires-idelayctrl`. Goes exactly where `pack_idelayctrl()`
previously returned early, and mirrors the check that already existed one
screen below it -- "IDELAYCTRL but no I/ODELAYs" and "I/ODELAYs but no
IDELAYCTRL" are the same mistake from opposite ends.

    ERROR: Found 1 I/ODELAY cell but no IDELAYCTRL (e.g. 'u_idelay'). An
    I/ODELAY without an IDELAYCTRL on a 200 MHz reference never calibrates and
    its output is dead -- the design would build and load and capture nothing.
    Instantiate IDELAYCTRL, or remove the delays.

Reproducer `t6_idelay_no_ctrl.v`, expected verdict `pnr`. Regression is 6/6.

**The check immediately caught two of our own reproducers.** `t4_iserdes_idelay.v`
and `t5_no_ofb.v` both instantiate IDELAYE2 with no IDELAYCTRL -- they were
never valid designs, and had they ever been loaded they would have captured
nothing. Both now carry an IDELAYCTRL, with a comment saying the REFCLK is
deliberately the wrong frequency because those files are toolchain reproducers
that never reach a board.

### BRAM x9: NOT the simple nextpnr bug I proposed

The proposal was that both L and U parity pins are documented, nextpnr drives
only L, and driving both would fix it. Checked, and it does not survive:

  * prjxray has exactly TEN RAMB36-scope features
    (`BRAM36_{READ,WRITE}_WIDTH_{A,B}_1`, `EN_ECC_{READ,WRITE}`,
    `RAM_EXTENSION_{A,B}_{LOWER,NONE_OR_UPPER}`). **There is no parity routing
    or output-mux feature at all.**
  * Both halves are already configured identically: `write_bram_width` maps
    width 9 to `actual_width = 4` for BOTH halves, and the 9th bit is the
    RAMB36-scope `BRAM36_*_WIDTH_*_1` leftover bit, which openXC7 does emit.
  * So the halves are not misconfigured. The problem is the FUSED SITE MODEL:
    the RAMB36's `DOPBDOP0` maps to the L half's physical pin only, and a net
    cannot have two drivers, so "drive both" is not available as a fix.

What that leaves is a genuine unknown: in a real x9 RAMB36, which single
physical pin carries the parity bit for both halves' addresses, and what
selects it. Nothing in prjxray answers that. This is category-3 fog, not a
software bug, and my "6 nextpnr defects to 2 db gaps, bet on nextpnr" heuristic
was wrong here.

**The guard stays**, now for a tested reason rather than an assumed one.

Two cheap experiments remain, if it ever matters:

  1. Route the user's parity net from `DOPBDOPU0` instead of `DOPBDOPL0` and
     re-run the 4096x26 capture. Correct on ODD addresses and zero on even
     would prove each half carries only its own addresses' parity, and that a
     single-pin model is impossible -- which would mean Vivado never uses x9
     RAMB36 with parity at all.
  2. If so, the fix is not in nextpnr's FASM writer but in memory inference:
     stop choosing x9 for a RAMB36 when the parity bit is needed, and use x18
     or x36. That is a yosys-side decision and needs no silicon knowledge.

Neither is on the critical path. The banked 4096x26 design maps to x36, avoids
the parity port entirely, and is what the radio ships.

### Branch state

    fix/bram-x9-parity-guard          guard only, unchanged, still correct
    fix/iserdes-ofb-tieoff            #4
    fix/ilogic-iffdelmux              #6
    fix/router-reserve-parallel-pips  #3
    fix/idelay-requires-idelayctrl    DRC
    tool/router-arc-diag              instrument + cap-vs-exhausted fix
    work/tier1                        merges all of the above

A note on process: the DRC commit initially landed on `work/tier1` instead of
its own branch, because a multi-line `git commit -m` sent through tmux breaks
at every newline. Recovered by cherry-picking onto a fresh branch off
`stable-backports`. Commit messages go in a file (`git commit -F`), always.

---

## IDELAY_TYPE = VAR_LOAD works. The eye scan is now one bitstream and 20 seconds.

### What changed

`Hw.Xilinx.IDELAYE2` gained `c`, `ld`, `ce`, `inc`, `cntvaluein[4:0]` and
`cntvalueout[4:0]`. `top.ex.varload` runs all seven lanes in `VAR_LOAD` with:

    CTRL1[12:8]   tap value
    CTRL1[13]     LD
    STATUS1[29:25] lane-0 CNTVALUEOUT
    C             = axi_clk

Two decisions worth keeping:

  * **`C` is the AXI clock, not the 200 MHz reference.** The reference goes to
    IDELAYCTRL, which calibrates the tap chain independently; `C` only has to
    be the clock `LD`/`CNTVALUEIN` are synchronous to. Using axi_clk keeps the
    whole tap path in one domain and removes every synchroniser.
  * **`LD` is level-sensitive, not a pulse.** IDELAYE2 reloads CNTVALUEIN on
    each rising `C` edge while LD is high, so holding it high just reloads the
    same value. Software writes {tap, LD=1} then {tap, LD=0}. No edge detect,
    nothing to get wrong.

### CNTVALUEOUT is the reason to prefer VAR_LOAD even without moving the tap

    tap written   0  1  7 15 16 23 31  4
    CNTVALUEOUT   0  1  7 15 16 23 31  4

Exact across the full range. With `FIXED`, the only evidence a tap was applied
is the bitstream you believe you loaded -- and this project has twice been
wrong about that. VAR_LOAD turns it into a register read.

### The full sweep, in one bitstream

    32 taps, decode at each, ~20 seconds total
    previously: 32 bitstreams, each with its own seed lottery, ~hours

    taps 0..31: 30 OPEN on the first pass, taps 17 and 30 flagged

Taps 17 and 30 showed the familiar `deg 62.1 / cv 0.38 / mag_mean 1714`
signature. That is the random capture-start-phase artifact, not a notch, and
re-testing with 12 captures each confirms it:

    tap 17 -> 11.247 / 1.1e-2      tap 30 -> 11.250 / 3.4e-4
    tap 16 -> 11.255 / 1.1e-2      tap 31 -> 11.250 / 3.4e-4

**32 of 32 taps open.** Two independent arguments say that is the truth rather
than a measurement failure: the artifact is a known signature seen on
bitstreams already proven good, and a real eye closes CONTIGUOUSLY at its
edges, not at two isolated interior taps surrounded by open ones.

Consistent with the earlier arithmetic: 31 taps is roughly 8% of a 31.25 ns
unit interval at 4 Msps, so the delay line cannot reach an edge at this rate.

### What this unblocks

Task #59, eye width at a high sample rate, is now cheap. The whole experiment
becomes: raise Fs so the UI shrinks toward the delay range, then run the same
20-second sweep. At 61.44 Msps DATA_CLK is 245 MHz and one UI is ~2 ns, which
the ~2.4 ns delay range can traverse -- so the edges become reachable and the
sweep returns a real width instead of "open everywhere".

No new bitstream is needed per tap ever again.

### Still true, and still the tax on everything

Seed 10 of this design routed and failed bring-up; seed 5 worked. Three of the
routed seeds tried across recent builds have been functionally broken. Defect
#2 remains the most expensive open item on the project.

---

## The eye finally closes. First real receive-margin numbers for this board.

One bitstream, `vl_s5` (VAR_LOAD), tap swept 0..31 at each sample rate. The BIST
tone is at Fs/32, so `deg_per_sample = 11.25` stays the criterion at every rate
-- the oracle scales with the experiment, which is why this works at all.

    Fs (Msps)  DATA_CLK   UI (DDR)   open taps
        4       16.00      31.2 ns   28/32   gaps at 8,9,11,17 = capture artifacts
        8       32.01      15.6 ns   30/32   gaps at 6,28      = capture artifacts
       16       64.00       7.8 ns    4/32   [0,1,2,3] CONTIGUOUS
       20       79.99       6.2 ns    0/32
       30.72   122.92       4.1 ns    0/32
       40      160.11       3.1 ns    0/32
       61.44   363.61 (!)             0/32

**The eye closes between 32 and 64 MHz DATA_CLK.** At 64 MHz only the four
lowest taps decode, and they are CONTIGUOUS -- that is the shape of a real
timing edge, not the scattered single-tap dropouts that the capture-phase
artifact produces. At 80 MHz and above, nothing.

### The important caveat: this is one edge, not a width

We delay the DATA lanes and deliberately not DATA_CLK. So the tap can only push
the sampling point one way, and what the sweep sees is the eye's TRAILING edge.
The open band at 64 MHz runs [0..3] -- it starts at tap 0, the minimum -- which
means the optimum lies at or before zero delay and we are already against the
end of the instrument.

**"4 taps open" is therefore a LOWER BOUND on the eye, not its width.** The eye
at 64 MHz may well be wider, centred at a delay we cannot reach. Measuring the
true centre needs the CLOCK delayed instead, or both delayed independently.
That is a real limitation of the current design, not of the method.

### What it means

    1 Msps  (HaLow target)   4 MHz DATA_CLK   enormous margin
    4 Msps                  16 MHz            28/32 taps, comfortable
    8 Msps                  32 MHz            30/32 taps, comfortable
    16 Msps                 64 MHz            MARGINAL -- minimum delay only
    >= 20 Msps                                does not work at all

So the fabric-flop receive path tops out somewhere around 16 Msps, and the
earlier claim that it "works at 32 MHz DATA_CLK with a wide-open eye" is now
confirmed with a number attached rather than asserted.

Two things this makes concrete that were previously arguments:

  * **This is where ISERDESE2 would earn its keep.** It moves capture into the
    IOB with characterised timing instead of fabric flops, which is exactly the
    budget that ran out between 32 and 64 MHz.
  * **The DIFF_TERM question stops being theoretical.** We run LVDS
    unterminated -- nextpnr silently ignores DIFF_TERM and prjxray documents no
    on-die termination bit. At 16 MHz that is invisible. At 64 MHz, where the
    eye is nearly shut, reflections on an unterminated pair are a plausible
    contributor and no longer something to wave off.

### Anomaly, flagged not glossed

At 61.44 Msps the DATA_CLK counter reads **363.61 MHz** against a predicted
245.76. Every other rate matched its prediction to within 0.1%. Either the
AD9363 did not land on the requested rate, or the 9-bit divide-by-512 counter
in the DATA_CLK domain stops counting reliably somewhere above 160 MHz. The
`0/32` verdict at that rate is therefore not trustworthy on its own -- though
it agrees with 20, 30.72 and 40 Msps, which are trustworthy.

### Cost

The whole ladder -- 7 rates x 32 taps, 224 decodes -- ran in about three
minutes on ONE bitstream. Under the old FIXED-tap scheme this experiment was
224 bitstreams and 224 seed lotteries, which is why it had never been done.

---

## Stage A, measured: PIO is ~0.94 Mwords/s, and the milestone does not need DMA

### The readout path, measured rather than assumed

    single read32                      4.6 k reads/s   (215 us each)
    read_block, fixed overhead         ~344 us per call
    read_block, marginal per word      ~1.06 us
    => sustained                       ~0.94 M words/s

The fixed 344 us is the Elixir/port round trip; the 1.06 us marginal is the
Zynq AXI GP port itself. ~100 PL clocks per 32-bit non-posted read on a
strongly-ordered device mapping is the known character of GP PIO, not a defect
in our slave. **This is a platform property and cannot be optimised away** --
it is exactly why every serious Zynq design puts sample data on an HP port.

### A measurement error, caught by verifying

The first pass reported 59 M words/s at a 16384-word block and a flat ~275 us
regardless of size. That was nonsense. `read_block` reads N CONSECUTIVE
ADDRESSES, and any span past the 4 kB mmap window returns

    {:error, "span 0x28..0x4028 is outside the 0x1000-byte window at 0x40000000"}

immediately, touching no hardware. The timing loop discarded the return value,
so it was timing an error path. The tell was there to read -- cost flat in N,
and non-monotonic across sizes -- and it was only caught by checking that the
returned data was the right length and plausible.

Sixth instrument on this project to give a confident wrong answer. The pattern
is now completely consistent: **every one was caught by checking the result
against something already known, and none by inspecting the code.**

### The consequence, and it is good news

DATA_CLK = 4 x Fs and the buffer stores one word per DATA_CLK cycle, so
CONTINUOUS capture at 1 Msps needs 4 M words/s. PIO gives 0.94. Short by 4.2x,
and fabric-side sample assembly (packing I1/Q1/I2/Q2 into whole words rather
than storing raw DATA_CLK cycles) recovers most but not all of it.

**But the milestone does not need continuous capture.** A HaLow beacon is
1-2 ms. At 4 M words/s that is 4000-8000 words. A 16384-word buffer holds 4 ms
-- a whole beacon with margin -- and reading it out takes ~17 ms, which nobody
is waiting on.

So Stage A splits cleanly, and the cheap half is the half we need:

    A1  BURST capture -- deepen the buffer to 16384 words (~12 BRAMs of the
        140 available), memory-map it into the AXI window so read_block can
        stream it instead of poking cap_rd_addr per word, and add a trigger.
        No DMA, no device tree change, no reserved memory, no AXI HP master,
        no new primitives. Unblocks "decode one real beacon".

    A2  CONTINUOUS capture -- AXI HP + DMA, as originally planned. Required
        for a real receiver, not for the milestone. Also needs a firmware
        rebuild: Linux currently owns all 1 GiB (System RAM 0x0-0x3fffffff,
        no reserved-memory node), so the PL has nowhere to write.

### Why memory-mapping the buffer matters more than it looks

Today each captured word costs THREE bus transactions: write cap_rd_addr, read
status3, and the address write is not even pipelined. Mapping the buffer as an
address range makes it one transaction per word inside a single port round
trip -- roughly 3x fewer transactions and one round trip instead of N.

The AXI window is currently 0x1000 (1024 words). It needs widening to cover the
buffer; that is the `len` argument to `fabric_port` plus the slave's address
decode.

### Revised Stage A order

    1. widen AXI window + memory-map the capture buffer   (biggest win/effort)
    2. deepen buffer 4096 -> 16384
    3. trigger (RX_FRAME edge, or software arm as today)
    4. THEN the beacon
    5. A2/DMA only when continuous operation is actually wanted

---

## Stage A1 implemented across four layers. BUILT AND UPLOADED, NOT YET VERIFIED.

The goal: remove the per-word userspace round trip from capture readout.
Measured cost was ~215 us per word as its own call versus ~1.06 us of actual
bus time, so the round trip was ~200x the work.

### What changed

**1. `Hw.AXI4Lite.Slave`** -- two new one-cycle strobes:

    output :status3_rd, 1   pulses when a read of STATUS3 COMPLETES
    output :ctrl2_wr, 1     pulses when a write to CTRL2 commits

`status3_rd` fires on the completed RVALID/RREADY handshake, not on entry to
`:resp`, so a master holding RREADY low does not advance a pointer under a read
it has not taken.

Both are needed. An earlier attempt used only `status3_rd` and derived "seek"
by comparing CTRL2 against the pointer -- that is broken, because the two
differ on every cycle after the first auto-advance and the pointer gets dragged
back continuously. Caught by reading it back, before building.

**2. `top.ex.autoinc`** -- `cap_rd_ptr` auto-advances on `status3_rd` and loads
from CTRL2[11:0] on `ctrl2_wr`, with load taking priority so a seek arriving in
the same cycle as a read lands where the seek asked. `cap_rd_addr` now comes
from the pointer instead of directly from CTRL2, so "seek then read N" works
without seeking before every word.

**3. Rust port** -- new `OP_READ_REPEAT = 0x06` and `Fabric::read_repeat`.
Reads the SAME address N times. That is not `read_block`, which walks
addresses: in front of an auto-advancing buffer each read of ONE address
returns the next word. `read_block` would also run off the end of the 4 kB
window, which is exactly the error that invalidated the first throughput
measurement.

**4. `Nervezynq.Fabric.read_repeat/2`** -- encode/decode for the new opcode.

Expected result: a 4096-word capture in ONE round trip, ~344 us + 4096 x
1.06 us = ~4.7 ms, against ~15 minutes word-by-word.

### Build state

  * Bitstream: seed 9 routed, staged as `ai_s9.bin.gz`. Only 1 of 10 seeds
    routed -- worse than usual, and worth watching.
  * Firmware: built and uploaded to **partition A**, board rebooted.

### NOT VERIFIED -- this is the top of the next session

Nothing above has been exercised on hardware. After the reboot the board did
not come back: usb0 down, ssh times out on 172.31.248.125, `nerves.local` does
not resolve. Most likely a USB gadget re-enumeration needing a physical replug
-- it has happened twice before -- but a partition A/B boot problem is also
possible and has ALSO happened before (`mix upload` wrote A, board booted B).

On reconnect, in order:

  1. Confirm the new firmware is actually running: `Nervezynq.Fabric.read_repeat/2`
     must EXIST. If it is undefined, the board booted the old partition and the
     upload needs redoing or `nerves_fw_active` needs checking.
  2. Load `ai_s9.bin.gz`, bring up, then compare:
         seek CTRL2 to 0, then read_repeat(0x28, 1024)
         against the old per-word path
     They must return the SAME 1024 words. Equality is the correctness test;
     timing is the point but correctness comes first.
  3. Time it. Expect ~5 ms rather than ~220 ms for 1024 words.
  4. Then deepen the buffer 4096 -> 16384 (16 banks of 1024x26, ~16 of 140
     BRAMs) and add a trigger.

### Repo change worth knowing about

`mix firmware` now HARD-ERRORS on `rootfs_overlay/root` -- Nerves refuses
overlay directories that a filesystem mount will shadow. That directory held
`radio4096.bin` and was already documented here as non-functional for exactly
that reason: /root is a writable mount that shadows the read-only rootfs, so
files placed there never appeared. Contents moved to
`nervezynq/_unused_rootfs_root/` rather than deleted.

### Stage A1 VERIFIED on hardware

New firmware confirmed live first (`read_repeat/2` exported, active partition
`a`, uuid a122965d) -- that check exists because `mix upload` has previously
written A while the board booted B.

Correctness, on a real capture (BIST tone, `cap_done=1`, 120 distinct values --
not an empty buffer):

    old per-word path   1024 words   791.2 ms
    read_repeat         1024 words    25.6 ms
    identical?          TRUE
    speedup             30.9x

The equality test is the important half. Timing a path that returns the wrong
data would have been the seventh instrument on this project to produce a
confident wrong answer.

### An unexplained 23x, recorded rather than smoothed over

Predicted was ~344 us + 1024 x 1.06 us = ~1.4 ms. Measured 25.6 ms, so ~25 us
per word rather than ~1.06 us -- and 1.06 us was itself a measured number, from
`read_block` over consecutive addresses in the register window with the
returned length checked.

So repeated reads of ONE address cost ~23x more per word than consecutive reads
of DIFFERENT addresses. That is not explained by anything in the slave, whose
read FSM is a fixed ~3 cycles either way. Candidates: the ARM's device-memory
read pipeline behaving differently for a repeated address, or something in the
Rust loop. Not chased -- 30.9x was the goal and it is banked.

**But the number has a direct consequence**: it means memory-mapping the
capture buffer, which I deferred as too invasive, is worth roughly another 23x
on top, because `read_block` would then apply. That moves it from "architectural
tidiness" to the single biggest remaining readout win, and re-raises it as the
next thing to do rather than a nice-to-have.

    per-word cost      path
      215 us           read32, one round trip per word   (original)
       25 us           read_repeat, one round trip total (now)
        1.06 us        read_block, if the buffer is memory-mapped (next)

### Where Stage A1 stands

    done      auto-increment read pointer + read_repeat, 30.9x, verified
    next      memory-map the buffer (another ~23x, per the above)
    then      deepen 4096 -> 16384 words, add a trigger
    then      the beacon

A 4096-word capture now reads out in ~100 ms, which is already well inside
"capture a whole beacon and decode it at leisure".

### Memory window REVERTED. Auto-increment alone gives 364x.

The memory-mapped buffer was built, uploaded and measured, and then reverted.
The reason is routing, not correctness:

    memmap design   ~2 routed out of 71 seeds (~3%), and BOTH failed bring-up
    autoinc design   4 routed out of 25 seeds (16%)

A design that routes 3% of the time and whose routed instances do not work is
not a design. The window also never justified itself on speed: measured
read_repeat 1.874 ms vs read_block 1.707 ms for 1024 words -- 1.1x, inside
noise. The predicted ~23x was based on a 25 us/word figure that turned out to
be an outlier.

`top.ex` is back to `top.ex.autoinc`. The window survives as `top.ex.memmap` if
it is ever wanted; the slave keeps its `mem_raddr`/`mem_rdata` ports, unused and
harmless, and `Fabric.@default_len` stays 0x20000 (a larger mmap than the design
decodes costs nothing).

### Verified on real data, seed 6

    old per-word path   1024 words   538.1 ms
    read_repeat         1024 words     1.48 ms
    identical?          TRUE
    distinct values     120            <- real capture, not an empty buffer
    speedup             364x

1.48 ms / 1024 = **1.45 us per word**, consistent with the ~1.7 us seen through
the memory window and with the ~1.06 us for plain register reads. So the true
per-word cost on this bus is ~1.5 us by any path, and the 25.6 ms
(25 us/word) measured earlier on `ai_s9` was an outlier, not a property of
repeated-address reads. Both the anomaly and the 23x prediction built on it are
withdrawn.

### Consequences, settled

    burst capture      SOLVED. 4096 words ~6 ms, 16384 words ~24 ms.
    continuous 1 Msps  needs 0.25 us/word; we are at 1.45. Still ~6x short,
                       so a real receiver still needs DMA over AXI HP.

### The routing tax is now the dominant constraint

Route rates measured this session, same design lineage, growing:

    radio (pre-VAR_LOAD)          ~1 in 3
    + VAR_LOAD                     1 in 12
    + memory window                1 in 35, and neither instance worked
    reverted to auto-increment     4 in 25

Every feature added costs route rate super-linearly, and functional failures
among routed bitstreams are running near 50%. **Defect #2 is no longer a
nuisance, it is the thing setting the pace of the project.** Any further
datapath work -- deeper buffer, trigger, DMA -- pays this tax twice, once in
build time and once in debugging phantom failures.

### Buffer deepened to 8192, and FIRST REAL RF

    route rate         5 of 31 seeds (16%) -- doubling depth cost nothing
    8192-word capture  cap_done 1, 8192 words, 120 distinct, ZERO zeros
    readout            9.96 ms, 1.22 us/word
    decode             deg_per_sample 11.25, mag_cv 3.4e-4, 2048 samples/ch

Eight banks of 1024x26 rather than four. Depth doubled, route rate held at 16%
-- so the memory window really was the thing that broke routing, not size as
such.

At 4 Msps, 8192 words is 2.05 ms of capture, which is a whole HaLow beacon.

### Real RF, BIST disabled, tuned to 2412 MHz

    bist_tone(:disable)              {:ok, 0}
    rf_receive_path(2_412_000_000)   :ok
    ch1 magnitude   n 2048, mean 42.3, max 103.4
    distinct words  1406 of 8192

Compare the BIST tone on the same path: mag_mean 2047.8 (full scale) and 120
distinct words. Mean 42.3 with 1406 distinct values is a live thermal noise
floor at roughly -34 dBFS -- **the receiver is off-air and listening.** This is
the first sample data in this project that came from an antenna rather than
from the transceiver's own test generator.

### Where the milestone stands

    capture depth    8192 words = 2.05 ms @ 4 Msps    DONE
    readout speed    9.96 ms for the whole buffer     DONE (364x)
    real RF          noise floor confirmed            DONE
    remaining        gain, a trigger, and finding an actual burst

Next is raising gain and looking for structure above the floor -- a beacon is
bursty, so the tell is max/mean over time windows, not the aggregate. Current
max/mean is 2.4, which is just noise.

---

# The CMT locks. It was never a silicon question.

The plan for this session was to point `frames_poke.exs` at the 2,614
undocumented bits in minors 28-29 of `CMT_TOP_L_LOWER_B_X178Y61` and search
them with LOCKED as a binary oracle. That search was never run and is now
cancelled. There was no documentation gap.

## Building the tool, then killing the reason for it

`scripts/frames_poke.exs` sets or clears arbitrary `<minor>_<bit>` in a routed
`.frames` file. `fasm2frames` only speaks NAMED features, so there is no way to
write a bit prjxray has not characterised; this edits the frames directly and
hands them to `xc7frames2bit`.

Two defects in it, found by running it: `import Bitwise` sat at the BOTTOM of
the module while `poke/5` used `|||`/`&&&`/`<<<` (Elixir imports are lexically
scoped -- the identical bug hit `reg_map.ex` earlier), and `parse_spec/2` was
called by the CLI and never defined. Both would have failed at first use.

Then the control, `scripts/frames_poke_selftest.exs`, because six instruments
in this project have produced confident wrong answers and every one was caught
by a known-answer test, none by reading the code. `fasm2frames` is a complete
oracle for the only thing under test -- the address arithmetic -- with no board
and no Vivado:

    A = fasm2frames(fasm)                     feature present
    B = fasm2frames(fasm minus that line)     feature absent
    C = poke(B, that feature's segbits)
    assert content(C) == content(A)

Four cases, each able to fail for a reason no other can:

    cmt_1bit      minor 29, 1 bit, offset 0      words 26..26   PASS
    cmt_multi     minors 28 AND 29, 110 bits     words  0..31   PASS
    hclk_clkword  offset 45, bit 185 -> WORD 50  words 50..50   PASS
    rioi3_neg     `34_72 !35_69`, negated        words 32..32   PASS

`hclk_clkword` is the one that mattered: it lands exactly on the clock word at
index 50, which is the assumption flagged in the tool's own header -- that
`offset` already indexes the 101-word space with the clock word in it, so no
HCLK adjustment applies. Every other case can pass while that one fails.

The tool is validated and committed. It was then not needed.

## What actually found it

Before searching for undocumented bits, diff the emitted FASM against the
COMPLETE documented feature list for the tile type. One pass over two files.
Of 132 documented `MMCME2_ADV.*` families, 56 were absent from our FASM. Most
are legitimately zero -- EDGE, FRAC, SS_EN, STARTUP_WAIT. Two were not:

    MMCME2_ADV.ZINV_RST       29_111    MISSING
    MMCME2_ADV.ZINV_PWRDWN    28_111    MISSING

while `ZINV_PSEN` and `ZINV_PSINCDEC` -- the same encoding, the same primitive,
four lines apart in the emitter -- were present.

`ZINV_*` is prjxray's Z-inverted encoding: the bit is SET when the pin is NOT
inverted. `nextpnr-xilinx/xilinx/fasm.cc` writes `!IS_x_INVERTED` in every
other place it emits a `ZINV_` -- ILOGIC/OLOGIC `ZINV_D`, `IFF.ZINV_C`,
`IFF.ZINV_OCLK`, `ZINV_T1`, `ZINV_ODATAIN`, BUFGCTRL `ZINV_CE0/CE1/S0/S1`,
BUFHCE `ZINV_CE`, the whole RAMB loop. `write_pll()` and `write_mmcm()` were
the only two functions that wrote it un-negated, under a comment saying so:

    // FIXME: should be INV not ZINV (XRay error?)

It was not an XRay error. With RST tied low and not inverted, the un-negated
form leaves the bit CLEAR, which INVERTS RST -- so the CMT sees RST asserted
permanently and LOCKED can never rise. **Every CMT this project has ever built
was held in reset by its own bitstream.** `INV_CLKINSEL` on the next line is
genuinely INV-encoded (note the name) and was always right; getting the
INV-named bit right while getting the ZINV-named ones wrong is presumably what
produced the FIXME.

## Measurement

Paired A/B against the SAME routed design. The two bits are appended to an
already-routed `.fasm`, so the router, the placer and the seed are held exactly
constant and control and candidate differ by `28_111` and `29_111` and nothing
else. That matters here: ~50% of routed bitstreams in this project are
functionally broken for unrelated reasons and would otherwise be
indistinguishable from a failed hypothesis.

The frames delta was audited before loading -- exactly two words changed,
`0x40241C` and `0x40241D`, bit 15 of word 3 in each. Nothing else moved.

    control (as routed)      LOCKED 0    CLKOUT0     0 ticks     0.000 MHz
    + ZINV_RST/ZINV_PWRDWN   LOCKED 1    CLKOUT0 19784 ticks    99.919 MHz

Both had a live heartbeat and both completed AD9363 bring-up, so the fabric was
equally alive in each. The clock rate is the real evidence, not the lock bit --
this project has been bitten by status bits that lie. 99.9 MHz is
`CLKFBOUT_MULT_F=10 / CLKOUT0_DIVIDE_F=5` on the input clock, so the CMT is
genuinely multiplying.

Then end to end through the patched nextpnr, on a different seed, which also
exercises the predicted swap in the emitted FASM:

    emitted before fix:  ZINV_PSEN, ZINV_PSINCDEC
    emitted after fix:   ZINV_PWRDWN, ZINV_RST
    seed 3, full flow    LOCKED 1    CLKOUT0 19784 ticks    99.986 MHz

Committed as `fix/cmt-zinv-polarity` in nextpnr-xilinx. Sixth branch; still
none filed upstream.

## What this retires

  - The 2,614-bit CMT search.
  - "Everything hard-block and analogue is dead." Nothing was dead. IDELAYE2,
    IDELAYCTRL and the CMT all work.
  - BUFHCE as a suspect. The locking design's CLKIN1 ran
    BUFG -> GCLK -> BUFHCE -> HCLK_CMT, so BUFH is now proven to carry a clock.
    It was only ever a suspect by association with this failure.
  - The "category 1 / category 3" framing from the CCIO discriminator. Neither:
    it was the emitter.

## The lesson worth keeping

Hazard 3 in SILICON_MAP was "documented + emitted + resolves is not evidence of
function". The CMT proves the converse also bites: **NOT emitted is not
evidence of undocumented.** Three defects in this project now have that shape --
ISERDES OFB/OCLK tie-offs, `ILOGICE3_IFF` writing the wrong input mux, and this
one. All three were the emitter dropping or corrupting a bit prjxray had
already characterised, and in all three cases the silicon was fine.

The check is cheap and should come first, before any hardware search: diff the
design's emitted FASM against the full documented feature list for the tile
type. Here it took one pass and would have saved roughly fifteen bitstreams.

## Where the CMT now unblocks things

A working CMT means the receive clock no longer has to be whatever the AD9363
happens to emit. Fs can be raised with the fabric clocked from a multiplied
DATA_CLK, and phase can be shifted in the CMT rather than only in IDELAYE2 taps
-- which is the direction the eye measurement was heading before it stalled.

---

# `ourfork`: one branch with every fix applied

`nextpnr-xilinx` now carries an integration branch, `ourfork`, merging all six
fixes plus the router diagnostic. The radio builds against it and the board
runs it.

    fix/bram-x9-parity-guard          1 commit   xilinx/fasm.cc
    fix/ilogic-iffdelmux              1          xilinx/fasm.cc
    fix/cmt-zinv-polarity             1          xilinx/fasm.cc
    fix/iserdes-ofb-tieoff            1          xilinx/pack_io_xc7.cc
    fix/idelay-requires-idelayctrl    1          xilinx/pack_io_xc7.cc
    tool/router-arc-diag              2          common/router2.cc
    fix/router-reserve-parallel-pips  1          common/router2.cc

All seven are single-parent branches off `stable-backports` and merge clean in
any order, despite three of them touching `fasm.cc`.

**`ourfork` is derived, not authored.** `ehdl/scripts/rebuild-ourfork.sh`
rebuilds it from the topic branches from scratch on every run, and refuses if
anything has been committed to it directly. That matters because each fix has
to stay one commit on the base to remain filable upstream, and none of the six
has been filed yet.

That rule had already been broken once: `fix/cmt-zinv-polarity` was branched
off `work/tier1` and carried fourteen unrelated commits, so it could not have
been pushed as a PR. Rewritten onto the base by cherry-pick, verified
diff-identical, old tip preserved as `backup/cmt-on-tier1`.

## Verification

    source          identical to backup/cmt-on-tier1, the tree every
                    measurement in this project was made on (only BRANCHES.md
                    differs, and that is now generated)
    regress.sh      6 passed, 0 unexpected
    hardware        of_s9 -- bring-up ok, deg_per_sample 11.25,
                    mag_cv 3.4e-4, mag_mean 2047.8

Four seeds were built. Two (9, 33) decode; two (3, 64) route and then fail
bring-up. That is the documented ~50% functional-failure rate among routed
bitstreams, not a regression -- the `d8_s0` control was re-run on the board
BEFORE concluding anything, and still worked. A negative needs a second seed
too, which is hazard 2 in SILICON_MAP and would have produced a false alarm
here otherwise.

`of_s9.bin.gz` is the new working head, loaded on the board.

## Two things left dirty

**Seed 4 no longer routes.** It routed at 19:51 and does not now, against
byte-identical nextpnr source. So the netlist changed, which means elaboration
or synthesis is not reproducible across a top-variant swap. Not chased. It is a
reproducibility problem and worth a session on its own.

**`build.exs` names artefacts by seed alone.** `libresdr_radio_s<N>.fasm`
collides across top variants, so sweeping a different top over the same seed
range silently destroys the previous variant's files. It has now eaten
`libresdr_radio_s0.fasm` (deep8k) and later overwrote `s3`. The build directory
should be namespaced by top variant before the next sweep.

---

# The seed lottery, finally measured

Two findings, one of which invalidates a number this project has been quoting
for weeks.

## Elaboration was nondeterministic

Generated signal names came from `:erlang.unique_integer([:positive])`, unique
per NODE and never reset. Two consecutive builds of an unchanged design gave
structurally identical Verilog -- same 3491 lines -- with every generated name
shifted by a constant offset (+992), because the counter's start depended on
how much unrelated work the BEAM had done first.

yosys and nextpnr order and tie-break on net names, so a rename changes
placement, which changes routing. That is why seed 4 routed the radio at 19:51
and would not an hour later against byte-identical nextpnr source, and I nearly
blamed the ourfork merge for it.

**Every seed sweep this project has ever run was sweeping a moving target** --
377 seeds in one campaign, 755 in another. `winning_seed.txt` could not be
trusted to rebuild. Fixed with a per-elaboration counter; five consecutive
builds now byte-identical in .v, .json and .fasm including across a forced
recompile.

## What the lottery actually is

    routed              23 / 60   38%
    routed AND decodes  20 / 23   87%
    end-to-end          20 / 60   33%

So "~50% of routed bitstreams are broken" was wrong; it is 13%. That number was
measured under the nondeterminism above and was counting build variance as
functional failure.

All 37 route failures are one failure: net `data_clk`, source
`BUFGCTRL_X0Y17/O`, destination `SLICE_*/CLKINV_OUT`, 37 out of 37.

And the dedicated clock router's give-up count separates the whole sweep
perfectly, 60 of 60 with no exceptions -- 0 give-ups always routes, 1+ never
does. So the defect lives in the dedicated clock router (`xilinx/arch.cc:1840`,
a greedy order-dependent backward BFS with no backtracking), not in router2.
Every previous framing named the wrong stage.

## Left open

The 3 routed-but-dead builds. Three different signatures (mean magnitude 0.0,
1.4, 551.8), Fmax does not separate them, and a FASM differential at n=3 found
nothing trustworthy. Wider sweep needed.

---

# Clock router: one hypothesis killed, the mechanism narrowed

## Disproven: it is not the sink ordering

The dedicated clock router routes each sink by a backward search that stops at
the first wire already bound to the net -- so its target is the partial tree
built by earlier sinks, and that tree grows as the loop runs. The obvious
reading is that a sink attempted early, against a nearly empty tree, fails
where it would later succeed, and that there is simply no retry.

Implemented the retry: iterate the sink loop to a fixpoint, report only the
permanently failed ones. Rebuilt, re-swept the same 60 seeds with the same
netlist.

    before   routed 23, failed 37
    after    routed 23, failed 37       <- identical, seed for seed

Clean negative. A sink that fails never succeeds on a later pass, so the
blockage is not our own net's ordering. Branch kept as
`wip/clock-router-retry-DISPROVEN`, deliberately NOT merged into ourfork --
zero measured benefit is not a reason to add complexity to a router.

## What it actually is: no track allocation across clock nets

Ran a failing seed under `--debug` and counted who holds the wires the search
skips. For `data_clk`'s sinks:

    345  used by net axi_clk
    105  used by net data_clk        (its own tree)
     38  used by net data_clk_raw
     13  used by net ref_clk

So it is CROSS-NET contention, and it is concentrated on one track:

    205  HCLK_CLB_CK_BUFHCLK0              BUFH track 0
     86  CLK_BUFG_REBUF_R_CK_GCLK16_BOT    GCLK spine track 16
     42  GCLK_B0                           INT tile clock track 0

The very FIRST arc of `data_clk` already fails, which independently kills the
incremental-tree story.

nextpnr constrains the three global clocks to adjacent BUFGs itself:

    clkbuf_bufg     (axi_clk)   -> BUFGCTRL_X0Y16
    dclk_bufg_bufg  (data_clk)  -> BUFGCTRL_X0Y17
    refbuf_bufg     (ref_clk)   -> BUFGCTRL_X0Y18

"Constrained ... based on dedicated routing."

The picture: each clock net's search grabs whatever dedicated track it finds
first, binds it STRENGTH_LOCKED, and the next net to route finds those tracks
occupied. There is no allocation of BUFH/GCLK tracks across nets and no ripup,
so whichever net `sorted(nets)` reaches first wins -- `axi_clk` before
`data_clk`, alphabetically. A device with 12 BUFH tracks per region is losing
to a first-come-first-served walk that keeps landing on track 0.

## Next

The fix is track allocation, not a retry: assign each (clock net, clock region)
a BUFH/GCLK track before routing any of them, then route each net onto its
assigned track. That is a real design change in `Arch::routeClock`, not a
three-line patch, and it should be measured the same way -- same 60 seeds, same
netlist, route rate before and after.

Worth stating plainly: with 12 tracks and 3 clocks, the correct route rate here
is 60/60. The 38% is entirely self-inflicted by the allocation strategy.

---

# PCAP readback: the plumbing is proven, the command stream is not

## What now works, measured on silicon

A 4 MB physically contiguous buffer, reserved at a fixed address and mapped
from Elixir with no Rust:

    /proc/device-tree/reserved-memory/pcap-readback@3fc00000
    /proc/iomem     00000000-3fbfffff : System RAM     <- carved out
    MemTotal        1005100 kB  (was 1009200)
    DmaBuf.verify   {:ok, %{base: 0x3FC00000, bytes: 4194304, words: 1048576}}

Declared as a `reserved-memory` node with `no-map` rather than a `mem=` kernel
argument, because bootargs on this board come from the U-Boot environment in a
raw partition and there is no `fw_setenv` on target -- editing that by hand
risks an unbootable board with no recovery short of a card reader.

The Nerves system resolves to a PREBUILT PORTABLE ARTIFACT, so the DTS in the
source tree is not in the build path at all. Editing it changes nothing. That
was caught by checking the DTB inside the built .fw rather than assuming:
`scripts/patch_dtb.py` decompiles the artifact's DTB, inserts the node and
recompiles, after verifying a decompile/recompile round-trip is byte-identical.

Full capability probe, all green:

    base_frames_present  devcfg_mapped  devcfg_wire_protocol  dma_buffer
    fabric_port_binary   mask_db_present  pl_configured  slcr_mapped

    selfcheck ready   pokecheck ready   census ready   functional ready

## And the DMA itself works in both directions

    cmd_xfer   {:ok, 0x23004}    DMA_DONE | D_P_DONE
    data_xfer  {:ok, 0x33004}
    buffer     pre-filled 0xDEADBEEF, overwritten by the transfer

So the engine accepted the command stream, ran a PL->PS transfer, and wrote
our buffer. Addresses, sentinel, direction, lengths and completion signalling
are all correct.

## What is not right yet

The bytes it wrote are zeros. `:selfcheck` compared 30 CMT frames against the
`.frames` the running bitstream was built from and reported 659 differing
words, every one of them readback=0 against a non-zero expectation.

That is the command stream, not the plumbing. `Readback.arm_sequence/2` was
written from the register tables and is missing something UG470 chapter 6
requires -- the RDBK_TYPE write named in its own comment is not actually
emitted, and the SHUTDOWN/GCAPTURE sequencing has not been checked.

**The known-answer gate did exactly its job.** It refused to certify an
instrument that transfers successfully and returns nothing, which is the single
most dangerous shape a result can have here: a clean `{:ok, ...}` from every
layer and garbage in the payload. Had `:census` been run first it would have
reported 2,614 "bits that did not stick" and every one of those would have been
an artefact.

## Next

One thing: get `arm_sequence/2` right against UG470 ch. 6, re-run
`:selfcheck` until it passes. Everything downstream of it is already built,
tested off-board (17/17) and gated.

## Two process notes worth keeping

**The board takes several minutes to come back after a firmware upgrade.** It
was declared dead twice and was healthy both times -- once on partition A, once
on B after an auto-revert cycle. `upgrade_available=1` + `bootcount=0` is armed
in fwup.conf, so a genuinely bad image does roll back on its own.

**A hardware GenServer must not be able to lock you out.** `Fabric.init/1`
matching `{:ok, port} = ...` means a mapping failure crashes init, exceeds
restart intensity, takes the app down, and erlinit reboots -- with networking
gone, there is no way in to fix it. It should degrade to a port-less state and
return `{:error, :port_unavailable}` per call instead. Not yet done.

---

# PCAP readback: register reads WORK, frame reads do not (yet)

Session ended with the board rebooting. Everything below was measured before
that; read the hazards at the end before touching devcfg again.

## The milestone: the configuration engine answers us

    IDCODE   0x23727093     <- exact xc7z020 ID. Known answer, confirmed.
    STAT     0x46107FFC
    FAR      0x402402       <- had advanced from a prior frame read

That is a **definitive known-answer pass** for the whole chain: reserved
buffer, devcfg registers, DMA out, DMA in, command-stream framing, and the
configuration engine's SYNC. Nothing about it is inferred. The PS can talk to
the 7-series configuration engine from Elixir with no Rust and no vendor tool.

## The exact recipe that worked

Three things all had to be true. Any one missing and it fails:

1. **The kernel driver must be UNBOUND.** `zynq_fpga_manager` claims
   `f8007000.devcfg` and owns the engine. With it bound, every transfer
   errors. `Devcfg.with_devcfg/1` unbinds and rebinds around the body. This is
   not a nicety; it is the difference between working and not.

2. **TWO DMA transactions, not one.**

       phase 1   src = cmd buffer,  dst = 0xFFFFFFFF,  len = cmd words
       phase 2   src = 0xFFFFFFFF,  dst = data buffer, len = data words

   `0xFFFFFFFF` is the sentinel meaning "the PL side". A single combined
   transaction (src = cmd buffer, dst = data buffer) always errored, despite
   UG585's readback page describing exactly that shape. Worth retrying from a
   genuinely fresh engine before concluding it is wrong.

3. **A fresh engine.** See hazards.

Command stream for a register read, six words:

    0xFFFFFFFF, 0xAA995566, NOOP, type1(read, <reg>, 1), NOOP, NOOP

## What does NOT work: frame data through FDRO

Same recipe plus `CMD=RCRC`, `FAR=<addr>`, `CMD=RCFG`, `type1(read,FDRO,0)`,
type-2 count, returns **all zeros** where registers return correct values. The
transfers report DMA_DONE|D_P_DONE and the destination buffer IS written --
a pre-filled 0xDEADBEEF pattern gets overwritten -- so the engine runs a
transfer and hands back zeros.

`:selfcheck` compared 30 CMT frames against the `.frames` the running bitstream
was built from: 659 differing words, every one readback=0 vs non-zero expected.

Ruled out along the way:

  - **Byte order.** `.bin` needs 32-bit words byte-swapped (sync as bytes
    `66 55 99 AA`). `write_volatile` of a u32 on little-endian ARM produces
    exactly that, so the path is already correct. Not the problem.
  - **QUARTER_PCAP_RATE_EN** (CTRL[25]). Tried set and clear. No difference.
  - **Trailing NOOP count.** Tried 2 and 32. No difference.
  - **Type-2 vs type-1 word count.** 202 words fits an 11-bit type-1 count
    field, so both forms were tried. No difference.

Still unexamined, in rough order of promise: the `RDBK_TYPE` write that
`arm_sequence/2`'s own comment names but never emits; whether `RCRC` is
harmful on a configured running device; whether frame readback needs
`SHUTDOWN`/`GCAPTURE` sequencing; and whether the pad frame is 1 frame or
something else on this part.

## Hazards, learned the hard way

**CTRL[31] FORCE_RST took the whole board down.** It is not a devcfg-local
reset -- it resets the PS-PL interface and the ssh session died instantly. Do
not poke it on a live system. Find a narrower reset or accept a reboot.

**The engine wedges, and a PL reload does NOT clear it.** After certain failed
sequences every subsequent transfer errors, including the register read that
worked minutes earlier. `Nervezynq.PL.reload/1` still succeeds (110 ms, the
driver's own path is fine) but our transfers stay broken. Only a reboot
recovered it. Budget a reboot between readback experiments until a proper
reset primitive is found -- that is the single biggest tax on iterating here.

**Always DESYNC.** Sequences that end without `CMD=DESYNC` leave the engine
synced, so the next `0xFFFFFFFF, 0xAA995566` is not a fresh sync and gets
parsed as data. Several confusing results came from this.

## Where this leaves the sweep

`:selfcheck` refused to certify, which is exactly its job. Had `:census` run
first it would have reported all 2,614 CMT bits as "did not stick" and every
one would have been an artefact of a readback returning zeros -- a wrong answer
with a clean `{:ok, ...}` at every layer.

Everything downstream of the command stream is built, gated and tested off
board (17/17). The remaining work is one function: `Readback.arm_sequence/2`.

---

# CORRECTION: the selfcheck "failure" was my bug, not the silicon's

Do not start the next session by debugging frame readback. Start by REDOING
THE COMPARISON, because the evidence that it was broken is unsound.

## What actually happened

`:selfcheck` reported 659 differing words, readback=0 against expected=133120
(0x20800). Two things were wrong with that, and together they invalidate the
conclusion:

1. **`Code.require_file/1` is a no-op if the file was already required.** The
   address-keyed fix to `load_expected_frames/0` was written, restaged and
   re-fetched -- and never loaded. The OLD positional version stayed resident,
   so the comparison zipped 30 CMT frames against the first 30 LINES of
   `base.frames` in file order.

   Use `Code.compile_file/1` on the target. `require_file` will silently give
   you the previous version and every result after that is about code you are
   not looking at.

2. **Frame 0x00402400 is ALL ZEROS in base.frames.** Verified directly:

       grep '^0x00402400 ' base.frames
       0x00402400 0x00000000,0x00000000,0x00000000,...

   And 0x00020800 -- the "expected" value -- is the first word of the file's
   FIRST line, frame 0x00000900.

So the readback returned zeros for a frame that IS zero, and was compared
against a completely different frame. **Frame readback may well have been
working the whole time.** We do not know, because the only comparison ever run
was against the wrong data, and every attempt after that hit a wedged engine.

This also means the CMT tile is a WEAK selfcheck target: zeros matching zeros
proves nothing. Use a frame with content -- 0x00000900 has
`20800, 0, 20800, 0, 20800, 0` as its first six words and is a proper known
answer.

## The one-shot experiment for next session

The engine wedges after a single failed readback and does not recover from a PL
reload, a driver unbind, or apparently a soft reboot -- the last attempt needed
a power cycle. So each attempt costs a power cycle. Make it count:

    1. Fresh boot. Set up, and load the harness with Code.compile_file/1.
    2. Read IDCODE first. Expect 0x23727093. This proves fresh engine + recipe
       before spending it.
    3. ONE frame read at FAR=0x900, requesting EXACTLY 101 words -- type-1
       count=101, NO pad frame.
    4. Compare the first six words against 20800, 0, 20800, 0, 20800, 0.

Step 3 is where the remaining doubt is. The last frame read requested
(n+1)*101 words for a pipeline pad frame and the data phase TIMED OUT, which is
exactly what happens if devcfg outputs n*101 and the DMA sits waiting for 101
words that never arrive. The pad frame is a SelectMAP/ICAP pipeline artifact
and may simply not apply to the PCAP path.

If 101 words comes back matching, frame readback works and `:census` is
unblocked. If it times out, the pad hypothesis is wrong and the next candidate
is the RDBK_TYPE write that `arm_sequence/2`'s own comment names but never
emits.

## Operational reality

  - One failed readback wedges devcfg for the session.
  - A wedged devcfg appears to block a clean reboot -- budget a power cycle.
  - Always DESYNC at the end of a sequence.
  - Never touch CTRL[31] FORCE_RST on a live system; it resets the PS-PL
    interface and drops ssh instantly.
  - The kernel driver MUST be unbound (`Devcfg.with_devcfg/1`) or every
    transfer errors.

---

# The wedge has a cause, and therefore a way to avoid it

## What wedges devcfg

The data-phase DMA requests N words from the PL. If the configuration engine
produces FEWER than N, the DMA never completes -- it sits waiting for words
that will never arrive. `clear_ints` does not abort an in-flight transfer, and
INT_STS bit 23 latches an error that does not clear. From then on EVERY
transfer errors, including the register read that worked a minute earlier.

Confirmed: a wedged devcfg also **blocks the boot**. Both
`Nerves.Runtime.reboot()` and a PL reload fail to recover it -- the board sat
dark for 9 minutes. Only a physical power cycle works. So a wedge costs a power
cycle, not a reboot.

## How to never wedge it: ASYMMETRIC LENGTHS

Ask the engine to produce MORE than the DMA collects.

    command stream:  type1(read, FDRO, 101)   <- engine will output 101 words
    data DMA:        dst_len = 8              <- we collect only 8

The DMA completes immediately, because the words it wants are already there.
Leftover data stays in the FIFO and is discarded by DESYNC. No stuck transfer,
no latched error, and the experiment is REPEATABLE without a power cycle.

Every wedge in this project came from doing the opposite -- requesting
(n+1)*101 words for a pipeline pad frame that the PCAP path very likely does
not produce, so the DMA waited forever for the last 101 words.

This is the single most useful operational fact learned tonight. It turns a
power-cycle-per-attempt loop into an iterate-freely loop.

## The exact next experiment, safe by construction

    1. Power cycle. Set up; load the harness with Code.compile_file/1.
    2. Gate: IDCODE, expect 0x23727093. Full recipe, INCLUDING the CTRL write
       that was omitted once and burned a whole cycle:

           Devcfg.unlock()
           {:ok,c} = Devcfg.read32(0x00)
           Devcfg.write32(0x00, c ||| (1 <<< 26) ||| (1 <<< 27))   # PCAP_MODE|PCAP_PR

       Driver unbound via Devcfg.with_devcfg/1. Two-phase DMA.
    3. Frame read at FAR=0x900, command says 101 words, DMA collects only 8.
    4. Compare against base.frames frame 0x900: 20800, 0, 20800, 0, 20800, 0.

If those six words match, frame readback works, `:census` is unblocked, and the
whole dark-space prune is one experiment away.

Frame 0x900 is chosen because it HAS content. The CMT tile at 0x402400 is all
zeros in base.frames, so it can never distinguish a working readback from one
that returns zeros -- which is exactly the trap the first selfcheck fell into.

---

# THE FIFO. Why two-phase readback cannot work for frames.

## The measurement

Fresh engine, gate passed (`IDCODE 0x23727093`, both phases `:ok`).

Frame read at FAR=0x900, command said 303 words, DMA asked for 110:

    words 0..79    written, all ZERO
    words 80..109  untouched (still 0xDEADBEEF)
    -> the engine produced exactly 80 words, then stopped

And an 8-word collect completed cleanly. So the engine emits ~80 words and no
more.

## What that means

**80 words is a FIFO depth, not a frame.** In the two-phase scheme the command
DMA finishes FIRST, and only then does the data DMA start draining. The
configuration engine has nowhere to put words in between, so it fills its
output FIFO (~80 words), stalls, and never produces the rest.

Register reads work in two phases only because 1 word fits in the FIFO. That
is why the IDCODE gate has been passing all along while frames never could --
the two-phase recipe was never wrong for registers and never right for frames.

This also explains every timeout: ask for more than ~80 words in the data phase
and the DMA waits forever for words the stalled engine will never emit. That is
the wedge, and it is why the "asymmetric lengths" rule needs correcting:

    collect <= what the engine ACTUALLY produces (~80), NOT what the
    command's word count asks for.

## So the combined DMA is the right shape after all

UG585's readback page describes exactly one transaction:

    DMA Source Address:  location of the PL readback command sequence
    DMA Destination Address: where to store the readback bitstream
    DMA Source Length:   number of command words
    DMA Destination Length: number of data words

One transaction, so the engine streams out WHILE the DMA drains, and the FIFO
never fills. Earlier combined attempts failed -- but every one of them ran on an
already-wedged engine, or omitted the CTRL PCAP_MODE|PCAP_PR write that a
later cycle proved is mandatory. Neither attempt was a fair test.

## The next shot

    1. Power cycle.
    2. Gate: IDCODE, two-phase, WITH the CTRL write. Expect 0x23727093.
    3. Frame read at FAR=0x900, ONE combined DMA:
           src = cmd buffer,  src_len = length(seq)
           dst = data buffer, dst_len = 101
    4. Compare first six words against 20800, 0, 20800, 0, 20800, 0.

If it still returns zeros with a completed transfer, the next hypothesis is the
CTL0 security field: 7-series can disable readback via SBITS, which would leave
registers readable and frames zero. That read was queued this cycle and lost to
the wedge -- do it early next time, it is cheap and decisive.

---

# Readback: what is proven, what is eliminated, and why to stop guessing

## Proven, repeatably, on a fresh engine

    gate: IDCODE  0x23727093    both DMA phases :ok, queue idle after

Register readback through PCAP works. Recipe, all three parts required:

    1. kernel driver UNBOUND (Devcfg.with_devcfg/1)
    2. CTRL |= PCAP_MODE|PCAP_PR  before the transfer
    3. two-phase DMA: cmd out (dst = 0xFFFFFFFF), then data in (src = 0xFFFFFFFF)

`Devcfg.queue_idle?/0` now gates everything, so a wedged engine raises instead
of returning plausible garbage. Verified: reports `false` when wedged, `true`
on a fresh boot.

## Eliminated

  - **Byte order.** `.bin` wants 32-bit words byte-swapped; `write_volatile` of
    a u32 on little-endian ARM already produces exactly that.
  - **QUARTER_PCAP_RATE_EN** (CTRL[25]). Set and clear, no difference.
  - **Trailing NOOP count.** 2 and 32, no difference.
  - **Type-1 vs type-2 word count.** Both forms, no difference.
  - **Readback security.** Read the generated bitstream directly:
    `CTL0 = 0x00000501`, **SBITS = 0**, security level None. prjxray defines no
    security features at all and `required_features.fasm` has only three
    ALWAYS_ON_PROP bits. Readback is permitted.
  - **The combined single DMA.** Tried on a genuinely fresh engine with the
    CTRL write present -- errors immediately and wedges the queue. So UG585's
    one-transaction description is not sufficient on its own.

## The one hard datum that constrains everything

Two-phase frame read, command asked 303 words, DMA asked 110:

    words 0..79    written, ALL ZERO
    words 80..109  untouched

The engine emitted **80 words of zeros**. Not 80 words of real data then a
stall -- zeros. So this is not only a FIFO-depth story: **FDRO is producing
zeros.** Any correct explanation has to account for zeros, not just for the
stall at 80.

## Why to stop guessing

Every remaining hypothesis costs a power cycle to test, because a failed frame
read wedges the DMA queue and neither a PL reload nor a soft reboot clears it --
a wedged queue also prevents the board from booting. Four cycles were spent
tonight and `/root` is now corrupted ("structure needs cleaning") from the hard
power-offs; the harness runs fine out of /tmp.

That is a bad iteration loop for hypothesis search. The fix is not more guesses,
it is the authoritative sequence:

  1. **UG470 chapter 6, Readback Command Sequences** (p.124 in v1.10). Every
     doc fetch so far returned only the table of contents. Get the actual PDF
     text.
  2. **The Linux `xdevcfg` driver**, which implemented PCAP readback before
     `fpga_manager` replaced it. That is working source for exactly this
     operation on exactly this silicon -- almost certainly the fastest route.
  3. Xilinx's `XDcfg_Transfer` in embeddedsw (`xdevcfg.c`), same reason.

Come back with a known-correct command stream and spend ONE power cycle
confirming it, instead of spending one per guess.

---

# SOLVED (pending confirmation): the preamble was wrong

Found in Xilinx's own driver, not by guessing. `xdevcfg_reg_readback_example.c`
builds its command buffer as:

    CmdBuf[0..7]  0xFFFFFFFF   eight dummy words
    CmdBuf[8]     0x000000BB   bus width sync word
    CmdBuf[9]     0x11220044   bus width detect
    CmdBuf[10]    0xFFFFFFFF   dummy
    CmdBuf[11]    0xAA995566   sync

This project sent `[0xFFFFFFFF, 0xAA995566]` -- ONE dummy and the sync. The bus
width detect pattern was missing entirely.

`0x000000BB` is deliberately asymmetric across byte lanes; that IS its purpose.
The device uses it to determine how a 32-bit word is presented to it.

**This explains the one thing that never made sense**: register reads worked
while FDRO returned zeros. A register read got through on an engine the kernel
driver had already synced during its own bitstream load. A frame readback needs
the stream parsed from a known bus width, and without that pattern the engine
never establishes one.

Three more things confirmed from source rather than inferred:

  - **One combined transfer.**
    `XDcfg_Transfer(cmdbuf, cmd_words, data, data_words, XDCFG_PCAP_READBACK)`.
    The combined attempt was structurally right and failed only because the
    command stream was malformed.
  - **The pad frame is real.** XAPP1230 gives an XCKU040 readback as
    "32530 frames + 1 frame + 10 words". `(n+1)*101`, discard the first 101.
  - **Cleanup is 6 words, DESYNC only, destination length ZERO.** No START.
    The old cleanup issued START on a running device AND asked for 7 words
    back, which would stall the queue by itself.

Harness updated with the sourcing in the comments. Off-board tests 17 -> 20/20;
the pad-frame assertion is now pattern-based rather than positional, because
the positional version broke the moment the preamble grew and that is precisely
the drift it exists to catch.

# The wedge is only cleared by a POWER-ON reset

Established by elimination, all measured:

    PCFG_PROG_B toggle      no  (devcfg.rs does this, THEN finds the queue full)
    PL reload via driver    no  ("DMA command queue not idle")
    driver unbind/rebind    no
    DESYNC-only command     no  (times out; queue cannot drain)
    Nerves.Runtime.reboot() no  (board never came back)
    power cycle             yes

And that explains why a wedge BRICKS THE BOOT rather than merely annoying us:
**the FSBL uses devcfg to load the bitstream**, so a stuck queue hangs it before
Linux starts. It is not that the reboot is slow -- it cannot complete.

Operationally: `Devcfg.queue_idle?/0` gates every entry point. If it returns
false, stop and power cycle. Nothing else will help, and every result taken
while it is false is meaningless.

---

# Combined DMA does NOT work here. Two-phase does. Preamble still untested.

Clean A/B on a fresh engine, same 1-word register read:

    two-phase + SHORT preamble (1 dummy + sync)   ->  :ok, IDCODE 0x23727093
    combined  + FULL preamble  (Xilinx's 12)      ->  :error, queue wedged

So the combined single transfer fails in this setup regardless of preamble.
That is now measured twice on fresh engines, so it is not a state artefact.

Why it might fail while Xilinx's driver uses it: `XDcfg_Transfer` may issue two
`XDcfg_InitiateDma` calls internally rather than one descriptor -- the EXAMPLE
calls Transfer once, which is not the same claim. Worth reading `xdevcfg.c`'s
`XDcfg_Transfer` body before trying combined again. Also unchecked: whether
devcfg tolerates DMA source and destination in the same reserved region (ours
are base+0 and base+16KB).

## The mistake, and the experiment that should have been run

Two variables were changed at once -- transfer shape AND preamble -- against a
known-good baseline. That is the exact discipline this project applies to every
hardware measurement and it was not applied here. The result is uninformative
about the thing being tested.

The minimal perturbation from the known-good configuration:

    two-phase, FULL preamble, FAR=0x900, collect only 8 words

  - two-phase because it is the only shape proven to work
  - full preamble because that is the single hypothesis under test
  - 8 words because the engine emits ~80 before stalling, so collecting 8
    cannot wedge the queue and the experiment is REPEATABLE

If those 8 words read 20800, 0, 20800, 0, 20800, 0 then the preamble was the
fix and only the >80-word streaming problem remains. If they read zeros, the
preamble was not the answer and combined-vs-two-phase becomes the live question
again.

Run that FIRST next cycle, before anything else.

## The functional sweep is blocked on the oracle, not on the sweep

`:selfcheck` passes, `:census` is answered, and the write path is verified
(see SILICON_MAP.md sections 13-17). `:functional` is the only remaining route
to the 2,614 undocumented CMT bits, and it cannot be started yet.

### Why not

`SiliconSweep.default_oracle/0` calls
`MIMO.validate(Fabric.read_repeat(0x28, 8192))`. That path has never produced a
live reading. Measured under both `det_s9` and `ourfork_s3`:

    %{deg: 0.0, cv: 999.0, mean: 0.0}

The fabric itself is fine -- mapped at `0x40000000`, 128 KB, reads succeed and
return zeros. The register simply is not driven.

The real 11.25 / 3.4e-4 numbers came from a different path entirely: an AD9363
BIST tone, captured by `LVDSProbe.capture/1` and decoded by
`SampleFormat.decode2/1` + `validate2/1`.

**This matters more than a wiring mistake.** A functional sweep compares each
poked bit against a baseline. With a dead baseline every bit reports
`changed: false`, the run completes cleanly, and 2,614 rows of nothing are
indistinguishable from 2,614 rows of "these bits do nothing". Exactly the shape
of `:census`'s first `0 real cells`, and this time with no accidental positive
control to catch it.

### Bring-up state, measured this session

| Step | Result |
|---|---|
| `release_reset/0` | works -- **this was the missing first step**; without it SPI reads `0xFF` |
| SPI reachable | yes, `PRODUCT_ID (0x37)` reads `0x0A` |
| `enable_bias/0` | **fails** readback verify: expected `14`, got `4` then `0` |
| `clock_path_setup(true)` | `:ok` |
| `bbpll_set_rate/0` | **locks**: `rate_hz: 983_040_000`, `locked: true`, integer 24, fract 1203241 |
| `bist_tone(:rx, 0, 0, 0)` | not reached |
| `LVDSProbe.capture/1` | `:capture_timeout` |

`bring_up(:auto)` fails because `enable_bias/0` is a hard `:ok =` match inside
it. Everything after that step works when driven by hand, including the BBPLL.

### The SPI read lag, which is probably the whole problem

Four consecutive reads of `PRODUCT_ID` immediately after reset:

    [ok: 1, ok: 1, ok: 1, ok: 10]

The correct value arrives on the fourth read. This is not noise -- it is
repeatable, and it explains `enable_bias/0` reading `4` and `0` where it wants
`14`: `write_verify/2` reads back a stale value and declares a mismatch on a
write that very likely landed.

So the first thing to try is **read-until-stable** in the SPI read path (or in
`write_verify/2`), rather than debugging `enable_bias/0` as if the write were
failing. Confirm by reading the register enable_bias touches several times in a
row and watching it converge to `14`.

### Order of work

1. Fix the SPI read lag; re-run `bring_up(:auto)` and expect it to complete.
2. `bist_tone(:rx, 0, 0, 0)`, then `LVDSProbe.capture(1024)` ->
   `SampleFormat.validate2/1`. Expect `mag_cv ~3.4e-4`, `mag_mean 2047.8`,
   `deg_per_sample -11.252`.
3. Repoint `default_oracle/0` at that, keeping `mag_cv` and `deg_per_sample` as
   the comparison quantities.
4. Implement `:pokecheck` -- poke KNOWN documented CMT bits, assert the oracle
   moves. Gate `:functional` on it. Without this the night is unfalsifiable.
5. Confirm `base_tile` is the CMT the design actually routes through.
   `CMT_TOP_L_LOWER_B_X178Y61` has only 48 nonzero words across its 30 frames in
   `base.frames`; if the design does not clock through it, poking it cannot
   perturb any oracle however good.
6. Generate `/root/documented_bits.term` from `segbits_cmt_top_l_lower_b.db` so
   the candidate set is the 2,614 undocumented bits rather than all 3,136.
   **Keep some documented bits in the set deliberately** as running positive
   controls -- that accident is what caught the census.

Step 5 is worth settling before step 4, because it can invalidate the target
outright and it is cheap to check.

## Oracle bring-up, session 2: `ourfork_s3` has a broken SPI master

Progress on the AD9363 path, and one hard blocker that is a **design** fault,
not a bring-up mistake.

### Fixed: `release_reset/0` is required, and SPI needs priming

Two separate things, previously conflated:

1. **`release_reset/0` must be called first.** Without it every SPI read returns
   `0xFF` and the chip looks dead. `bring_up/1` does call it, but if `bring_up`
   has already failed once the chip is left mid-reset and the next attempt
   inherits it.

2. **The SPI master needs priming after any reset or PL reload.** Reads
   immediately after `release_reset/0` go `[1, 1, 1, 10]` -- three wrong then
   correct. This is NOT settle time: it persisted unchanged with a 2000 ms sleep
   and cleared after two read *transactions*. Prime by reading `PRODUCT_ID`
   (0x37) until it returns `0x0A` twice consecutively; that took 2 iterations.

With those two, the full chain runs on the **boot** bitstream:

    bias   :ok
    clk    :ok
    bbpll  {:ok, %{rate_hz: 983_040_000, locked: true, integer: 24,
                   fract: 1203241, icp: 4}}
    tone   {:ok, 11}          <- BIST tone enabled and verified

### The blocker: SPI breaks under `ourfork_s3`

The boot bitstream has a working SPI master but **no LVDS capture block**
(`LVDSProbe.capture/1` -> `:capture_timeout`). `ourfork_s3` has the capture
block -- it returns 256 samples -- but its SPI master is broken:

    bias   {:error, {:readback_mismatch, expected: 14, got: 0}}
    bbpll  {:error, {:bbpll_not_locked, ...}}
    tone   {:error, {:readback_mismatch, expected: 11, got: 15}}

So neither bitstream can produce the oracle on its own, and that is the whole
blocker: **capture and SPI have never been working in the same design.**

### What the failure looks like

Every failing register is above 0xFF -- bandgap `0x2A6`/`0x2A8`, BIST
`0x3F4`-`0x3F6` -- while `PRODUCT_ID` (0x37) and everything `clock_path_setup/1`
touches are below it, and those pass. That points at the instruction word's high
byte.

But it is worse than a stuck address bit: after a few dozen transactions
`PRODUCT_ID` itself degrades from `0x0A` to `0x01`. The master is
**desynchronising**, not mis-addressing. `AD9363.read/1`'s own docstring
describes exactly this failure and its cause -- a transaction clocked for the
wrong number of bits desynchronises the AD9363's SPI state machine, and only a
RESETB pulse recovers it. That workaround was removed when
`Hw.SPI.Master` gained `MISO_SAMPLE_TRAILING` **and the radio design sets it**.

**So the first thing to check is whether `ourfork_s3` actually sets
`MISO_SAMPLE_TRAILING` on its SPI master.** If one of the seven topic branches
merged into `ourfork` dropped or reordered that parameter, this is the
regression, it is a one-line fix, and it would have gone unnoticed because
nothing downstream of SPI was being exercised.

### Where this leaves the sweep

`:functional` remains blocked, for the original reason: no live oracle. But the
blocker is now specific and small rather than open-ended.

    1. Check MISO_SAMPLE_TRAILING on the SPI master in the ourfork build.
    2. Failing that, find or rebuild the seed-25 26-bit-capture LVDS probe
       design -- the one that produced 11.25 / 3.4e-4. It is NOT in
       designs/libresdr_radio/taps/serve/; every .bin.gz there was checked.
    3. Then: prime SPI, bring up, BIST tone, capture, validate2, and only then
       repoint default_oracle/0 and build :pokecheck.

### Two fixes that belong in the tree regardless

- `AD9363.prime/0` -- read `PRODUCT_ID` until stable, called after
  `release_reset/0` and after every `PL.reload/1`. Without it the first few
  transactions of any session return wrong data that looks like real data.
- `bring_up/1` uses `:ok = enable_bias()`, so a single readback mismatch
  aborts the whole sequence and leaves the chip half-configured. It should
  return the error rather than match on it, so a caller can see which step
  failed instead of a bare `badmatch`.

## ORACLE LIVE. And the sweep target was wrong.

### The oracle works

Reference values reproduced exactly:

    mag_cv 3.4e-4    deg_per_sample -11.252    mag_mean 2047.8    predicted 11.25

Working sequence, on a **known-good bitstream**:

    fetch of_s9.bin.gz -> PL.reload
    AD9363.release_reset(); sleep 800
    prime()                          # read PRODUCT_ID until 0x0A twice
    AD9363.Bringup.receive_path()    # NOT bring_up/1 -- this is the full path
    AD9363.bist_tone(:rx, 0, 0, 0)
    LVDSProbe.capture(1024) |> SampleFormat.validate2()

`Bringup.receive_path/1` is the piece that was missing: `bring_up/1` stops after
the BBPLL, and `data_port_setup/1` (with `rx_clk_data_delay: 0x0A`) lives inside
`receive_path`. Without it the capture returns a CONSTANT -- `mag_cv 0.0`,
`deg_per_sample 0.0`, `mag_mean 551.5` -- which looks like data and is not.

### `ourfork_s3` was a routed-but-broken build

Not a source defect. `top.ex:491` sets `MISO_SAMPLE_TRAILING: 1`, and the SPI
master RTL is identical across builds. Measured across five bitstreams:

    build          SPI      capture
    ourfork_s3     BROKEN   works
    ourfork_s4     ok       works
    of_s9          ok       works
    of_s33         ok       works
    of_s64         BROKEN   timeout

Same source, same design, different place-and-route. This is the
routed-but-functionally-broken hazard measured directly, and the failure
signature is specific: SPI registers **above 0xFF** fail first (bandgap
0x2A6/0x2A8, BIST 0x3F4-0x3F6), and after a few dozen transactions even
`PRODUCT_ID` degrades from 0x0A to 0x01 -- the master desynchronises rather
than mis-addressing.

**Use `of_s9`.** Do not use `ourfork_s3`; every SPI result taken under it is
worthless.

### The oracle's stable quantities

`samples` (254-256) and `parity_a`/`parity_b` vary between captures at constant
configuration -- they track capture phase, not the design. Comparing whole
oracle maps would report "changed" for every bit tested. Compare only:

    deg_per_sample, mag_mean, mag_cv

### THE TARGET IS WRONG, and this is why the pre-flight mattered

`SiliconSweep.base_tile/0` is `CMT_TOP_L_LOWER_B_X178Y61` (0x00402400). One
experiment settles it: `:census` sets ALL 3,136 bits of minors 28 and 29 to 1.

    before  %{mag_cv: 3.4e-4, deg_per_sample: -11.252, mag_mean: 2047.8}
    after   identical, three consecutive captures
    MOVED   false

The radio does not notice the entire CMT dark space being set to ones. That CMT
is not in this design's clock path, so **no single bit in it can move the
oracle**. A 2,614-bit functional sweep against this target would have run all
night and reported "no change" for every bit -- correctly, and meaninglessly.

That is the third time in this project a null result would have read as a
finding, and the first time it was caught before the run rather than after.

### Next: find the CMT the design actually uses

xc7z020 has 8 CMT tiles at 4 distinct base addresses (LOWER_B and UPPER_T share
an address and differ by word window):

    0x00002400   CMT_TOP_L_LOWER_B_X178Y113  words 0-48
                 CMT_TOP_L_UPPER_T_X178Y148  words 74-100
    0x00402400   CMT_TOP_L_LOWER_B_X178Y61   words 0-48   <- current target, unused
                 CMT_TOP_L_UPPER_T_X178Y96   words 74-100
    0x00422400   CMT_TOP_L_LOWER_B_X178Y9    words 0-48
                 CMT_TOP_L_UPPER_T_X178Y44   words 74-100
    0x00420080   CMT_TOP_R_LOWER_B_X8Y9      words 0-48
                 CMT_TOP_R_UPPER_T_X8Y44     words 74-100

Read all four back and pick the one with nonzero content in minors 28/29, then
repeat the all-ones sensitivity test against it. Only if THAT moves the oracle
is the functional sweep worth starting.

(The scan was cut short by a wedged DMA queue -- `STATUS 0xA0000F30`, both slots
occupied, needs a power cycle. `RbProbe` had to be recompiled after the reload;
compile it before starting the scan.)

### The 31-frame wedge was a buffer-layout bug in `rb_probe.exs`, not hardware

`RbProbe` had `@noop_off 2048` and `@data_off 8192` -- 6144 words of room for
the NOOP clock stream. Clock budget is `3 * words`, so:

    11 frames -> 1111 words ->  3333 clocks   fits
    31 frames -> 3131 words ->  9393 clocks   OVERRUNS data_off by 3249 words

The clock stream was overwritten by the very data it was clocking in. The engine
stopped being clocked, the receive stalled, both queue slots filled, power cycle.
Two constants sitting too close together, presenting as a hardware fault.

Fixed: `@noop_off 262_144`, plus an explicit overflow check that raises before
the transfer rather than stalling minutes into it. Overlapping DMA regions do
not fail at the point of the mistake.

**Scan the CMTs the cheap way instead.** Only minors 28 and 29 matter, so read
at `baseaddr + 28` with `chunks: 3` (pad + 2 frames): 303 words, 909 clocks, no
layout pressure at all. Reading all 30 frames to look at 2 of them was the only
reason the limit was ever approached.

## SOLVED: the board did not boot because U-Boot was programming the PL at boot

Symptom: board dead after relocation. No USB gadget, no mDNS, no console, across
several power cycles. Feared a dead SD card.

### Diagnosis, entirely over JTAG

The console was unreachable (UART0 enabled, `CR=0x114`, ~115200 from its
divisors -- but writing bytes directly into its TX FIFO over JTAG produced
nothing on any of the three FTDI UART channels, so the PS console pin is not
wired to this debug header, most likely routed via EMIO through the PL). So
everything below came from `openocd -f openocd/libresdr.cfg` and register reads.

    JTAG tap zynq_pl.bs   0x23727093   PL alive, board powered
    BOOT_MODE 0xF800025C  0x00000005   booting from SD
    SDIO0     0xE0100024  0x01FF0000   card inserted, stable, lines idle-high
    GEM0      0xE000B000  0x00000000   Ethernet never enabled
    cpu0 pc                0x3ff569d4  5 of 6 samples

`BOOT_MODE = SD` with U-Boot running proves the FSBL *and* U-Boot were both read
off the card. `fsck_msdos` on the boot partition returned exit 0. The card was
never the problem.

`GEM0 net_ctrl = 0` rules out a DHCP/link hang, which was the obvious guess
after the laptop changed networks. It was wrong.

The instructions at the hang:

    e5903000   ldr  r3, [r0]         ; device
    e593303c   ldr  r3, [r3, #0x3c]  ; ->ops
    e5933010   ldr  r3, [r3, #0x10]  ; ->ops[4]
    e12fff13   bx   r3               ; call
    ...
    e370000b   cmn  r0, #11          ; == -EAGAIN ?
    0afffffa   beq  -6 words         ; retry, forever

A driver-model op returning `-EAGAIN` on every call, retried without limit.

### The cause

`ls -la` on the boot partition:

    BOOT.BIN               101476   Jan  1 1980   <- written by fwup
    u-boot.img            1060344   Jan  1 1980   <- written by fwup
    uImage.a / uImage.b   8114752   Jan  1 1980   <- written by fwup
    zynq-libresdr.*.dtb     11339   Jan  1 1980   <- written by fwup
    libresdr.bit          4045672   Jul 29 14:27  <- COPIED BY HAND

One file with a real timestamp among a set of fwup-written ones. Its header:
`Generator=xc7frames2bit`, `xc7z020clg400-1`, built `2026/07/29 14:24:28` from
`/tmp/radio.frames` -- one of our own openXC7 builds.

Reflashed with `fwup -a -t complete`, which writes no `.bit`, and **the board
booted normally**. USB gadget up, `mix nerves.discover` finds it.

So U-Boot was loading that bitstream into the PL at boot and the devcfg transfer
never completed. That also explains the silent console: if UART0 is routed via
EMIO, an unprogrammed PL means no console pin.

### Rules that follow

1. **Never leave a `.bit` on the boot partition.** Load bitstreams at runtime
   from Elixir via `Nervezynq.PL.reload/1`, which is what every successful
   session has done. A bad bitstream then costs a reload, not a bricked boot.
2. A hand-copied file on the FAT partition survives `upgrade.a`/`upgrade.b`
   firmware updates and is invisible to `mix firmware`. It is untracked state on
   a device that is otherwise fully reproducible from a `.fw`. Treat any file on
   BOOT that fwup did not write as suspect.
3. This is the second time tonight that a build from the routed-but-broken
   population caused a failure that looked like something else entirely (the
   first: `ourfork_s3`'s SPI master). Assume any openXC7 build is broken until
   it has passed a functional check, and never put one somewhere that boot
   depends on it.

Backup of the old boot partition, including the offending bitstream, is at
`nervezynq/boot-backup-20260801-1812/`; `libresdr.bit` sha256
`95e8ebd0f0875fab24663752ab30ceb6d1d6a8a8862c12e7911ec4cffb53538c`.

### After a `complete` reflash, restore these

`fwup -t complete` wipes the app data partition, which clears the `/root`
corruption from repeated hard power cycles (good) but also removes the two files
the sweep harness reads:

    /root/base.frames
    /root/mask_cmt_top_l_lower_b.db

Both are served from `ehdl/designs/libresdr_radio/taps/serve/`.

### Consequence of the fix: the PL is now UNCONFIGURED at boot

Removing `libresdr.bit` from the boot partition fixed booting, but it changes a
standing assumption. Previously U-Boot programmed the PL before Linux started,
so the fabric was always live by the time Elixir ran. Now it is not.

That matters because **an AXI read to an unresponsive PL slave hangs the CPU
forever** on Zynq -- there is no bus timeout. Any code that touches
`Nervezynq.Fabric`, `Regs`, `LVDSProbe` or the AD9363 SPI bridge before a
bitstream is loaded can hard-lock the board with no console, no network and no
crash dump. That is indistinguishable from the board being dead.

So the order is now mandatory, not stylistic:

    1. Nervezynq.PL.reload/1   -- get a bitstream in first
    2. anything touching the fabric

`Fabric.init/1` starting at application boot is now a live hazard, and the
existing note that it "should degrade to a port-less state rather than
crash-looping" is upgraded from a nuisance to a correctness requirement: it
should refuse to touch the bus until PCFG_DONE is set. `Nervezynq.PL` can read
that from devcfg `INT_STS` bit 2.

Verified not the cause of the post-reflash lockup: the DTB inside the flashed
`.fw` does contain `reserved-memory` / `pcap-readback@3fc00000` / `no-map`, so
the 4 MB DMA buffer is properly carved out and readback DMA is not writing over
live kernel memory.

Open: after the successful reflash and boot, restoring `/root` files and loading
`of_s9` succeeded (`PL: ok 111 ms`), then the board dropped off the network
mid-bring-up. JTAG could not be used to inspect it because the FT4232H had also
disappeared from USB, which points at a power or cable drop rather than a
software lockup. Re-check power before assuming a repeat.

## ROOT CAUSE: `PL.reload/1` never enabled the PS-PL level shifters

Two hard lockups after the reflash, both at the first fabric access, both taking
the board completely off the network (100% packet loss, no console, no crash
dump). Deterministic, 2 for 2. That reproducibility is what identified it.

### The mechanism

Programming the PL through devcfg does **not** make it reachable. The PS-PL
interfaces come out of reset isolated:

    SLCR 0xF8000240  FPGA_RST_CTRL   holds the PL AXI interfaces in reset
    SLCR 0xF8000900  LVL_SHFTR_EN    level shifters disabled

Until both are cleared, every fabric access goes into a bus with no slave. On
Zynq an AXI read with no responder **never returns** -- no error, no timeout, no
fault. The core wedges, Linux locks up, the board vanishes. Indistinguishable
from dead hardware.

Neither `Nervezynq.PL.reload/1` nor `Nervezynq.SLCR` ever touched either
register. Confirmed by grep across both modules.

### Why it was invisible until tonight

`libresdr.bit` on the SD card's boot partition meant **U-Boot** programmed the
PL and enabled these interfaces before Linux started. `PL.reload/1` inherited a
bus that was already open, and got away with never opening it itself.

Removing that bitstream fixed the U-Boot boot hang -- and in the same stroke
removed the only thing enabling the AXI path. One fix exposed the other bug.
The capability probe has been printing `slcr_mapped: NO` all along; it never
mattered because nothing needed SLCR while U-Boot was doing this work for us.

### The fix

`Nervezynq.PL.enable_ps_pl_interfaces/0`, called from `reload/1` immediately
after a successful load and before `Fabric.authorise/0`:

    unlock SLCR        0x008 <- 0x0000DF0D
    FPGA_RST_CTRL      0x240 <- 0x00000000     release AXI interfaces
    LVL_SHFTR_EN       0x900 <- 0x0000000A     PS->PL first
    LVL_SHFTR_EN       0x900 <- 0x0000000F     then all
    lock SLCR          0x004 <- 0x0000767B

Order is Xilinx's FSBL sequence, not arbitrary. SLCR is relocked afterwards so a
later stray write cannot reconfigure clocks or resets.

### The ordering rule, now enforceable

    1. PL.reload/1        programs the PL AND opens the bus
    2. anything touching Fabric / Regs / LVDSProbe / AD9363 SPI

`Fabric.init/1` running at application boot is a live hazard on a board that no
longer programs the PL from U-Boot. It should gate on devcfg `INT_STS` bit 2
(`PCFG_DONE`) and refuse to touch the bus until it is set, rather than mapping
and hoping.

### Diagnostic value of the JTAG session

Worth keeping: `openocd -f openocd/libresdr.cfg` reaches this board even when
Linux is wedged, and the useful registers are

    0xF800025C  BOOT_MODE      0x5 = SD
    0xE0100024  SDIO0 present  bit16 = card inserted
    0xE000B000  GEM0 net_ctrl  0 = Ethernet never enabled
    0xF8000900  LVL_SHFTR_EN   expect 0xF once the PL is usable
    0xF8000240  FPGA_RST_CTRL  expect 0x0

A JTAG halt plus `reg pc` sampling distinguishes "spinning in a retry loop"
from "hard AXI wedge" in about thirty seconds, and neither is visible any other
way when the console is unreachable.

### CORRECTION: the level shifters were NOT the cause

The section above is wrong and is kept only so the same theory is not re-derived.

Measured on the board, before touching anything:

    SLCR 0xF8000900  LVL_SHFTR_EN   0x0000000F   already enabled
    SLCR 0xF8000240  FPGA_RST_CTRL  0x00000000   already released

Both were already correct at boot. The **FSBL** in `BOOT.BIN` does this, not
U-Boot, so removing `libresdr.bit` never affected it. Writing them again changed
nothing and the next fabric access still hard-locked the board.

`Nervezynq.PL.enable_ps_pl_interfaces/0` also fails on this kernel:
`:file.pwrite` to `/dev/mem` returns `{:error, :efault}` (Nerves builds with
`CONFIG_STRICT_DEVMEM`). Use `Nervezynq.SLCR`, which already maps
`0xF8000000+0x1000` through `fabric_port` and reaches both registers. That
failure also left `reload/1` raising *after* `Fabric.invalidate/0` and before
`Fabric.authorise/0`, which is a second bug worth fixing on its own: a partial
`reload/1` must not leave the fabric gated off with no way back.

### What is actually established

    PL programmed          devcfg INT_STS bit 2 (PCFG_DONE) = 1
    Level shifters         0xF
    FPGA_RST_CTRL          0x0
    First fabric read      hard-locks the CPU, board off the network

Three times, deterministically, at `Fabric.read32(0x00)`.

And critically: **`of_s9` worked earlier the same evening** -- full AD9363
bring-up and a valid oracle (`mag_cv 3.4e-4`, `deg_per_sample -11.252`) -- on
the same bitstream, before the card was reflashed. So the design is fine and the
fault is in the post-reflash environment.

### The remaining hypothesis, untested

The PL is now programmed at RUNTIME rather than by U-Boot at boot, and the
programming sequence is incomplete. Xilinx's order brackets the load:

    1. LVL_SHFTR_EN   0x900 <- 0x00000000     isolate PS from PL
    2. FPGA_RST_CTRL  0x240 <- 0x0000000F     assert AXI resets
    3. program the PL through devcfg
    4. LVL_SHFTR_EN   0x900 <- 0x0000000A then 0x0000000F
    5. FPGA_RST_CTRL  0x240 <- 0x00000000     release AXI resets

This project only ever did step 3. It got away with it because the shifters were
already enabled from boot and the PL was already configured -- so a reload
replaced a working design with another working design and the AXI slave was
never observed mid-configuration.

With the PL unconfigured at boot, step 3 alone loads a design whose AXI slave
has never been reset while isolated. A slave that comes up in an undefined state
and never completes a transaction produces exactly this: a read that never
returns.

Note that `FPGA_RST_CTRL` needs a **pulse**, not a level. It already reads 0;
writing 0 again is a no-op. It must go 0xF then 0x0 around the load.

Also unchecked: **FCLK**. The PL AXI slave is clocked by FCLK0
(`SLCR FPGA0_CLK_CTRL`, 0xF8000170). If that clock is not running, the slave
cannot complete a transaction and the symptom is identical. `Nervezynq.SLCR`
already has `fclk_ctrl/1` and `fclk_hz/1` -- read them BEFORE the next fabric
access, since reading SLCR is safe and reading the fabric is not.

### Method note

Three hard locks were spent because each test touched the fabric directly. The
cheap checks -- SLCR clock and reset state, devcfg `PCFG_DONE` -- are all
PS-side and cannot hang. Exhaust those first. A fabric read is the most
expensive probe available and should be the last one, not the first.

### The bracketed programming sequence is ALSO eliminated

`scripts/pl_load.exs` (`PlLoad`) implements Xilinx's full sequence -- isolate
shifters, PULSE `FPGA_RST_CTRL` 0xF then 0x0, program, re-enable 0xA then 0xF,
release. Measured, cleanly:

    pcfg_done BEFORE   false
    loader             {"ok 112 ms\n", 0}
    pcfg_done AFTER    true
    lvl_shftr          0x0000000F
    fpga_rst           0x00000000
    fclk0              100.0 MHz     (matches the 99.99 MHz measured on silicon)

Everything correct. The very next `Fabric.read32(0x00)` hard-locked the board
anyway. Fourth lock.

So all of these are now excluded by measurement, not by argument:

    level shifters          already 0xF from the FSBL
    FPGA_RST_CTRL           released, and pulsed properly on the retry
    FCLK0                   running at 100 MHz
    PL configured           PCFG_DONE = 1
    programming sequence    full Xilinx bracket, loader returns 0

### The one difference that remains

`of_s9` **worked earlier the same evening** -- full AD9363 bring-up and a valid
oracle -- on this exact bitstream. The only thing that has changed is:

    THEN   U-Boot programmed the PL at boot (libresdr.bit on the boot partition),
           Linux started with a live fabric, and PL.reload/1 later swapped one
           running design for another.

    NOW    the PL is unconfigured when Linux boots. Nervezynq.Fabric starts and
           mmaps 0x40000000 against a fabric that does not exist yet. The PL is
           programmed afterwards, and the first access through that mapping
           never returns.

That points at the **mapping**, not the programming: an mmap of the PL aperture
created while no slave existed. Everything about the PL side is now verified
good, and the PS side is the only part that was set up under different
conditions than before.

### Next, in order of cost

1. **Restart `Nervezynq.Fabric` after programming**, so the mmap is created
   against a live fabric, then read. One line, one power cycle to test, and it
   directly tests the hypothesis above.
2. **Put a known-good bitstream back on the boot partition.** This is probably
   the real answer. The original design was correct -- configure the PL at boot
   -- and the only thing wrong with it was that `libresdr.bit` was a
   routed-but-broken build that hung U-Boot's devcfg. We removed the mechanism
   when we should have replaced the input. Generate a `.bit` from a build known
   to work (`of_s9`, `of_s33` or `ourfork_s4` -- all three passed SPI and
   capture) with `xc7frames2bit`, install it as `libresdr.bit`, and the
   environment that worked all night is restored, boot hang included.
3. Only if both fail: JTAG halt during the wedge and read the AXI interconnect
   state. Requires the FT4232H reconnected.

### Standing method note

Four power cycles were spent on this because each attempt ended in a fabric
read. `PlLoad.preflight/0` and `PlLoad.load/1` never touch the fabric and can be
run freely; `PlLoad.verify/0` is the only expensive call and is deliberately
separate. Keep it that way.

### CORRECTION 2: U-Boot never loaded the bitstream either

Measured from the firmware's own `uEnv.txt`:

    uenvcmd=mmcinfo && fatload mmc 0 ${kernel_load_address} ${kernel_image}
            && fatload mmc 0 ${devicetree_load_address} ${devicetree_image}
            && bootm ${kernel_load_address} - ${devicetree_load_address}

No `fpga load`. No `.bit` string anywhere in `uboot-env.bin`. **U-Boot does not
program the PL on this board.**

So "removing `libresdr.bit` fixed the boot hang" was an INFERENCE, not a
measurement. The reflash rewrote `uboot-env.bin`, both rootfs partitions, all of
the BOOT files and the A/B state simultaneously. Any of those could have been
the fix. The `.bit` was simply the most conspicuous difference, and it was the
wrong thing to credit.

Also note what the old card's boot partition actually held:

    uImage.a, uImage.b, zynq-libresdr.a.dtb, zynq-libresdr.b.dtb, no uEnv.txt

while the current firmware writes `uImage`, `zynq-libresdr.dtb` and a `uEnv.txt`.
Different filenames and no uEnv -- so that card was written by an OLDER firmware
revision, and it was running `Valid (B)`. The environment that worked all evening
was not the one now on the card.

### What this reframes

On the old card, `fpga state` read **`operating`** straight after boot, before
any `PL.reload/1`. On the freshly flashed card it reads `unknown`. Something in
the older setup configured the PL before Linux userland started, and it was not
U-Boot. That is the environment in which every successful fabric access tonight
happened.

The current firmware simply never programs the PL, so `Nervezynq.Fabric` maps the
PL aperture at boot against nothing, and the mapping is dead from then on.

### Therefore

Writing a `.bit` to the boot partition is pointless -- nothing reads it. The fix
belongs in software:

1. Cheap test, no reflash: program the PL at runtime, then RESTART
   `Nervezynq.Fabric` so it maps a live fabric, then read.
2. Permanent: have the application program the PL before `Fabric` starts, and
   gate `Fabric.init/1` on devcfg `PCFG_DONE` so it can never map a fabric that
   is not there.

### CORRECTION 3: nothing programs the PL at boot, in any layer

`lib/nervezynq/application.ex` starts exactly one fabric child --
`{Nervezynq.Fabric, []}` -- and never loads a bitstream. Combined with the
`uEnv.txt` finding (no `fpga load` in U-Boot) and no `.bit` reference in
`uboot-env.bin`, **no layer of this system programs the PL at boot**: not the
BootROM, not U-Boot, not the kernel, not the application.

So the `fpga state: operating` reading taken from the old card early in the
debug session cannot be explained by boot-time programming, and should not be
treated as evidence of it. Most likely it was residual driver state. It was the
observation that motivated the whole "restore boot-time configuration" line of
attack, and it did not support the weight put on it.

### Fifth lock: a fresh mmap does not help either

Programmed with the full bracketed sequence, then `Nervezynq.Fabric` stopped and
restarted so its mmap was created against a live, configured PL:

    fabric pid before   #PID<0.248.0>
    fabric pid after    #PID<0.330.0>
    info                {:ok, %{base: 1073741824, length: 131072}}
    authorise           :ok
    read32(0x00)        hard lock

So the stale-mapping hypothesis is dead too. Now excluded by measurement:

    level shifters, FPGA_RST_CTRL, FCLK0, PCFG_DONE, the Xilinx programming
    bracket, and the age of the mmap

### What is left, and what NOT to do next

Do not run another live fabric experiment. Five power cycles have produced five
eliminations and no positive result, and each costs the user real time.

The one fact still unexplained: **`of_s9` worked earlier the same evening** --
`PL.reload/1`, AD9363 bring-up, LVDS capture, a valid oracle. Same bitstream,
same board. The board was running `Firmware: Valid (B)` then; it now runs
`Valid (A)` from a `complete` flash. Both firmware slots were overwritten, so
the image that worked is gone and cannot be compared against directly.

That makes the firmware the last uncontrolled variable, and the only one never
tested. Everything else has been.

### Plan that does not cost power cycles

1. `mix upload` works over the network and does not need the SD card. Use it for
   all further firmware iteration; the card only needs `fwup` if the board stops
   booting entirely.
2. Bisect the firmware against git. The working configuration existed earlier
   tonight; find the commit, build it, upload it, and confirm `of_s9` + fabric
   works. That establishes a known-good baseline before changing anything else.
3. Only then re-apply changes forward.

### Cleanup owed

`Nervezynq.PL.enable_ps_pl_interfaces/0` (added tonight) is dead code built on a
disproven theory AND is broken -- `/dev/mem` returns `EFAULT` under
`CONFIG_STRICT_DEVMEM`. It also leaves `reload/1` raising after
`Fabric.invalidate/0` and before `Fabric.authorise/0`, stranding the fabric
gated off. Revert it, or reimplement via `Nervezynq.SLCR` only if a reason to
keep it appears. It is currently a liability.

## POSITIVE RESULT: the PL is correctly configured. The fault is PS-to-PL AXI only.

Used the readback instrument built earlier tonight -- devcfg, PS-side, cannot
hang the AXI bus -- to ask the fabric's configuration memory what is actually in
it after a `PlLoad.load/1` of `of_s9`:

    complete        true
    words landed    202 / 202
    frame 0x900     49 nonzero words
    head            20A80 0 20800 0 20800 0 20800 0

    vs base.frames  3 differing words out of 101
                    word  0   base 0x00020800   silicon 0x00020A80
                    word  9   base 0x00000000   silicon 0x00040000
                    word 50   ECC, device-computed, expected

`base.frames` was generated from a different build, so two differing routing
words is exactly right. This is a valid, fully-written bitstream.

### What this finally separates

    PL configuration        CORRECT -- proven by reading config memory back
    devcfg / readback path  WORKING -- 202/202 words, first try
    PS-to-PL AXI access     BROKEN  -- hangs the CPU on first read

Those are two different subsystems and they can now be reasoned about
separately. Everything up to and including getting bits into the fabric works.
The only broken thing is the AXI path from the PS to the design's slave.

That also means the readback/sweep work is NOT blocked by this. `:selfcheck`,
`:census` and the frame readback all run over devcfg and never touch the AXI
bus. The silicon characterisation can continue on a board whose fabric AXI is
dead. Only the AD9363 / LVDS oracle path needs AXI.

### Still unexplained, and the last uncontrolled variable

`of_s9` worked completely earlier the same evening on this same board -- AXI
included. The firmware is the only thing never held constant, and both slots
were overwritten by the `complete` flash. There is no git history for the
`nervezynq` tree, so the working image cannot be rebuilt from source either.

Candidates worth checking before another live attempt, all cheap:

* Whether the design's AXI slave is clocked by an MMCM inside the PL rather than
  FCLK0 directly. If that MMCM does not lock, the slave has no clock and an
  access hangs exactly like this. Nothing in the config memory reveals lock
  state -- it is dynamic -- but `SiliconSweep` can read the CMT's configuration
  and compare it against a build known to have worked.
* Whether `priv/fabric_port` in the rebuilt firmware differs from the one that
  was running. A wrong base or length would produce the same symptom.

## AXI failure is FIRMWARE-level, not design-specific

Tested two independent bitstreams, both of which had working SPI *and* LVDS
capture earlier the same evening (so both certainly implement the fabric
register map and both certainly worked over AXI):

    of_s9    load ok, PCFG_DONE, FCLK0 100 MHz -> Fabric.read32(0x00) hard lock
    of_s33   load ok, PCFG_DONE, FCLK0 100 MHz -> Fabric.read32(0x00) hard lock

Same result. The fault does not depend on the bitstream, so it is not a
routed-but-broken build and not an MMCM that fails to lock. It is in the PS-side
environment, i.e. the firmware.

### LEAD: slot B may still hold the firmware that worked

`fwup -t complete` writes the bootloader plus **one** rootfs slot and activates
it. Evidence it wrote only one: the .fw is 38.38 MB in / 42.11 MB out, and
`rootfs.img` alone is 30.2 MB -- that accounts for a single rootfs, not two. The
board reports `Firmware: Valid (A)` after both flashes.

If slot B was never overwritten, it still contains the image the board was
running earlier tonight -- the one under which `of_s9` worked completely, AXI
included. That is the known-good firmware I assumed was destroyed.

Check on next boot, all read-only:

    Nerves.Runtime.KV.get_all()

Look for `b.nerves_fw_uuid`, `b.nerves_fw_product`, `b.nerves_fw_version` and
`nerves_fw_active`. A populated `b.*` block with a UUID different from
`8b8c1a21-...` (`lottery-lab`, tonight's build) means slot B is intact and is
the older image.

If so, switching is a KV write plus a reboot:

    Nerves.Runtime.KV.put("nerves_fw_active", "b")
    Nerves.Runtime.reboot()

Reversible: if B does not boot, the bootloader's A/B fallback should return to
A, and worst case the SD card can be reflashed again from `_build`.

**Do this before any further AXI theorising.** If AXI works under slot B, the
difference between the two images is the entire remaining search space, and it
can be diffed offline rather than by burning power cycles.

### What was banked this round

Whole-tile pre/post-fix diff of the CMT: exactly two bits, `ZINV_PWRDWN` and
`ZINV_RST`. See SILICON_MAP.md section 18. That result needed only devcfg and is
unaffected by the AXI fault.

### Slot B lead CLOSED: it is erased

    /dev/mmcblk0p2  68737173 A50C0000   "hsqs" -- valid squashfs, slot A, current
    /dev/mmcblk0p3  FFFFFFFFFFFFFFFF    erased flash, no filesystem

Slot B holds nothing. `b.nerves_fw_uuid` is absent from the KV for the same
reason. The firmware that worked earlier tonight is unrecoverable -- the
`complete` flash destroyed it, and there is no git history for this tree to
rebuild it from.

That is a real loss and it was avoidable: the working firmware should have been
copied off the device (or the card imaged) before reflashing. **Before any
future `fwup -t complete` on a board whose current image works, image the card
first** -- `dd if=/dev/rdiskN of=backup.img` for the first ~350 MB covers the
bootloader and both rootfs slots.

### Consequence for the AXI fault

The comparison that would have isolated it is no longer possible. AXI remains
broken and unexplained, with these excluded by measurement: bitstream (two
independent designs), level shifters, FPGA_RST_CTRL, FCLK0, PCFG_DONE, the
Xilinx programming bracket, and mmap freshness.

**This does not block the project.** Everything in the silicon-characterisation
line runs over devcfg:

    frame readback      works, 202/202 words, first try
    :selfcheck          devcfg only
    :census             devcfg only
    pre/post-fix diff   devcfg only -- produced tonight's headline result

Only the AD9363/LVDS oracle needs AXI, and that is required solely by
`:functional`. Sections 13-18 of SILICON_MAP.md were all produced on a board
whose fabric AXI is dead.

## AXI investigation: eliminations, and the one surviving lead

### Eliminated by measurement tonight

    bitstream                of_s9 and of_s33 both hang; mmcm_* load fine
    level shifters           0xF before we ever wrote them (FSBL sets them)
    FPGA_RST_CTRL            0x0, and pulsed 0xF->0x0 on retry: no change
    FCLK0                    100.0 MHz, matches the 99.99 MHz measured earlier
    PCFG_DONE                set after every load
    Xilinx programming       full isolate/reset/program/restore bracket: no change
    mmap freshness           Fabric restarted post-load, new PID: still hangs
    loader determinism       3 loads of one file, 1212 words: 0 differences
    cache coherency          implied by the above -- the DMA is not corrupting
    native binaries          devcfg_load and fabric_port unchanged since Jul 31
                             17:35, i.e. the exact binaries that worked
    trailing startup clocks  16 KB of 0xFF appended to the .bin: no change
    boot chain               BOOT.BIN, u-boot.img, uImage and the DTB are all
                             BYTE-IDENTICAL to the pre-reflash card (sha256)

That last one matters most: the FSBL, `ps7_init`, U-Boot, kernel and device tree
on this card are bit-for-bit what was running when AXI worked.

### The surviving lead: kernel fpga_manager vs our userspace loader

On the pre-reflash card, `/sys/class/fpga_manager/fpga0/state` read
**`operating`** immediately after boot, before any `PL.reload/1`. It reads
`unknown` now, always.

`devcfg_load` drives DevC from `/dev/mem` and deliberately bypasses the kernel
driver, so it CANNOT set that sysfs state. Therefore on the old system something
programmed the PL through `zynq_fpga_manager` -- the real driver -- and it did so
at boot.

This was dismissed earlier in the session as "residual driver state". That was
wrong, and it is the only remaining difference between the two configurations.

So the hypothesis is: **a PL programmed by the kernel driver ends up in a
runnable state; a PL programmed by our userspace path does not**, even though
the configuration memory is provably identical and deterministic. The difference
would be in the completion/startup handling, not the frame data.

### The plan this implies

`devcfg.rs`'s own header documents why the kernel path was unavailable: no
`/dev/xdevcfg`, no `firmware` attribute on the fpga_manager, no configfs
overlays, and `/fpga-full` carries **no `firmware-name`**, so `of-fpga-region`
never programs on probe.

That last point is the actionable one. `CONFIG_OF_OVERLAY=y` is set and the
machinery is present -- what is missing is a `firmware-name` property. Adding it
to the `fpga-full` node in the DTB, with the bitstream placed in the rootfs
firmware directory, makes the kernel program the PL at probe through the proper
driver. That almost certainly reproduces the `operating` state, and with it the
working AXI path.

It is a DTB edit plus a rootfs file: buildable offline, one reflash to test, and
it removes the userspace loader from the boot path entirely.

Keep `devcfg_load` for fast iteration -- it is deterministic and correct as far
as the configuration memory goes, which is exactly what the silicon-readback
work needs. The kernel path is for getting a *runnable* fabric.

## The original boot hang is EXPLAINED (and reproduced deliberately)

Added to the U-Boot environment, via `Nerves.Runtime.KV` (which writes the
U-Boot env directly -- no reflash, no card removal):

    if load mmc 0:1 0x4000000 system.bin; then fpga load 0 0x4000000 ${filesize}; fi;

inserted into `nerves_boot` before the kernel load, with `system.bin` = `of_s9`
copied to the FAT boot partition. Env write verified (506 bytes, `fpga load`
present). Rebooted.

**The board did not come back.** Five minutes of polling, no ping, no ssh.

### What this establishes

1. **U-Boot on this board hangs when asked to program the PL from an openXC7
   bitstream.** `of_s9` loads perfectly through `devcfg_load` -- 111 ms, and
   three consecutive loads produce bit-identical configuration memory -- yet it
   hangs U-Boot's `fpga load`.

2. **This retroactively explains the original boot hang.** The pre-reflash card
   had `libresdr.bit` on the boot partition and, almost certainly, an
   `fpga load`/`loadb` in its stored U-Boot environment. The hang we found by
   JTAG -- a `cmn r0,#11 / beq` retry loop at `0x3ff569d4`, i.e. a driver op
   returning `-EAGAIN` forever -- is U-Boot's zynq fpga driver polling for
   `PCFG_DONE` that never arrives. The reflash "fixed" booting by replacing the
   environment, not by deleting the `.bit`.

   That was the open question from earlier in the session. It is now answered,
   at the cost of reproducing the fault on purpose.

3. It also explains `fpga0/state = operating` on the old card: U-Boot had
   programmed (or half-programmed) the PL before Linux started, so `PCFG_DONE`
   was set and `zynq_fpga_ops_state()` reported `operating`.

### The mistake

`fpga load` takes a raw `.bin`; `fpga loadb` takes a `.bit` with its header.
Our `.bin` files are byte-swapped for DevC (`66 55 99 AA`), which is not
necessarily what U-Boot's `zynq_validate_bitstream` expects from `fpga load`.
The correct call was probably `fpga loadb` with a real `.bit` -- generatable
with `xc7frames2bit`, which is built in the prjxray tree.

But note the old card hung too, and it had a genuine `.bit`. So "U-Boot's
loader cannot handle openXC7 bitstreams at all" remains live and is arguably
the better-supported reading.

### Rule going forward

**Do not modify the boot path on this board while there is no console.** The PS
console UART is not wired to any of the four FT4232H channels (verified by
writing bytes directly into the UART0 TX FIFO over JTAG and watching all three
UART channels). Without it, any boot-path failure is invisible and costs a card
reflash. JTAG can inspect a hung U-Boot but cannot recover it -- there is no
SRST wired either (`Error: zynq.cpu0: how to reset?`).

Boot-path changes should wait until either a console exists or the change can be
tested in a way that cannot hang.

### Recovery

    diskutil unmountDisk /dev/disk4
    sudo fwup -a -i _build/libresdr_dev/nerves/images/nervezynq.fw -t complete -d /dev/rdisk4

Restores a clean environment. `/root/nerves_boot.bak` (the original 424-byte
`nerves_boot`) is lost with the data partition, but the correct value is
recorded in this file above and in the KV dump earlier in the session.

## The AXI hang, characterised by JTAG

Triggered deliberately with JTAG attached and Ethernet as transport (so the
debug cable no longer costs us usb0). `of_s9` loaded, `PCFG_DONE` set,
`FCLK0` 100 MHz, `LVL_SHFTR_EN` 0xF. Then `Fabric.read32(0x00)`.

    zynq.cpu0   running
    zynq.cpu1   running
    Error: timeout waiting for DSCR bit change
    Error: Error waiting for halt

**Neither core can be halted.** On Cortex-A9 a debug halt cannot retire while a
memory access is outstanding, so a core stalled on a bus transaction is
un-haltable. Both cores are stalled, because they share the L2/AXI path -- once
the interconnect is blocked, any memory access by either core stalls behind it.

### What this settles

The access **reached the bus and no slave responded**. That was the open
question: "the PL slave never answers" versus "the access never got there". It
is the former.

Consequences:

* There is **no timeout** on M_AXI_GP0. A read with no responder wedges the
  interconnect permanently.
* There is **no software mitigation**. Not a supervisor, not a process
  boundary, not a watchdog -- both cores are stalled, so nothing runs to
  recover.
* JTAG cannot recover it either: halt fails, and there is no SRST wired
  (`Error: zynq.cpu0: how to reset?`). Only a power cycle.

So `Fabric.read32/1` against an unproven design is the single most destructive
operation available in this project, and it is a plain function call.

### A SAFE AXI probe, for next time

JTAG DAP transactions have timeouts and report errors; a Linux load does not and
wedges. So the fabric can be probed WITHOUT risking the board:

    openocd -f openocd/libresdr.cfg -c init -c "halt" -c "mdw 0x40000000 1" \
            -c "resume" -c shutdown

with the core halted first. If the slave answers, the word is printed. If it
does not, OpenOCD reports a DAP error and the board survives -- because the
stalled transaction belongs to the debug port, not to a running core.

**Use this before ever calling `Fabric.read32/1` on a new bitstream.** It turns
the most expensive operation in the project into a cheap one. It should have
been the first thing tried tonight.

### Still unexplained

Why the slave does not respond. Everything checked is correct: bitstream
complete with a textbook `RCRC/GRESTORE/LFRM/START` tail, configuration memory
bit-exact and deterministic across three loads, PCFG_DONE set, clocks running,
level shifters up, resets released, boot chain byte-identical to when AXI
worked, native binaries unchanged, Elixir path correct (`Fabric.info/0`
round-trips fine while `read32/1` hangs).

The only uncontrolled variable remains `fabric.ex` / `port_wire.ex`, edited at
Aug 1 01:10 -- the timestamp of the firmware we now boot -- while the
configuration that worked was the older slot-B build. Inspection of both files
shows nothing wrong, and there is no copy of the previous version to diff
against.

### CORRECTION: `mdw phys` is NOT a safe probe

The "safe AXI probe" proposed above is wrong as written, and testing it cost a
power cycle.

    mdw 0x40000000          SAFE but useless.  Goes through the MMU and faults
                            before reaching the bus:
                            "data abort at 0x40000000, dfsr = 0x00000005"
                            (section translation fault -- the address is simply
                            not in the kernel page tables). Board survives.

    mdw phys 0x40000000     NOT SAFE. OpenOCD implements physical access on
                            cortex_a by EXECUTING LOAD INSTRUCTIONS ON THE
                            HALTED CORE with the MMU disabled. Same core, same
                            bus read, same stall:
                              Error: Error waiting for cortex_a_exec_opcode
                              Error: Error waiting for dpm prepare
                            Board dead, 100% packet loss.

So JTAG does not make the probe safe by itself -- it depends entirely on WHICH
path OpenOCD uses, and `cortex_a` uses the core for both variants.

### The variant that might actually be safe -- UNTESTED

Read through the DAP's AHB-AP directly, with no core involvement, by creating a
`mem_ap` target:

    openocd -f openocd/libresdr.cfg \
      -c "target create zynq.mem mem_ap -dap zynq.dap -ap-num 0" \
      -c "init" -c "targets zynq.mem" -c "mdw 0x40000000 1" -c "shutdown"

On Zynq the DAP normally exposes AP0 = AHB-AP (system memory) and AP1 = APB-AP
(debug). An AHB-AP read is issued by the debug port, not by a CPU, so a stalled
transaction should belong to the DAP and time out there rather than wedging a
core.

**That is the theory and it has not been tested.** Verify it the same way the
last one should have been: run it once with the PL UNCONFIGURED, where there is
definitely no slave, and check the board still pings afterwards. Only if it
survives that is it usable as a probe.

Do not repeat the mistake of announcing a probe as safe before the negative case
has been run.

---

# The JTAG "safe probe" is one-shot per power cycle — and the DP is not the problem

The `mem_ap` / AHB-AP probe found earlier does survive a PL AXI read that would
hard-lock the CPU: the board stays up (`ping` 0% loss, `ALIVE` over ssh). But it
is **not repeatable**. After one failed probe every subsequent access reports
`JTAG-DP STICKY ERROR`.

Recovery attempts, in order, and what each proved:

    zynq.dap dpreg 0x0 0x1f        DP ABORT, all five clear bits   no effect
    debug power down/up            CTRL/STAT 0x0 then 0x50000000   made it worse:
                                   "Debug regions are unpowered"
    jtag arp_init-reset + ABORT    full JTAG state-machine reset   DP recovers,
                                   AP does not

The last one is the informative one. After it, CTRL/STAT reads:

    0xf0000000    CSYSPWRUPACK | CSYSPWRUPREQ | CDBGPWRUPACK | CDBGPWRUPREQ
                  and NO sticky bits set

So the **debug port is clean and fully powered**. The sticky error returns only
on `arp_examine`, i.e. on the first access that goes through the AHB-AP. The
stall is held in the AP / PS interconnect, not in the DP, and `DAPABORT` does
not reach it.

That is consistent with the Zynq behaviour already established for M_AXI_GP0:
a read with no responder never completes and there is no timeout. The AHB-AP
inherits that stall like any other master. Nothing on the JTAG side can clear
it because there is nothing wrong on the JTAG side.

**Operational consequence:** budget ONE PL AXI probe per power cycle. The board
survives, which is a real improvement over the Elixir path (that takes the whole
BEAM down), but the bitstream sweep is one design per cycle, not four in one.

Do NOT write CTRL/STAT to 0 to "power cycle the debug domain". It drops
CDBGPWRUP and the recovery is strictly harder afterwards.

## Reverted: PL.enable_ps_pl_interfaces/0

Removed as previously flagged. It was dead code from a disproven theory
(level shifters were already `0xF` at boot, set by the FSBL), it was broken
under `CONFIG_STRICT_DEVMEM` (`:file.pwrite` on `/dev/mem` returns
`{:error, :efault}` for non-RAM physical addresses), and its raise sat between
`Fabric.invalidate/0` and `Fabric.authorise/0` in `reload/1`, so hitting it left
the fabric gated off with no way back short of a restart.

---
---

# STATE DUMP — end of the readback-instrument session

Everything below is measured or implemented, not planned. Planned work is at
the bottom, clearly separated.

## Board access

**Use the USB link. It is the only path that does not depend on the WAN.**

    board        172.31.248.125     (usb0)
    workstation  172.31.248.126     (usb0)
    file server  http://172.31.248.126:8101
                 serving ~/src/ehdl/designs/libresdr_radio/taps/serve

The LAN address changes every boot (observed .57, .60, .58 in one evening) and
vanished entirely when the workstation moved to a mobile hotspot. The USB
gadget link is point-to-point, needs no router, and survived that transition.
`ssh 172.31.248.125` drops straight into IEx.

There is no console. The PS UART is not wired to any FT4232H channel --
verified by writing bytes into the UART0 TX FIFO over JTAG and seeing nothing.
**Never modify the boot path.** A bad boot is unrecoverable without reflashing.

## The instrument, and what it is now known to do

### Files

    nervezynq/scripts/silicon_sweep.exs   canonical harness
    nervezynq/scripts/rb_check.exs        standalone readback probe
    <serve>/pl_load.exs                   bracketed PL loader
    <serve>/mirror.exs                    mirror-census batch
    <serve>/confine.exs                   confinement batch

`<serve>` copies are what the board fetches; `nervezynq/scripts/` is canonical.
Keep them in sync -- there is no git in this tree, so a drift is silent.

### Bootstrap, in order, on a fresh boot

    :inets.start()
    fetch silicon_sweep.exs, rb_check.exs, pl_load.exs -> /data
    Code.compile_file/1 on each
    SiliconSweep.Devcfg.start_link()      # NOT started by the app
    SiliconSweep.DmaBuf.start_link()      # NOT started by the app
    PlLoad.load("/data/mmcm_zinv.bin")    # THE PL IS EMPTY AT BOOT

`SiliconSweep.probe/0` reports every prerequisite by name and is the gate.

### The PL is NOT configured at boot

`PlLoad.preflight/0` reports `pcfg_done: false` on every fresh boot, confirmed
three times. The bitstream was removed from the SD boot partition to fix a
U-Boot hang and nothing replaced it. A readback against an unconfigured PL
returns a clean stream of zeros that completes without error and looks exactly
like a broken instrument. It cost most of an hour. Gate on
`PlLoad.pcfg_done?/0` -- PS-side, cannot hang.

### Readback API and its invariants

    words_for(n)       (n + 1) * 101      what the DMA collects
    engine_words(n)    == words_for(n)    what the command stream requests
    request_frames(n)  n + 2              frames to ASK for to get n aligned
    align/1            measured per read, returns %{lead:, offset:, confident:}
    to_frames/1        {:ok, frames, align} | {:error, {:unaligned, a}}
    split/2            split at a KNOWN offset -- callers that measured one
    readback_tile/1    public; asks for request_frames(tile.frames), trims back
    write_frames/2     public; MUST build payload via write_payload/1

**Symmetric lengths.** `engine_words == words_for` is deliberate. Both
asymmetric variants stalled the engine and cost a power cycle each:

    DMA 3232 / engine 3131    inverted the rule outright
    DMA 3232 / engine 3333    stalled on the SECOND read after a load, having
                              succeeded on the first

The second is the informative one: **the engine's output is not governed by
the type-2 count alone.** The asymmetric-lengths trick recorded earlier in this
file holds for short register-style reads where the collect count is far below
the production count. It does not generalise to one frame below.

**The lead is not a constant.** Measured lead 14 on one boot, 0 on the next
two, same board, same bitstream, same code, with the 209-assertion set
confirming each independently. Stable within a boot, which is what makes it
dangerous. Measure every read; never hardcode. Full detail in SILICON_MAP.md
section 22.

## Results, all reproduced through the harness path

    prjxray zynq7 CMT segbits          209 assertions, 0 disagreements
    census                             3136 / 3136 candidate positions
    mirror census                      3136 / 3136 proven BIDIRECTIONAL
    confinement                        36 frames compared, 0 collateral changes
    stability                          9 consecutive reads, no stall, queue idle

### The three-state round trip

    pristine      209 agree,   0 disagree
    all ones      206 agree,   3 disagree     (the 3 must-be-0 flip)
    all zeros       3 agree, 206 disagree     (the 206 must-be-1 flip)

The set contains 206 must-be-1 and 3 must-be-0. Both outcomes were predicted
before running and both came out to the bit. This exercises the write path,
the read path and prjxray's database simultaneously; a displaced reader, a
misdirected writer or a wrong database each fail it visibly and differently.

### Confinement is what licenses poke-and-observe

Ones into minors 28/29 words 0..48, then 36 frames compared word for word:
98 changed, all intended, **zero collateral**. Nothing moved in words 49..100
(shared with `HCLK_CMT_L` at offset 45 and `INT_L` at offset 48, whose windows
overlap this tile) and nothing moved in minors 30..35. A behaviour change after
a poke can therefore be attributed to the poked bits.

## Defects found and fixed this session

  * **`write_frames/2` omitted the pipeline pad frame.** Built its payload with
    `List.flatten/1` while `write_sequence/2` declares an FDRI packet of
    `(n+1)*101`. The engine sat mid-packet, consumed DESYNC as frame data, and
    the NEXT readback stalled -- so it presents as a broken reader. `:census`
    was immune because `write_all_ones/2` already used `write_payload/1`;
    `poke_load_test/4` was not, so the whole `:functional` strategy would have
    hit this on its first poke. Fixed and confirmed on silicon.
  * **`PL.enable_ps_pl_interfaces/0` reverted.** Dead code from a disproven
    theory, broken under `CONFIG_STRICT_DEVMEM`, and its raise sat between
    `Fabric.invalidate/0` and `Fabric.authorise/0`, stranding the fabric gated
    off.

## Hazards, each of which has cost at least one power cycle

  * A DMA that collects more than the engine produces stalls it. Recovery is a
    POWER CYCLE -- a reboot does not clear it and may not boot.
  * Never write CTRL/STAT to 0 to "power cycle the debug domain" over JTAG. It
    drops CDBGPWRUP and recovery gets strictly harder.
  * `mdw phys` on a `cortex_a` target executes loads on the core and wedges the
    board. Use a `mem_ap` target.
  * One PL AXI probe per power cycle. After a failed probe the AHB-AP holds the
    stall; the DP is clean (`CTRL/STAT 0xf0000000`, no sticky bits) and
    `DAPABORT` cannot reach it. The board survives, unlike the Elixir path.

## Operational notes on the tooling

  * **`mix nerves.discover.first -q` does NOT leave only the IP on stdout.**
    Mix's own environment banner and compile output precede it. Take the last
    line; `$(mix nerves.discover.first --quiet)` is broken on any run where mix
    has something to say, which includes the first run in a session.
  * **`wait_for_channel` is capped at ~60s** by the MCP layer whatever timeout
    is passed. Let the shell own the deadline and write results to a file; the
    channel is only a wake-up, and its signal is edge-triggered so it can be
    missed. Read the file, do not re-wait.
  * A board-reachability test cannot distinguish "board rebooted" from "my
    network went away". Key reboot detection on BEAM uptime, not on ping.

## Open questions

  * **What does the readback lead depend on?** Untested candidates: FCLK,
    engine state at load time, DESYNC history of the previous stream.
  * **Fabric AXI is still dead** and unexplained. Everything except the
    firmware build has been eliminated by measurement; the working image was
    destroyed by a `fwup -t complete` and there is no git history to rebuild it.
  * **GCAPTURE yields nothing.** 8 frame ranges, full tile, FASM-derived
    columns, explicit RCRC/GRESTORE/START, 1024 clocks -- all zero. Any plan
    that measures dynamic state via capture-and-readback is void on this setup.

## Next, in the order I would do it

  1. **Falsify the DRP premise before building anything.** The whole
     DRP-differential approach assumes MMCM DRP registers and CMT configuration
     bits are the same storage. If the DRP file is separate storage initialised
     at load, DRP writes will not appear in readback and the approach is void.
     Minimal harness, ONE DRP write to one known field, one readback. Cheapest
     test of the most expensive assumption.
  2. **EMIO GPIO as the AXI-free bridge.** PS GPIO banks 2/3 route into the
     fabric from the controller at `0xE000A000` -- a PS peripheral like SLCR
     and devcfg, with no M_AXI_GP0 involvement. Bit-bang DRP from Elixir.
  3. **Read the observables back over EMIO GPIO INPUTS, not GCAPTURE.** Route
     `LOCKED` and the high bits of a free-running counter clocked by the MMCM
     output to EMIO inputs. Two reads a known interval apart give frequency.
     This replaces the dead capture path and resurrects a general functional
     oracle, which is worth more than the CMT work on its own.
  4. Desk gap analysis: diff prjxray's zynq7 CMT segbits against the full
     attribute inventory to get a finite target list. No board needed.
  5. Deferred: static-only attributes by bit-flipping; census extension to
     other tile types.

Cite XAPP888 for the lock/filter table words rather than claiming independent
derivation -- silicon only ever shows one row at a time, and the provenance
matters.
