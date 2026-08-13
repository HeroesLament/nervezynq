# AXI streaming path — plan of record (2026-08-02)

The transceiver needs sustained bidirectional I/Q at rates PIO cannot reach
(0.94 Mwords/s measured; ~16 Msps needed). The GP0 slave path is dead on
current firmware and unexplained. This plan does not wait for that fault:
the streaming architecture uses only paths that are either proven on this
board or structurally immune to the GP failure mode.

## Architecture: HP data plane, EMIO control plane, no GP anywhere

    AD9363 -> LVDS RX (proven) -> pack to 64-bit -> Hw.FIFO -> Hw.AXIHPWriter
        -> PS7 S_AXI_HP0 -> DDR ring buffer (reserved, non-cached)
        -> Elixir mmap + poll

    control:  Linux GPIO -> EMIO bank 2/3 -> enable / (config)
    status:   write_ptr bits, bursts, bresp_errs, LOCKED, heartbeat
              -> EMIO inputs -> Linux GPIO reads

Why this shape survives the GP fault:

- HP is the PL *mastering* into the PS. The lethal GP mode — a PS-initiated
  read into the PL that never answers, hanging the CPU unrecoverably —
  cannot occur; a broken PL master starves, it cannot wedge the ARM.
- The GPIO controller (0xE000A000) is a PS peripheral like SLCR and devcfg,
  both proven live on this board. EMIO is 64 wires into the fabric with no
  PL AXI interconnect at all. This is HANDOFF step 2, promoted from
  "next" to load-bearing.
- Nothing needs PL-to-PS interrupts: the ARM polls `write_ptr` (via EMIO or
  from the ring itself). Interrupts are an optimisation for later.

## What exists as of tonight (all in ehdl, all committed)

- `Hw.AXIHPWriter` — AXI3 write-burst engine for HP0. 16-beat INCR bursts,
  64-bit, ring addressing, one transaction outstanding (sized: ~2x margin
  over 16 Msps at 50% bus efficiency; single-outstanding keeps bring-up
  legible). **8/8 tests green** against a scripted ideal slave: burst
  shape, data order, WLAST, W-stall holds data, ring wrap, threshold and
  enable gating, SLVERR counted-not-fatal.
- `Hw.PS7HP` — PS7 wrapper adding S_AXI_HP0 (write side) and EMIO GPIO
  banks 2/3 to the `Hw.PS7` surface. Separate component so existing
  designs keep their PS7 untouched. Port widths taken from yosys
  cells_xtra.v (ID 6, LEN 4, AWSIZE 2, WSTRB 8, EMIO 64) — not from
  memory of the TRM. Exposes WACOUNT/WCOUNT for triage.
- `test/axi_hp_writer_test.exs` — the BFM testbench.

`Hw.AXI4Master` is superseded (AXI4-shaped at an AXI3 port, no WID, broken
FIFO count arithmetic) and instantiated by nothing; treat as deprecated.

## Two findings from building this, so they don't get rediscovered

1. **The EHDL simulator has never executed a memory write.** No previously
   simulated design writes a `memory` (the USB descriptor ROMs are
   init-only and lower to logic). `Hw.Sim.Eval` has no `MemWrite` clause;
   `_top_`'s retained-op path crashes on the op (FunctionClauseError,
   eval.ex). This is why `Hw.AXIHPWriter` is a memoryless engine with the
   FIFO composed in front, and it is why `Hw.FIFO` itself — and any capture
   buffer, and eventually any modelled-AD9363 sim — cannot be simulated
   today. **Filed as an EHDL work item**: exclude MemWrite from comb-op
   retention, apply writes two-phase at the edge, back contents with the
   ETS entry that `Hw.Sim.State` already creates per memory. Until then a
   structural test pins the engine memoryless.
2. `clock :aclk` without `freq:` elaborates fine and then kills every
   testbench in `Hw.Sim.Clock.init` (division by nil). `Hw.FIFO` and
   `Hw.AXI4Master` both carry bare clocks — they were never simulated
   either.

## Board bring-up sequence (one session, cheap gates first)

Gate 0 — desk: DONE 2026-08-02, and in the LIVE design rather than a
  separate bringup top (decision: one bitstream carries the radio AND the
  DMA path, so the RX chain stays testable in the same load).
  `designs/libresdr_radio/top.ex` now instantiates `Hw.PS7HP` +
  `Hw.AXIHPWriter` + a 64-bit pattern counter, EMIO: enable in on bit 0
  (gpiochip line 54); status word documented in top.ex (bursts, wptr,
  bresp_errs, WACOUNT/WCOUNT, and smoke-test bits 41..43 = 1,1,0).
  Routed on seeds 0 and 17 of the current netlist (the clock-router
  lottery struck first — 0..16 all failed on the documented
  data_clk/CLKINV_OUT signature — then relented). fasm_audit on the
  shipped seed-0 FASM: 28 tile types, 5439 features, 0 findings.
  Bitstream staged at taps/serve/hp_dma_s0.bin(.gz).

Gate 1 — PS-side state, READ-ONLY first (all from IEx over USB; every one
  of these is a register read, none can hang):
  - `PlLoad.pcfg_done?/0` gate as always; load via the bracketed loader.
  - SLCR 0xF8000900 LVL_SHFTR_EN == 0xF (known needed, known state).
  - FCLK0 gate open (0xF8000170) — the writer and both ACLKs run on it.
  - **DO NOT READ AFI0 (0xF800_8000) FROM LINUX. It hangs the CPU.**
    Measured 2026-08-02, first board session of this plan: bitstream
    loaded clean (pcfg_done true, 109 ms), then a single
    `PortWire.transact(afi, {:read32, 0x00})` against a fresh
    `PortWire.open(0xF8008000, 0x1000)` mapping killed the board dead —
    no oops, ping gone, power cycle required. Same signature as the PL
    aperture hang. SLCR (0xF800_0000) and devcfg (0xF800_7000) map and
    read fine through the identical mechanism, so this is specific to the
    AFI block, not to fabric_port. Mechanism unknown (secure-world gating
    and an ungated interconnect stall are both candidates); UG585 listing
    it as an ordinary PS register block is an assumption this board just
    falsified. If the AFI values are ever truly needed, the only
    remaining path is JTAG via a mem_ap target — one probe per power
    cycle, per the JTAG hazard notes. Until then: proceed on reset
    defaults (64-bit width IS the documented reset state of
    AFI_WRCHAN_CTRL) and let BRESP/WACOUNT tell us if that assumption is
    wrong — SLVERR is counted, not fatal, by design.
  - EMIO GPIO: banks 2/3 direction regs from Linux (gpiochip lines 54+);
    verify a heartbeat bit toggles. **This alone is a milestone**: first
    PS<->PL signalling on this board that does not involve the dead GP.

Gate 2 — memory: RESOLVED WITHOUT FIRMWARE WORK. The ring is the top 1 MB
  of the existing 4 MB DmaBuf reservation (base 0x3FF0_0000), so the first
  silicon session needs no device-tree change and no burn. Sharing rule:
  DmaBuf allocations (readback buffers, tens of KB) stay below the 3 MB
  mark; do not run a readback census concurrently with a DMA soak. A
  dedicated region comes back on the table only if the radio stream needs
  more than 1 MB of ring.

Gate 3 — first DMA: enable via EMIO with the counter producer.
  - Success: `bursts` climbing on EMIO, ring fills with the counter
    pattern, `write_ptr` wraps, pattern check in Elixir passes
    (consecutive 64-bit increments, no gaps, no repeats).
  - Failure triage, in order: bursts==0 & AWVALID stuck (WACOUNT==0) ->
    PS never accepted the address: AFI/clock/level-shifter problem.
    bursts>0 & wrong data -> ordering/packing. bresp_errs>0 -> address
    outside the reserved window or AFI width mismatch.
  - The engine cannot wedge the ARM; worst case is a stuck engine,
    observed comfortably from EMIO, cleared by disable+reset via EMIO.

Gate 4 — rate: producer at radio rate (16 Msps equivalent), measure
  sustained throughput vs `bursts` delta over wall-clock; confirm zero
  FIFO overruns once the real FIFO fronts the engine (overrun counting
  lives with the FIFO).

Then: swap the counter for the packed LVDS RX stream — that is the
"samples land in DDR" milestone the whole SDR plan runs through.

## Explicitly deferred

- TX direction (`Hw.AXIHPReader`) — same shape, opposite channels; after
  RX streams.
- PL->PS interrupts — polling is sufficient at these rates.
- GP0 fault root-cause — still worth finding (HANDOFF's surviving lead:
  kernel fpga_manager vs userspace loader), but nothing above waits on it.
- MemWrite in the EHDL simulator — unblocks simulating the FIFO'd
  composition and the eventual modelled-AD9363 testbench.
