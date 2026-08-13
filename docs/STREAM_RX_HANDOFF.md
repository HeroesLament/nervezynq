# STREAM_RX handoff — gapless RX over HP0 DMA (SDR V2)

Pass-on for the next Fable instance. Goal: replace snapshot capture with a
continuous, gapless receive stream — `Nervezynq.SDR.stream_rx/2` — fed by the
HP0 DMA engine that already streams into DDR (HPDMA_SESSION.md). The immediate
consumer is the `scope/` waterfall GUI (NzScope), which is live on silicon
today but rate-starved by the snapshot path. This document is written after a
session that got the GUI working end-to-end against the V1 snapshot driver and
measured exactly where it hurts.

Everything marked **measured** was seen on the board this session (board
`lottery-lab`, bitstream `hp_dma_s0.bin`). Everything marked **proposed** or
**test this** is design not yet run — do not treat it as fact.

---

## Why this is needed, with the number

The scope works. Silicon → tap → TCP → host FFT → GL waterfall, all proven this
session (see SCOPE_V1 notes / `scope/README.md`). It draws real 2.4 GHz energy,
the DC-offset spike lands at center as predicted, retune/gain round-trip through
the board. It is just **slow**: **measured 0.4 rows/s at 1020 pairs, 1.0 rows/s
at 512 pairs.** A waterfall that scrolls one line a second cannot show Wi-Fi
frames — the snapshot duty cycle is a ~64 µs peek per second.

The cost is **not** the GUI, the FFT, or the TCP link — all three idle waiting
on the board. It is the capture readout. `LVDSProbe.capture/1` walks the buffer
one word at a time:

```elixir
words =
  Enum.map(0..(n - 1), fn addr ->
    Regs.put_cap_rd_addr(addr)   # AXI-lite WRITE: set read address
    Regs.cap_word()              # AXI-lite READ:  get one word
  end)
```

For a 1020-pair frame `rx/1` asks for `n*4+8 ≈ 4088` words → **~8000 port
round-trips per frame**. `Nervezynq.Fabric`'s own `read_repeat/2` docstring
gives the arithmetic that kills us: *"A read costs ~1.06 µs of bus time and
~215 µs as its own userspace call."* 8000 × ~215 µs ≈ 1.7 s of pure round-trip
overhead per frame, before decode. That is the 0.4–1.0 rows/s, exactly.

The bus is fast. The **per-call round-trip through the Rust port** is what we
pay 8000 times. Two independent fixes below attack this: one cheap and
software-only (Tier 0), one the real V2 milestone (DMA).

---

## Tier 0 — collapse the readout round-trips (do this FIRST)

**Before building DMA, spend one session here. It may make DMA unnecessary for
the waterfall use case**, and it de-risks everything downstream because it's
pure software with no bitstream rebuild.

`Nervezynq.Fabric` already carries the primitives:

- `read_block(offset, count)` — `count` consecutive addresses, one port call.
- `read_repeat(offset, count)` — the SAME offset `count` times, one port call.
  Its docstring: *"pulling a whole capture buffer in one call is roughly 200x
  faster than reading it word by word."* Written for *"a register in front of
  an auto-advancing buffer … whose read pointer steps on every access."*

The catch: the current `hp_dma_s0` capture uses **explicit addressing**
(`Regs.put_cap_rd_addr` then read `cap_word`), which is *not* what `read_repeat`
assumes. So **test this first** (one IEx session on the board, no rebuild):

1. `LVDSProbe.capture` (arm + wait for done), then read `status3` (offset
   `0x28`) via `Fabric.read_repeat(0x28, N)` **without** touching the address
   register between reads. Compare to the addressed readout of the same buffer.
2. If they match → the read port auto-advances; drop `read_repeat` straight
   into `capture/1` and you've got the ~200× win. `rx()` goes from ~2 s to
   ~15 ms; the waterfall is instantly live at tens of rows/s.
3. If they don't match (read port is strictly addressed), the buffer is behind
   an addr-reg + data-reg pair, so neither `read_block` nor `read_repeat`
   applies as-is. Two options, pick by cost:
   - **Native batched op (recommended, no bitstream change):** add an op to
     `native/fabric` (the Rust `fabric_port`) that takes
     `(addr_reg, data_reg, count)` and loops in native code — write addr, read
     data, ×count — returning all words in ONE port round-trip. This mirrors
     `read_repeat`/`read_block` and collapses 8000 BEAM↔port hops into 1 while
     keeping the ~1.06 µs bus cost. Same ~200× outcome. Wire it through
     `PortWire` + a new `Fabric.read_capture/2`, then use it in
     `LVDSProbe.capture/1`.
   - **Fabric tweak:** make the data register auto-advance the read pointer on
     read, then `read_repeat` applies directly. Needs a bitstream rebuild, so
     prefer the native op unless you're rebuilding anyway.

Confirm the exact readout interface from `ehdl/designs/libresdr_radio` (the
capture buffer read port) + `regmap.exs` + `Nervezynq.Regs` before choosing.

**Tier 0 gets a watchable waterfall.** DMA (below) is still the right answer for
*true gapless* streaming and the beacon-depth continuous capture the SDR plan
needs — snapshots have dead time between frames no matter how fast the readout.
But if the near-term goal is "watch the band," Tier 0 likely suffices and ships
in a day.

---

## The DMA path — what's proven, what's missing

### Proven on silicon (HPDMA_SESSION.md, **measured**)

- HP0 DMA streams **gapless, zero BRESP errors, 64-bit** into a DDR ring at
  `0x3FF0_0000` (top 1 MB of the existing DmaBuf reservation). Measured:
  bursts 12074→51625 in 200 ms, `bresp_errs 0`, ring readout of 64 consecutive
  64-bit integers with deltas uniformly +1 after ~54k bursts and multiple 1 MB
  wraps. First PL-mastered DMA into DDR on this board, no vendor tools.
- Producer today is a **synthetic incrementing counter**, not radio samples.
- Enable is over **EMIO** (bank2 bit 0, gpiochip line 54). AFI reset defaults
  are correct (BRESP clean, 64-bit width). Readout via `mmap`.

### Missing piece 1 — the fabric revision (bitstream rebuild)

Swap the counter producer for **packed LVDS samples**. This is the
"sample-pack + FIFO fabric revision" SDR_V1 and HPDMA both point at. The LVDS RX
stream must feed a FIFO whose 64-bit output words the DMA engine bursts to DDR.
This is an EHDL / openXC7 change + fasm audit + new bitstream — the heavy part.

Decisions the fabric revision must pin (and mirror in the decoder):

- **Packing format.** Define exactly what each 64-bit DDR word carries. The
  natural choice mirrors the capture word: `sample_a` (rise), `sample_b`
  (fall), RX_FRAME pair — but you have 64 bits to spend, so consider packing a
  whole 4-word frame (I1/Q1/I2/Q2) per beat to make host decode trivial and
  self-framing. Whatever you choose, it must be the SINGLE source of truth,
  documented in `Nervezynq.SampleFormat` terms.
- **Keep `nibble_swap: false`.** This fabric family carries the fixed sample
  assembly `sample_a = {rise_q_d, rise_q}` (top.ex), which is why the V1 driver
  pins `@nibble_swap false` and it decodes to 11.25°/sample, mag_cv 3.4e-4. The
  DMA packer MUST use the same edge assembly so the streamed decode stays
  nibble_swap-false. If it doesn't, you'll chase a 62°/cv-0.38 ghost.
  (Note `MIMO.@fabric_needs_nibble_swap` still defaults `true` — SDR_V1
  next-step #1 is to make it a runtime probe. Do that in the same campaign so
  the stream decoder and the snapshot decoder agree without a pin.)
- **A write-pointer / fill-level status register.** The proven counter demo
  read a free-running ring by mmap with no producer position. A stream needs to
  know how far the producer has written. GP0 works now (post-throttle-fix), so
  the AXI-lite `write_ptr` register HPDMA next-step #6 anticipated is available
  — expose current write offset (and a wrap/overflow flag) in a STATUS word.

### Missing piece 2 — the `stream_rx/2` software (this repo)

Consumer side, all in `nervezynq/`:

1. **Ring reader.** mmap the DmaBuf ring region via `Nervezynq.PortWire`
   (NOT AFI — see hazards) and read the fill region. `read_block` over the ring
   aperture is the batched read here (contiguous DDR, unlike the capture buffer).
2. **Write-pointer tracking + wrap handling.** Poll the write_ptr status reg;
   read the delta since last poll; handle 1 MB ring wrap. Detect overflow
   (producer laps consumer) via the wrap/level flag and the `bursts`/`bresp_errs`
   counters — and `log()` it, never silently drop.
3. **Decode routing** — the key design fork, below.
4. **API.** `Nervezynq.SDR.stream_rx(pid_or_fun, opts)` — start DMA, spawn the
   consumer loop, deliver decoded frames (or raw words) to the caller. Mirror
   the V1 facade shape so it slots into `sdr.exs` beside `rx/1`. `open/1`
   already does the platform ritual (THR_CNT release, guard, magic) — stream_rx
   inherits it.

### The decode-location fork — decide explicitly

At stream rates, pure-Elixir `MIMO.decode` on the 667 MHz A9 becomes the *next*
bottleneck after readout. Options:

- **(a) Decode on board.** Simplest; keeps the API returning `{i,q}` pairs like
  `rx/1`. But A9-bound — likely caps sustained rate.
- **(b) Ship raw 64-bit DDR words to the host, decode on the Mac.**
  **Recommended for the scope path.** The scope already has the plumbing:
  `NzScope.Link` receives framed binaries and runs the FFT; it would gain a
  `MIMO.decode` port (pure Elixir → Elixir, straightforward) and the board tap
  just DMA-drains and ships. Takes the A9 out of the hot path entirely. The tap
  protocol already carries everything per-frame, so this is a small host change.
- The scope tap (`wf_tap.exs`) grows a `:stream` mode; `NzScope.Link` already
  handles arbitrary frame rates (tested to 20 rows/s against the Sim). At true
  DMA rates you'll likely **decimate or coalesce** on the tap before shipping —
  the waterfall only needs ~30 rows/s, not the full sample stream. Flag this so
  nobody tries to push 8 Msps over usb0.

---

## Hazards to carry forward (written in blood — do not relearn these)

- **NEVER read AFI0 (`0xF800_8000`) from Linux.** One `read32` of offset 0
  through a fresh mapping killed the board — CPU hang, no oops, power cycle lost
  (HPDMA_SESSION). SLCR and devcfg map fine; AFI does not. You do not need AFI:
  BRESP=OKAY already proved the defaults. If AFI values are ever truly needed,
  JTAG mem_ap is the only safe route.
- **THR_CNT throttle.** `SLCR FPGA0/1_THR_CNT` reading 1 halts every PL clock
  while divisors read as configured — the 2026-08-02 "dead fabric" root cause.
  `SDR.open/1` releases it idempotently; `stream_rx` inherits that via `open`.
  Any cold boot needs it before any fabric access.
- **Bitstream reload invalidates the guard.** If `stream_rx` ever swaps the
  bitstream at runtime (e.g. to load the DMA-radio build), it MUST go through
  `PlLoad` + `Fabric.invalidate/0` before and `Fabric.authorise/0` after
  hardware-confirmed `PCFG_DONE`. Reading an unconfigured aperture hangs the CPU
  with no recovery — the guard is the only thing standing between you and a
  power cycle. `devcfg_load` pulses PROG_B (erases the running design) before
  the first byte, so a mid-load failure leaves the PL blank and lethal.
- **SPI framing (same driver, unrelated path):** never clock >24 clocks for a
  single-byte AD9363 access — desyncs the SPI state machine, presents as a dead
  chip, needs RESETB. Not stream-specific but you're in the same module.

---

## Order of work

1. **Tier 0 readout fix** (1 session, software only). Confirm the capture read
   interface; drop in `read_repeat` or add the native batched `fabric_port` op;
   measure the new `rx()` time. Likely gets the waterfall watchable on its own.
2. **Fabric revision** (the big one): LVDS → FIFO → HP0 packer + write_ptr
   status reg. EHDL design change, openXC7 PAR, fasm audit clean, new bitstream.
   Pin the packing format and keep the edge assembly nibble_swap-false.
3. **`stream_rx/2` software**: ring reader (batched `read_block`), write-ptr
   tracking, wrap + overflow handling, decode routing (prefer host-side decode
   for the scope).
4. **Wire the scope**: `wf_tap.exs` gains `:stream` mode; port `MIMO.decode` to
   the host in `nz_scope`; decimate/coalesce on the tap to ~30 rows/s.
5. **Verification gates:**
   - **Known-answer through the DMA path.** Inject the `Fs/32` BIST tone and
     stream it: `deg_per_sample` must be 11.25 and `mag_cv` < 1e-2 on both
     channels *after* DMA packing + decode. This is the same gate `selftest/0`
     uses; it has caught every decode bug this project has had. If the DMA
     packer mangles edge order, this fails loudly — which is the point.
   - **Gapless continuity.** Sequence/timestamp continuity across ring wraps;
     the +1 delta invariant the counter demo proved must survive with real
     samples (adapted to the sample format).
   - **Sustained rate** (HPDMA Gate 4): radio-rate producer, sustained MB/s vs
     bursts-over-wallclock, overflow flag never set under normal load.

---

## File map

Board / firmware (`~/src/nervezynq/nervezynq/`):
- `scripts/sdr.exs` — the V1 facade; `stream_rx/2` lands here beside `rx/1`.
- `scripts/wf_tap.exs` — the scope tap; gains `:stream` mode.
- `lib/nervezynq/lvds_probe.ex` — `capture/1`, the word-at-a-time readout to fix
  in Tier 0.
- `lib/nervezynq/fabric.ex` — `read_block/2`, `read_repeat/2` (the 200× note),
  the guard (`invalidate/0`/`authorise/0`), and the register map.
- `lib/nervezynq/mimo.ex` — `decode/2`, `validate/2`; the `@fabric_needs_nibble_swap`
  default to turn into a runtime probe; the frame cycle `[3,1,0,2]`.
- `lib/nervezynq/sample_format.ex` — the settled bit map (`decode_mimo/2`);
  authority for the DMA packing format.
- `native/fabric/` — the Rust `fabric_port`; home for the batched-read op if you
  go that route (Tier 0 option 3a).
- `regmap.exs` in `ehdl/designs/libresdr_radio` — the register spec `top.ex`
  unpacks; source of truth for any new status/write-ptr register.

Reference docs (`~/src/nervezynq/`):
- `HPDMA_SESSION.md` — the proven DMA engine, hazards, next-steps ledger.
- `SDR_V1.md` — the V1 driver, the nibble_swap measurement, the next-in-order
  list (stream_rx is #2).
- `AGENTS.md` — board reach (usb0 `172.31.248.125`), deploy, the port rationale.

Host / consumer (`~/src/nervezynq/scope/`):
- `lib/nz_scope/link.ex` — TCP client, FFT, feeds canvases; where host-side
  `MIMO.decode` lands for option (b).
- `lib/nz_scope/canvas/waterfall.ex` — the GL waterfall (proven).
- `scope/README.md` — the transport protocol and run instructions.

---

## One honest framing for whoever picks this up

The snapshot path was never going to be a live scope — that ceiling is exactly
what V2 is for. But before you commit to the fabric rebuild, run Tier 0. The
readout, not the radio, is what makes V1 crawl, and there's a ~200× lever
sitting in `Fabric` that needs at most a Rust-port op and no bitstream. Get the
waterfall watchable cheaply, *then* build DMA for the gapless, beacon-depth
streaming that Tier 0 can't give you. The two are complementary, not either/or.
