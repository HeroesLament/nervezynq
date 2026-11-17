# STATE DUMP — HP0 DMA first silicon, and the FCLK throttle root cause

Session 2026-08-02, board `lottery-lab`, bitstream `hp_dma_s0.bin`
(libresdr_radio + HP0 DMA path, seed 0, fasm_audit clean). Everything below
is measured. Two power cycles were spent; both bought something.

## THE HEADLINE: the fabric was never broken. Its clock was stopped.

`SLCR FPGA0_THR_CNT (0xF800_0178)` and `FPGA1_THR_CNT (0xF800_0188)` both
read **1** on this firmware. With a throttle count of 1, FCLK0/FCLK1 are
effectively halted: the divisor registers read as perfectly configured
(100 MHz / 200 MHz), and the clock never runs.

The fix, measured live:

    SLCR.unlock()
    SLCR.write32(0x178, 0)     # FPGA0_THR_CNT
    SLCR.write32(0x188, 0)     # FPGA1_THR_CNT
    SLCR.lock()

Heartbeat frozen before, toggling after. Nothing else changed.

### What this retires, all at once

* **"Fabric AXI is dead" — CLOSED.** After the throttle release,
  `Fabric.read32(0x00)` returns `0x45484431` ("EHD1"). The GP0 path, the
  AXI-lite slave, the whole CTRL/STATUS + SPI + capture toolchain works on
  current firmware. (The guard needed `Fabric.authorise/0` first — the
  known Correction-4 staleness, unchanged.)
* **"The PL is configured but not running" (SILICON_MAP §20) — EXPLAINED.**
  GCAPTURE saw no dynamic state because no flip-flop anywhere had a clock.
  The GCAPTURE instrument itself may be fine; re-test it now that FFs run.
* **"AXI failure is firmware-level" — CONFIRMED, and located.** The old
  firmware presumably left THR_CNT at 0; whatever produced the current
  image (the network-dry era FSBL/boot chain) leaves 1 there. Open
  question: which component writes it (or fails to clear a non-zero reset
  state). The durable fix belongs in firmware boot — see next steps.
* The kernel `fpga_manager` lead is MOOT for the AXI fault (and note in
  passing: this kernel's fpga0 has NO `firmware` sysfs attribute — the
  AGENTS.md loading instructions describe an older kernel; PlLoad is the
  only loader on current firmware).

### How it was found, for the method ledger

The EMIO status word did it. Combinational bits (alive/one/zero) read
correctly while the heartbeat register bit never toggled across 360 ms —
"comb flows, FFs frozen" in one 32-bit read, with no CPU-hang risk. That
signature eliminated reset (alive bit IS fclk_reset0_n), eliminated GWE
(STAT register via PCAP readback = 0x46107FFC: EOS, GWE, GTS_CFG_B, GHIGH_B
all released), and left only the clock. The startup-clock-starvation
hypothesis (NOOP push through PCAP) was tested first and cleanly falsified
— the push was accepted, FFs stayed frozen.

## MILESTONE: HP0 DMA streams, gapless, zero errors

With the clock released and the engine enabled over EMIO (bank2 bit 0,
gpiochip line 54):

    bursts        12074 -> 51625 in 200 ms (16-bit counter, wrapping)
    bresp_errs    0
    ring readout  64 words at 0x3FF0_0000: consecutive 64-bit integers,
                  deltas uniformly +1, after ~54k bursts and multiple
                  1 MB ring wraps

First PL-mastered DMA into DDR on this board, no vendor tools anywhere in
the chain: EHDL -> openXC7 -> PCAP load -> EMIO enable -> HP0 bursts ->
mmap readout. AFI reset defaults were correct (BRESP clean, 64-bit width).

The WACOUNT/WCOUNT anomaly resolved itself: they read garbage while the HP
interface clock (our SAXIHP0ACLK = axi_clk) was throttled, and read 0/0 at
idle once it ran. Instrument note: those PS7 counters are only meaningful
when the ACLK they're synchronised to is alive.

## NEW HAZARD, written in blood (one power cycle)

**Reading AFI0 (0xF800_8000) from Linux hangs the CPU** — same
no-oops-no-recovery signature as the PL-aperture hang. One `read32` of
offset 0 through a fresh `PortWire.open(0xF8008000, 0x1000)` killed the
board with the PL freshly configured and level shifters up. SLCR and
devcfg read fine through the identical mechanism. Do not map AFI from
Linux again; JTAG mem_ap is the only remaining route if AFI values are
ever needed (they were not needed tonight — BRESP=OKAY proves the
defaults).

## Also proven tonight

* GPIO controller (0xE000A000) maps and reads safely from Linux (zynq-gpio
  driver keeps it clocked). EMIO smoke bits (1,1,0) validate the read path
  before any conclusion rides on the other fields.
* EMIO as control plane: DIRM_2/OEN_2 + MASK_DATA_2_LSW writes drive
  fabric enable; full loop closed.
* The DmaBuf-tail ring placement (0x3FF0_0000, top 1 MB of the existing
  reservation) worked with zero firmware changes.

## Next, in the order I would do it

1. **Make the throttle release durable.** Two candidate homes: Nervezynq
   boot (application.ex writes THR_CNT=0 once SLCR is up) and
   `PlLoad.preflight/load` (gate + fix, so the instrument self-heals on
   any firmware). Also add `fclk_throttle` to preflight's report so a
   regression is visible in one read. Until then: the two SLCR writes are
   part of the boot ritual, like Devcfg/DmaBuf start_link.
2. **Find what sets THR_CNT=1.** Diff the boot chain against the pre-dry
   image's (FSBL/ps7_init/U-Boot). Knowing the writer says whether other
   SLCR state is also wrong.
   *Update 2026-09-28:* `ps7_init` is now source
   (`nerves_system_libresdr/uboot/patches/0002`, identical to the tables the
   2026-07-28 SPL ran). It writes only `FPGA0_CLK_CTRL` / `FPGA1_CLK_CTRL`
   (`0xF8000170`, `0xF8000180`) and never a `FPGA*_THR_CNT` register
   (`0xF8000178`, `0xF8000188`, ...), so the writer is not `ps7_init`.
3. **Re-run the radio bring-up on current firmware.** GP0 works now: SPI,
   AD9363 init, capture buffer — the whole RX chain is unblocked without
   any firmware rebuild.
4. **Re-test GCAPTURE** with running FFs. If it captures now, the readback
   beacon idea (SILICON_MAP §20) comes back as a free dynamic oracle.
5. **Rate test the DMA** (Gate 4): radio-rate producer, sustained MB/s vs
   bursts-over-wallclock, then swap the counter for packed LVDS samples —
   that is "samples land in DDR", the milestone the SDR plan runs through.
6. The AXI-lite `write_ptr`/config registers become available again now
   that GP works — the EMIO-only constraint on the DMA design can relax
   in the next revision (keep EMIO as the fallback instrument; it just
   proved its worth).
