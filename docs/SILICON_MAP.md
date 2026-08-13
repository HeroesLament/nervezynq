# What we know about this silicon, and what we don't

Scope: the LibreSDR receive path on xc7z020clg400-1 under openXC7 —
LVDS pad → IOB33 → IOI3 → interconnect → CLB → BRAM → AXI → PS7 — plus
everything that clocks it.

Status codes:

    OK     measured working on THIS board
    BAD    measured NOT working on this board
    UNV    documented in prjxray AND emitted by nextpnr, but NEVER tested on
           silicon. This is the dangerous column: it has been wrong three times.
    DARK   undocumented in prjxray, or documented but never emitted

---

## 1. IOB33 — the pads

    OK    IBUFDS, IOSTANDARD LVDS_25, differential input        16 MHz proven
    OK    LVCMOS25 single-ended in/out (SPI, control)
    UNV   HCLK_IOI3.LVDS_25_IN_USE / ONLY_DIFF_IN_USE / STEPDOWN / VREF
    DARK  DIFF_TERM / on-die 100 ohm differential termination

`DIFF_TERM` is set on every IBUFDS in the design and nextpnr silently ignores
it: no termination feature appears anywhere in the emitted FASM, and prjxray
documents only `IN_DIFF` for RIOB33. The board carries no external termination
either. **We are running unterminated LVDS and have never measured the cost.**
At 16 MHz it evidently does not matter — the tap sweep is clean at every tap —
but this is an unmeasured risk that grows with data rate.

## 2. IOI3 — IDELAYE2

    OK    IDELAY_TYPE FIXED, DELAY_SRC IDATAIN, IDELAY_VALUE 0..28
    OK    Sweeping the tap does not perturb the decode (8 taps x 2 seeds)
    UNV   IDELAY_TYPE VARIABLE and VAR_LOAD (runtime tap control)
    UNV   DELAY_SRC DATAIN, PIPE_SEL, HIGH_PERFORMANCE_MODE, CINVCTRL_SEL
    UNV   IS_DATAIN_INVERTED, IS_IDATAIN_INVERTED
    DARK  Absolute picoseconds per tap

21 of 21 emittable features resolve in segbits. Only FIXED has been exercised.
Runtime-variable taps would remove the one-bitstream-per-tap cost entirely and
are the single highest-value untested feature here.

## 3. IOI3 — ILOGICE3 (the IFF / IDDR / ISERDESE2 site)

    BAD   IDDR   measured giving rise != fall on a STATIC input, which no DC
                 level can produce. But see the caveat below.
    UNV   ISERDESE2 via IOBDELAY="IFD" — builds clean end to end, never run
    BAD   ISERDESE2 via direct D — nextpnr cannot route the site arc, any seed
    DARK  9 of 14 site pips: IMUX, IFFMUX, D2OBYP_SEL, D2OFFBYP_SEL,
          ZHOLD_FABRIC_INV, ZHOLD_IFF_INV, CE1USED, SRUSED, REVUSED
    DARK  IFF.INV_OCLK, ISERDES.DYN_CLK_INV_EN, ISERDES.DYN_CLKDIV_INV_EN
          (documented, nextpnr never emits them — DYNCLKSEL/DYNCLKDIVSEL dead)

**The IDDR verdict needs reopening.** That measurement was taken when the
AD9363 was not driving the lanes at all — the captured word was a constant
`0x659`, the undriven bias state — and before the RF PLL was brought up. The
inference (rise != fall on a DC input is impossible if correctly connected) is
sound in isolation, but it was made with a broken instrument against a dead
signal, and it predates everything we now know. **Retest is cheap and the
oracle is now trustworthy.** Nothing depends on the answer — the design uses
fabric flops — but "IDDR is broken" should not be carried forward as settled.

The undocumented site pips cost us the ZHOLD auto-delay path, the combinational
O bypass, and the tristate bypass. None is needed for an LVDS receiver.

### A real defect, found while writing this and NOT previously recorded

The IFF's data input comes from `IFFMUX_OUT <- IFFDELMUXE3_OUT`, and
`IFFDELMUXE3` selects between `DDLY` (delayed), `DINV_OUT` (direct) and
`ZHOLD_IFF_INV_OUT`. `IDELMUXE3` is a *different* mux that feeds only the
combinational `O` output through `IMUX`.

nextpnr's `ILOGICE3_IFF` branch writes **IDELMUXE3** — choosing P0 when an
IDELAYE2 drives D, P1 otherwise — and **never writes IFFDELMUXE3 at all**
(verified: zero occurrences in that branch).

For a plain IDDR this is harmless: zynq7 documents `IFFDELMUXE3.P0 = 28_116`,
virtex7 documents `IFFDELMUXE3.P1 = !28_116`, so the unwritten default is P1 =
`DINV_OUT` = direct, which is correct. (This is why the "unprogrammed IFF mux"
theory for the IDDR failure is WRONG — checked before reporting.)

But for **IDDR fed by an IDELAYE2** it is a silent correctness bug: nextpnr sets
`IDELMUXE3.P0` (routing the delayed signal to the unused `O` output) while
`IFFDELMUXE3` stays clear, so the flip-flop samples the **undelayed** signal.
The delay is configured, consumes a site, and does nothing.

Consequence worth noting: had the eye scan been built on IDDR instead of fabric
flops, it would have produced a flat, fully-open eye at every tap — the same
observed result, for an entirely different and wrong reason.

## 4. HCLK_IOI3

    OK    IDELAYCTRL — RDY asserts and holds, with RST tied low or pulsed
    OK    IDELAYCTRL REFCLK routed from a leaf GCLK
    UNV   BUFR (BUFR_DIVIDE BYPASS/D1..D8) and BUFIO — documented, never tried

BUFR/BUFIO matter: a real ISERDES design takes CLK from BUFIO and CLKDIV from
BUFR. Our ISERDES probe cheated by driving both from a BUFG, which is
structurally valid for a build test and useless at speed.

## 5. Clock distribution

    OK    BUFG                                   proven, clocks everything
    OK    Leaf GCLK into HCLK_IOI3               proven by IDELAYCTRL RDY
    OK    CCIO from a clock-capable pin (N20)    route emitted; see caveat

    OK    BUFHCE actually delivering a clock       proven 2026-07-31

BUFHCE is now proven. The CMT lock experiment below drove CLKIN1 through
BUFG -> GCLK -> BUFHCE -> HCLK_CMT, and once the CMT came out of reset it
locked and produced a correctly multiplied output clock on that exact path.
BUFH was never broken; it was only ever under suspicion because it happened to
be in the path of a failure that had nothing to do with it.

## 6. CMT — PLLE2_ADV / MMCME2_ADV

    OK    MMCME2_ADV locks and multiplies         proven 2026-07-31
    OK    CLKIN1 via BUFG -> BUFHCE -> HCLK_CMT   same experiment
    UNV   PLLE2_ADV                               same root cause, same fix,
                                                  not yet re-measured

SOLVED. The cause was not in the silicon and not in prjxray. It was six lines
in nextpnr-xilinx's FASM backend writing `ZINV_RST` and `ZINV_PWRDWN` with
inverted polarity, so every CMT this project ever built was **held in reset by
its own bitstream**.

`ZINV_*` is prjxray's Z-inverted encoding: the bit is SET when the pin is NOT
inverted. `xilinx/fasm.cc` already writes `!IS_x_INVERTED` everywhere else —
ILOGIC/OLOGIC `ZINV_D`, `IFF.ZINV_C`, `IFF.ZINV_OCLK`, `ZINV_T1`,
`ZINV_ODATAIN`, BUFGCTRL `ZINV_CE0/CE1/S0/S1`, BUFHCE `ZINV_CE`, the whole RAMB
`ZINV_` loop. `write_pll()` and `write_mmcm()` were the only two functions that
wrote it un-negated, under a comment that said so:

    // FIXME: should be INV not ZINV (XRay error?)

It was not an XRay error. With RST tied low and not inverted, the un-negated
form leaves the bit clear, which inverts RST, so the CMT sees RST asserted for
ever and LOCKED can never rise. `INV_CLKINSEL` on the next line is genuinely
INV-encoded (note the name) and was always correct — getting the INV-named bit
right while getting the ZINV-named ones wrong is presumably what produced the
FIXME.

Measured, paired A/B against the SAME routed design, the two bits appended to
an already-routed `.fasm` so control and candidate differ by exactly `28_111`
and `29_111`:

    control (as routed)     LOCKED 0    CLKOUT0     0 ticks     0.000 MHz
    + ZINV_RST/ZINV_PWRDWN  LOCKED 1    CLKOUT0 19784 ticks    99.919 MHz

Then end-to-end through the patched nextpnr on a different seed, which also
exercises the predicted swap in the emitted FASM (`ZINV_PSEN`/`ZINV_PSINCDEC`
out, `ZINV_RST`/`ZINV_PWRDWN` in):

    seed 3, full flow        LOCKED 1    CLKOUT0 19784 ticks    99.986 MHz

99.9 MHz is `CLKFBOUT_MULT_F=10 / CLKOUT0_DIVIDE_F=5` on the input clock, so
the CMT is genuinely multiplying — not merely reporting a lock bit. Both control
and candidate had a live heartbeat and completed AD9363 bring-up, so the fabric
was equally alive in each.

### What this retires

  - The plan to search 2,614 undocumented bits in minors 28-29 of
    `CMT_TOP_L_LOWER_B_X178Y61` with LOCKED as a binary oracle. There was
    never a documentation gap here. prjxray had the bit; the emitter wrote
    it backwards.
  - "Everything hard-block and analogue is dead." Nothing was dead. IDELAYE2,
    IDELAYCTRL and now the CMT all work.
  - BUFHCE as a suspect (see section 5).

### What it should change about how we look

Three of the defects found in this project so far — ISERDES OFB/OCLK tie-offs,
`ILOGICE3_IFF` writing the wrong input mux, and now this — are the emitter
writing a bit prjxray had already characterised. None of the three was a gap in
the database. Before treating a silent hard block as undocumented silicon, diff
what the design's FASM emits against the full documented feature list for that
tile type; that is how this one was found, in one pass, after ~15 bitstreams of
searching in the wrong place. `scripts/frames_poke.exs` remains the tool for
genuinely undocumented bits, but it turned out not to be needed here.

## 7. CLB fabric

    OK    LUT, FF, MUXF7/F8, distributed logic
    BAD   Nets into SLICE clock-enable pins. Measured on a 252-FF reproducer at
          0.24% device occupancy: distinct SR nets route 3/3 at 1, 2 and 4 nets;
          CE nets route 2/3, 1/3, 0/3. Every failure is
          "Failed to route arc ... CEUSEDMUX_OUT".
    DARK  The mechanism. Three theories falsified (FAN_ALT/FAN_BOUNCE
          contention, pip blacklisting, placement legality).

Worked around with yosys `dffunmap`, which pushes the enable out of the FF into
D-side logic. Took the routing success rate from 1-in-1600 seeds to 1-in-17.

## 8. BRAM

    OK    RAMB36E1, 4096 x 26 as four banked 1024-deep blocks
    BAD   x9 width mode: the 9th bit lands on the parity port, and openXC7's
          site map sends DOPBDOP0 to the LOWER half only, so that bit is correct
          on even addresses and zero on odd. Guarded locally in fasm.cc — the
          build now hard-errors instead of emitting a corrupt bitstream.
    UNV   Cascade, true dual-port, FIFO modes

## 9. PS7 and the PS clocking

    OK    AXI4-Lite GP0, PCAP configuration, FCLK0 = 99.99 MHz
    OK    FCLK1 = 199.97 MHz in fabric (FSBL already sets IO PLL/5)
    OK    SLCR read via mmap
    UNV   SLCR write (calibration passed; no write was ever needed)
    UNV   AXI HP ports — the DMA path, and the next real milestone
    UNV   PL-to-PS interrupts

    Board facts: PS_CLK is 50 MHz (NOT the usual 33.333; it is in no register
    and must be derived). IO PLL 999.9 MHz. FPGA1_CLK_CTRL is 0x180.

---

## 10. What a whole-design audit now says

`ehdl/scripts/fasm_audit.exs` diffs a design's emitted FASM against prjxray's
complete documented feature set, for every tile type the design touches. It is
the automated form of the hand-diff that found the CMT defect.

    libresdr_radio_s4  (current head)   27 tile types, 5392 features   0 findings
    libresdr_radio_s3  (post-fix MMCM)  28 tile types, 5368 features   0 findings
    mmcm_b             (pre-fix MMCM)   29 tile types, 5385 features   1 finding

One real defect, no noise. Run it before any hardware search.

Two things learned while getting the false-positive rate to zero, both of which
are facts about the stack worth having written down:

### SING tiles are aliased, not undocumented

`RIOB33_SING` and `RIOI3_SING` have NO segbits file in zynq7 -- nor in artix7,
kintex7 or spartan7. That looks like a family-wide dark region and is not one.
`tilegrid.json` gives them an `alias`:

    "alias": {"type": "RIOB33", "sites": {"IOB33_Y0": "IOB33_Y1"}}

Their bits live in their own frames but are NAMED by the aliased type, and
`fasm2frames` honours it. Verified by reading the frames rather than the names:
`RIOB33_SING_X73Y99` carries 15 set bits in a real build. R19
(`ad9363_spi_do`, the SPI read path) sits in that tile and SPI reads work.

Anything walking the database by tile type must follow the alias or it will
invent a structural gap where there is none.

### Absent ZINV on an unused control pin is correct, not a bug

`pack.cc:674`: an invertible pin tied to 0 is optimised into a connection to
VCC plus an inversion, because VCC is easier to route. That sets
`IS_x_INVERTED`, which correctly suppresses `ZINV_x`. The bit being absent IS
the pin working.

This is why BRAM `ZINV_RSTRAM*`/`ZINV_RSTREG*`, BUFGCTRL `ZINV_CE1`/`ZINV_S1`
and post-fix MMCM `ZINV_PSEN`/`ZINV_PSINCDEC` are all absent and all fine. A
second mechanism in `fasm.cc` skips the output register's clock/reset ZINVs
when `DOA_REG`/`DOB_REG` is absent, attributed to a dcp2fasm campaign against
Vivado goldens.

Note what this does NOT do to the CMT finding. Under the OLD code both cases
were broken: with RST driven by a real zero net, `ZINV_RST` was omitted and the
pin was inverted; with RST left unconnected, the tie idiom set
`IS_RST_INVERTED=1` so the old code EMITTED `ZINV_RST`, bypassing the inverter
so the pin saw VCC. Reset asserted either way. openXC7's CMT could not have
worked for anyone, which is consistent with the FIXME its author left.

---

## 11. Coverage: what we have never touched

`ehdl/scripts/fasm_coverage.exs`, unioned over 17 builds. 7367 of 13475
documented features have ever been emitted (55%).

    INT_L               92%   3331 / 3636      CLK_BUFG_REBUF       9%    12 /  128
    INT_R               90%   3268 / 3636      RIOI3_TBYTETERM      5%    18 /  352
    BRAM_L              56%    246 /  440      HCLK_R               4%     8 /  200
    CLBLM_R             48%     96 /  199      HCLK_IOI3            4%     9 /  252
    CMT_TOP_L_LOWER_B   47%     67 /  142      RIOI3_TBYTESRC       3%    12 /  354
    CLBLM_L             45%     90 /  199      CLK_HROW_TOP_R       2%    42 / 2134
    CLBLL_L             25%     44 /  176      HCLK_CMT_L           2%    11 /  660
    CLK_BUFG_TOP_R      16%     54 /  336      HCLK_L               2%     3 /  196
    RIOB33              13%     11 /   83
    RIOI3               13%     45 /  352

A low number is not a defect. Most of a tile type's feature space is modes we
have no use for -- every IOSTANDARD we do not drive, every SERDES width we do
not instantiate. This is a risk register, not a scorecard: it says where, if we
later need something, there is no evidence it works.

**The clock network is the darkest region we actually depend on.**
`CLK_HROW_TOP_R` is 2% of 2134 features; `HCLK_CMT_L` 2% of 660; `HCLK_L`,
`HCLK_R` and `HCLK_IOI3` all under 5%. Roughly 3300 documented clocking
features have never been emitted once.

That is exactly the region where this project has just been wrong twice. BUFH
sat under suspicion for weeks over a fault that turned out to be the CMT's
reset bit, and the CMT itself was written off as dead silicon. Both were
misattributions INTO the least-exercised part of the chip -- which is what you
would predict, because that is where we have the least ability to tell a real
failure from a wrong guess.

Next targets follow from the table rather than from intuition: BUFH/BUFR
delivering a measured clock, HCLK_IOI3 leaf distribution beyond the single
IDELAYCTRL path, and the BUFG_REBUF / HROW muxes.

---

## 12. The seed lottery, measured

60 seeds, one netlist, every routed bitstream tested on the board.

    routed              23 / 60   38%
    routed AND decodes  20 / 23   87%
    end-to-end          20 / 60   33%

### Hazard 2 needs rewriting

"~50% of routed bitstreams are functionally broken" has been quoted throughout
this project as the dominant tax. **It is 13%, not 50%.** The old figure was
measured while elaboration was nondeterministic -- rebuilding "the same" seed
silently produced a different netlist -- so it was counting build variance as
functional failure. Two of this project's conclusions rested on that number.

### The route failure has one address

All 37 route failures are the same failure:

    net          data_clk                       37 / 37
    source       BUFGCTRL_X0Y17/O               37 / 37
    destination  SITEWIRE/SLICE_*/CLKINV_OUT    37 / 37

Zero scatter in kind. The sink SLICE varies within X 26..37, Y 91..119.

### And a perfect predictor, which is the mechanism

nextpnr's dedicated clock router prints one line per sink it abandons. Over
60 seeds, no exceptions:

    give-ups == 0  ->  routed 23, failed  0
    give-ups >= 1  ->  routed  0, failed 37

**The defect is in the dedicated clock router, not router2.** Every earlier
framing -- "SLICE CE routing defect", "router2 congestion" -- named the wrong
stage. router2 is only where the corpse turns up: the clock router punts a sink
it could not place, and a SLICE clock pin is essentially unreachable through
general interconnect.

`xilinx/arch.cc:1840` routes each sink by a backward BFS that stops at the
first wire already bound to the net, walking dedicated clock intents only. That
is greedy, order-dependent and has no backtracking -- an early sink can claim a
resource a later sink needed. The lenient fallback beneath it covers only
PLL/MMCM CLKIN1 and BUFG inputs, so a SLICE sink that loses the race has
nowhere to go. That predicts the observed shape exactly.

This is the last big unexplained tax on the project and it now has a specific
line number. Fix direction: order sinks deterministically by difficulty or
geometry, or give SLICE sinks the same fallback the PLL inputs get.

### Still unexplained: 3 of 23

The three routed-but-dead builds are not one mode -- mean magnitude 0.0, 1.4
and 551.8. Seed 34 captures real data and will not decode. Fmax does not
separate them (seed 9 works at 265.67 MHz, seed 17 is dead at the same
265.67 MHz). A FASM differential over 20 good and 3 bad found 12 shared routing
pips, which at n=3 is not evidence. Needs a wider sweep for more bad samples.

---

## The cross-cutting hazards

**1. openXC7 has no DRC.** Vivado refuses an IDELAYE2 with no IDELAYCTRL.
openXC7 builds it, emits a complete and entirely correct FASM, produces a
loadable bitstream — and every delayed lane reads zero forever. Nothing in the
stack models inter-primitive requirements. This is the single largest practical
risk, because the failure is silent and looks like broken hardware.

**2. "Routed" does not mean "works".** (Rate corrected: 13%, not 50% -- see
section 12. The 50% figure was an artefact of nondeterministic elaboration.) Seed 6 of the IDELAYCTRL build routed,
loaded, showed correct magic, a running heartbeat and RDY = 1, and returned
AD9363 product ID 0x01 instead of 0x0A. Seeds 8, 11, 16 and 18 all returned
0x0A. **Any result needs a second seed before it means anything, including a
negative one.** A bad seed has twice been mistaken for a hardware failure.

**3. Documented + emitted + resolves is not evidence of function.** It has been
wrong for the BRAM parity port and for IDELAYE2 without its controller. Only
the board is evidence.

**3b. And the converse: NOT emitted is not evidence of undocumented.** The CMT
looked for weeks like undocumented silicon. It was a documented bit the emitter
wrote backwards. Three of this project's defects now have that shape — ISERDES
OFB/OCLK tie-offs, `ILOGICE3_IFF`'s input mux, and CMT `ZINV_RST`. Before
concluding a hard block is undocumented, diff the design's emitted FASM against
the complete documented feature list for that tile type. It is one pass over two
files and it would have saved ~15 bitstreams here.

**4. Instruments need a known answer before they are trusted.** Three separate
harness bugs each produced a confident, wrong, plausible-looking result:
`bist_tone/4` returning `{:ok, 11}` faked a uniformly closed eye; a 300 ms
window on a 24-bit counter faked a 44 MHz clock; and `frame_integrity/1` — which
reads 0.25 on captures that decode perfectly — declared a fully open eye closed
at all eight taps. In each case what caught it was a control point whose answer
was already known.

## 13. PCAP frame readback — what has been ruled out

Register readback works and is trustworthy: `IDCODE` reads back `0x23727093`,
correct for the 7z020. So devcfg register access, the 4 MB reserved DMA buffer,
physical addressing, the `0xFFFF_FFFF` (`XDCFG_DMA_INVALID_ADDRESS`) sentinel
and the two-phase transfer shape are all sound. Every remaining failure is in
the FRAME command sequence, not the plumbing.

Frame readback at `FAR=0x900` asking the fabric for 202 words returned exactly
101 words of zeros and then stalled. 101 is the 7-series frame length, so the
fabric emitted precisely one frame and stopped, regardless of the count it was
asked for.

### Ruled out, with the evidence

| Hypothesis | Verdict | Evidence |
|---|---|---|
| `QUARTER_PCAP_RATE_EN` (CTRL[25]) must be set for readback | **No** | `XDcfg_Transfer` sets it only for `XDCFG_SECURE_PCAP_WRITE` (the AES engine takes 8 bits/clock) and explicitly *clears* it for non-secure writes. The `XDCFG_PCAP_READBACK` path never touches it. |
| The receive DMA must be armed concurrently with the command send | **No** | `XDcfg_PcapReadback` sends the command, spins on `D_P_DONE`, and only *then* calls `XDcfg_InitiateDma` for the read. Serial is Xilinx's own order. |
| Internal PCAP loopback (`MCTRL[4]`, `PCAP_LPBK`) was left on | **No** | Read directly off the board: `MCTRL = 0x30800100`, bit 4 clear. Worth clearing defensively anyway, as the driver does, but it was never the cause. |

Two of the three were settled by reading Xilinx's driver rather than by
spending a power cycle, and the third by a register read on an already-wedged
board. Wedges cost a power cycle each; hypotheses that can be killed from
source or from a read-only probe must be killed there first.

### The remaining suspect

The failing attempts encoded the FDRO read as a type-1 packet with an INLINE
word count. UG470's readback sequence is a type-1 read of FDRO with count **0**
followed by a **type-2** packet carrying the real count — which is what
`Readback.arm_sequence/2` implements and what the hand-written experiments
bypassed. `scripts/rb_probe.exs` tests exactly that one variable.

### Wedge state, for recognising it later

A stalled readback leaves the devcfg DMA command queue full and nothing short
of a power cycle clears it. Observed signature:

    ctrl        = 0x4E00E07F
    status      = 0x90600F30      <- DMA_Q_F set, DMA_Q_E clear
    dma_src     = 0x3FC00000
    dma_dst     = 0xFFFFFFFF
    dma_src_len = 0x6             <- the DESYNC cleanup, queued and never run
    dma_dst_len = 0x0

The second queue slot is occupied by the cleanup command that was issued
*after* the stall. That is why `rb_probe.exs` gates its DESYNC on
`queue_idle?/0`: queueing behind a stalled transfer is what converts a
recoverable stall into a hard wedge.

### The chunked-walk discipline

A receive DMA that asks for more words than the fabric emits never completes.
So the read is now split into 101-word transfers issued one at a time, each
awaited before the next is risked. Every frame that arrives is banked. This
turns "one power cycle per attempt" into "one power cycle per *wrong
hypothesis*", and it also measures exactly how many words the fabric is willing
to emit — which is the number the whole problem hinges on.

## 14. PCAP frame readback WORKS — the undocumented mechanism

**The configuration engine only emits readback data while the PCAP interface
is being clocked.** Nothing in UG470, UG585 or Xilinx's `xdevcfg` driver says
this, because the driver's only readback example reads a single register word,
where the command packet itself supplies more than enough clocks to cover it.

Frame data is 101 words per frame on the 7z020, and a two-frame read needs
hundreds of clocks after the command has been consumed. When the command
transfer ends, the clocking ends, and the engine simply stops mid-stream. The
receive DMA then waits for ever for words that will never come, and that is
what every "wedge" in this project actually was.

### Evidence

A readback at `FAR=0x900` asking for 202 words returned exactly 101 words (the
pad frame) and stalled. With the receive DMA still outstanding and one queue
slot free, 256 NOOP words were pushed as a *separate* transmit transfer. The
engine immediately resumed streaming into the still-armed receive buffer:

    frame 0x900 = 20800 0 20800 0 20800 0 20800 0 20800 0 6020800 0 ...

which is what `base.frames` holds for that address. 55 nonzero words in the
frame. This is real configuration memory read off the silicon.

### Two consequences

1. **A stalled readback is starved, not dead.** As long as only one queue slot
   is occupied, pushing NOOPs restarts the stream and the pending receive
   completes. Most of the power cycles this project spent were avoidable.

2. **The clock budget must be sized up front.** 56 command words produced 101
   output words; a further 256 NOOPs produced 88 more. So roughly **0.6 output
   words per transmitted word** — call it 2 transmitted words per word wanted,
   with margin. The queue is only 2 deep, so the transmit that supplies the
   clocks must be queued *behind the already-armed receive*, and it has to be
   big enough on the first try.

### The working shape

    1. TX  command sequence           (preamble, RCRC, FAR, RCFG,
                                       type-1 FDRO read count 0, type-2 count N)
       wait D_P_DONE
    2. RX  N words                    <- armed, will stall part-way
    3. TX  ~2N + margin NOOP words    <- supplies the clocks that drain it

Steps 2 and 3 occupy both queue slots simultaneously. That is not a hack around
the hardware; it is what the hardware requires, and it is the piece that was
missing for the whole of this effort.

## 15. Readback validated against the oracle — and the one legitimate difference

With the clock budget sized correctly, `FAR=0x900` reads back **202/202 words,
queue idle afterwards, first time, no power cycle**. Then eleven frames
(1111 words) in one transfer, likewise complete.

Compared word for word against `base.frames`, all ten real frames differ in
**exactly one word each: word 50, and only in bits [12:0]**.

    FAR     base word 50   silicon word 50   delta
    0x900   0x00600000     0x00600E12        0x0E12
    0x901   0x00000000     0x00000E0F        0x0E0F
    0x902   0x00000000     0x000001E5        0x01E5
    0x903   0x00000000     0x00000062        0x0062
    0x904   0x00200000     0x00201D84        0x1D84
    0x905   0x00000000     0x0000143E        0x143E
    0x906   0x00000000     0x000004D8        0x04D8
    0x907   0x00000000     0x00001760        0x1760
    0x908   0x00000000     0x000007F8        0x07F8
    0x909   0x00000000     0x00001122        0x1122

Every delta is 13 bits wide, in the same word, in every frame, and nowhere
else. That is the **7-series per-frame ECC**: the device computes a Hamming
code over each frame and reports it on readback. openXC7 writes zeros there;
Vivado fills it in only when asked to.

So it is not a discrepancy, and it is not silicon telling us anything. But left
unmasked it makes every frame differ, which would render the whole comparison
useless in exactly the way an unmasked flip-flop would. `Mask.strip_ecc/1`
zeroes word 50 bits [12:0] unconditionally, separately from the per-tile-type
`mask_*.db` handling.

**Everything else is bit-exact.** 1010 words of configuration memory read off
the silicon, matching what the flow intended to load, on a board with no
Vivado anywhere near it.

### A retracted finding

An earlier partial read showed what looked like a one-word insertion at index
16, which would have meant the fabric disagreeing with the bitstream. It was an
artifact: that read had stalled and been resumed by hand with a second NOOP
transfer, and 16 words is 64 bytes -- one AXI burst. The clean single-shot read
shows no such shift. Worth recording because the wrong version was nearly
written down as silicon behaviour.

## 16. The write path — three defects, and the bitstream as oracle

`:census` writes 1 to every candidate bit and reads back. First run: **3,136
candidates, 0 read back as 1.** Taken at face value that says the entire CMT
dark space is unbacked silicon, which would have been a spectacular finding and
was entirely an instrument failure.

What saved it was an accident. `/root/documented_bits.term` was missing, so
`undocumented_bits/2` fell back to the whole 3,136-position space instead of
the 2,614 undocumented ones -- which meant the 522 DOCUMENTED bits were in the
candidate set too. Those are known-real cells. Zero of them reading back 1 is
not a result, it is a broken experiment. **Keep known-positive controls in the
candidate set on purpose.**

### The three defects

Guessing was replaced with reading a real bitstream. `tier1_s3.bin` was parsed
packet by packet and compared against `Readback.write_sequence/2`:

    T1 op=2 CMD     0x0(NULL)        <- missing
    T1 op=2 CMD     0x7(RCRC)
    T1 op=2 IDCODE  0x3727093        <- missing
    T1 op=2 FAR     ...
    T1 op=2 CMD     0x1(WCFG)
    T1 op=2 FDRI    cnt=0
    T2 op=2 cnt=1010808
    T1 op=2 CMD     0x7(RCRC)        <- missing
    T1 op=2 CMD     0xa(GRESTORE)    <- missing
    T1 op=2 CMD     0x3(LFRM)        <- missing
    T1 op=2 CMD     0x5(START)

1. **No trailing pad frame.** The engine writes frame data through a pipeline
   one frame deep: the words for frame k do not commit until the words for
   frame k+1 arrive. Every census candidate lives in minor 28 or 29 -- the last
   two frames of the tile -- which are exactly the frames a missing pad frame
   discards. `Readback.write_payload/1` now appends one.

2. **No `IDCODE` write.** 7-series compares the written IDCODE against the
   device before accepting frame writes. Omitting it is not "no check"; it is a
   check against whatever the register happens to hold.

3. **No `LFRM`.** "Last frame" is the documented flush for that same pipeline.
   A real bitstream sends both LFRM and a pad frame, plus `RCRC` and `GRESTORE`
   before `START`.

After the fixes: **3,136 / 3,136** bits written and read back as 1, and
`:selfcheck` correctly flipped to `:fail` with 98 differing words (49 words x 2
minors) because the tile really had changed. Reloading the bitstream restored
it and `:selfcheck` returned to `:pass`. Write, detect, restore, verify --
the instrument is complete and reversible.

## 17. The census result: the dark space is NOT dark

**All 3,136 addressable bit positions in CMT minors 28 and 29 are backed by
real, writable configuration storage.** Nothing was pruned, because there was
nothing to prune.

This kills the cheap path. The hope behind `:census` was that most of the 2,614
undocumented positions would turn out to be unimplemented and could be
dismissed in one write/read pair. They are all implemented. Configuration
memory is fully populated; whether a cell *does* anything is a functional
question, and a functional question cannot be answered by asking storage.

So the remaining route is `:functional` -- one bit at a time, O(n), poke, load,
run the oracle, record, restore. That is the expensive answer, and it is now
the only honest one. It is also exactly what `SiliconSweep.GroupTesting`'s
refusal note predicted: there is no monotone oracle here to pool against.

A negative result, established with a positive control, that closes off a
shortcut which would otherwise have been retried indefinitely.

## 18. The CMT fix, confirmed on silicon, at bit level

The `fix/cmt-zinv-polarity` patch to nextpnr-xilinx was justified by reasoning
about ZINV encoding and validated by the MMCM locking. It has now been confirmed
**directly in the configuration memory of the running device**, read back
vendor-free over PCAP.

### Method

`mmcm_b` is the pre-fix build (CMT did not lock). `mmcm_zinv` is the same design
after the patch (CMT locks). Both were loaded in turn and minors 28 and 29 of
`CMT_TOP_L_LOWER_B_X178Y61` (`0x00402400`) were read back and compared word by
word.

### Result

    minor 28, word 3   0x00004000 -> 0x0000C000     bit 111
    minor 29, word 3   0x00004000 -> 0x0000C000     bit 111
    minor 28, word 50  ECC only, device-computed
    minor 29, word 50  ECC only, device-computed

**Two bits. Nothing else in either frame differs.** Named from
`segbits_cmt_top_l_lower_b.db`:

    CMT_TOP_L_LOWER_B.MMCME2_ADV.ZINV_PWRDWN   28_111
    CMT_TOP_L_LOWER_B.MMCME2_ADV.ZINV_RST      29_111

Both go from clear to SET. That is exactly the patch: before it,
`IS_PWRDWN_INVERTED = false` emitted `ZINV_PWRDWN = 0`; after it, the negation
emits `ZINV_PWRDWN = 1`. `ZINV` set means the pin is NOT inverted, which is
correct for a `PWRDWN` and `RST` that should be active-high and undriven.

### Why this is worth having

The fix was previously supported by a behavioural argument -- the MMCM locks
now, it did not before -- which is real evidence but indirect. This is the
mechanism itself: the two configuration cells that changed, named by prjxray,
read off the silicon. For an upstream PR that is the difference between "this
made my design work" and "this sets exactly these two documented bits, and here
they are in the device."

Worth noting: the patch also negates `ZINV_PSEN` (28_110) and `ZINV_PSINCDEC`
(29_110). Those bits are **identical** between the two builds here, so this
design does not exercise them. Their correctness rests on the same encoding
argument but has not been confirmed on silicon. Do not claim it has.

### Which CMT, and which designs use one

Scanned all four CMT base addresses on the 7z020, minors 28/29 only:

    design        0x2400   0x402400          0x422400   0x420080
    of_s9           -         -                 -          -
    mm_s0           -         -                 -          -
    mmcm_b          -      15 / 17 words        -          -
    mmcm_zinv       -      15 / 17 words        -          -

`of_s9` -- the radio build -- instantiates **no CMT at all**. That is a stronger
statement than the earlier conclusion that the CMT was "not in the clock path":
there is no MMCM or PLL in that design to be in any path. The all-ones census
that failed to perturb the oracle could not possibly have done so.

`base_tile` in `SiliconSweep` (`CMT_TOP_L_LOWER_B_X178Y61`, `0x00402400`) was
therefore the RIGHT target all along. The mistake was pairing it with a design
that has no CMT. Any CMT sweep must run against `mmcm_zinv` or `mmcm_b`.

### Whole-tile confirmation

The two-bit result above was from minors 28/29 only. Repeated across **all 30
frames of the tile** (3030 words), excluding the device-computed ECC word:

    diff_words_excluding_ecc: 2

        minor 28, word 3   0x00004000 -> 0x0000C000   bit 111
        minor 29, word 3   0x00004000 -> 0x0000C000   bit 111

Nothing else anywhere in `CMT_TOP_L_LOWER_B_X178Y61` differs between the pre-fix
and post-fix builds. The patch's entire effect on the configuration memory of
this tile is those two cells, and both are named in prjxray:

    CMT_TOP_L_LOWER_B.MMCME2_ADV.ZINV_PWRDWN   28_111
    CMT_TOP_L_LOWER_B.MMCME2_ADV.ZINV_RST      29_111

This is the claim to put in the upstream PR. It is not an inference from
behaviour; it is the configuration memory of the running device, read back
without any vendor tooling.

## 19. Census replicated on the correct target

The earlier census ran against `CMT_TOP_L_LOWER_B_X178Y61` while a design with
**no CMT at all** was loaded. Repeated with `mmcm_zinv` loaded, which does
populate that tile:

    candidates   3136
    real_cells   3136
    pruned       0
    tile before  minor 28: 15 nonzero words, minor 29: 17
    tile after   minor 28: 49, minor 29: 49   (every write landed)

Same answer, now on the right target with the right design. **All 3136
addressable bit positions in CMT minors 28 and 29 are real, writable
configuration cells.** The dark space is not dark, and `:functional` -- one bit
at a time, O(n) -- remains the only route.

Restoring the bitstream returned the tile to (15, 17) exactly.

## 20. Readback is deterministic; capture-based dynamic sensing is not available

**Repeatability.** Two consecutive readbacks of the same 202 words, excluding
the device-computed ECC word: **0 differing words.** Readback is noise-free and
bit-exact on repeat, which is the precondition for using it as a measurement
instrument rather than a diagnostic.

**Capture attempt.** `CMD GCAPTURE` (0x0C) snapshots live flip-flop state into
the configuration memory shadow, where readback can retrieve it. If that worked,
it would give a **dynamic oracle over devcfg alone** -- clock liveness, counter
progress, MMCM behaviour -- with no dependency on the fabric AXI path that is
currently broken.

The commands are accepted (`{:ok, 143364}`, same as any well-formed stream), but
no dynamic bits were observed:

    FAR 0x900     5 frames    0 dynamic words
    FAR 0xA00     8 frames    0 dynamic words   <- CLBLL_L_X20Y1xx, design logic
    FAR 0xA80     8 frames    0 dynamic words   <- CLBLM_R_X21Y1xx
    FAR 0x420A00  8 frames    0 dynamic words

The CLB addresses were taken from `mmcm_b.fasm` (which places logic at
`CLBLL_L_X20Y100`+) via `tilegrid.json`, so these are the columns the design
actually occupies -- not a blind scan.

**Interpretation, carefully.** This does not prove GCAPTURE is unavailable. It
shows that *these* designs present nothing that changes between captures. The
MMCM probe designs were built to be measured through a fabric register over AXI;
they contain no free-running counter whose state would differ 250 ms apart.

### The design change this argues for

Build a **readback beacon**: a minimal EHDL design containing a free-running
counter clocked by the MMCM output, placed in a known tile. Then MMCM lock and
frequency become observable through GCAPTURE plus readback, with no AXI at all.

That would make the entire silicon-characterisation line -- including
`:functional`, which is currently blocked only by needing an oracle -- immune to
the fabric AXI fault that has cost this whole evening. It is also buildable
offline, with no board time.

### GCAPTURE: thoroughly tested, no dynamic state observable

Scope of the negative, so nobody repeats it:

    design      of_s9 (741 FF features, free-running heartbeat) and mmcm_zinv
    ranges      FAR 0x900, 0xA00, 0xA80, 0x420A00, 0xC00, 0x400C00,
                0x400A80, 0x980
    depth       10 frames each, PLUS one full 36-frame CLB tile (3636 words)
    tiles       chosen from libresdr_radio_s9.fasm via tilegrid.json, i.e. the
                columns the design actually occupies -- not a blind scan
    spacing     250-400 ms between captures
    extra       explicit RCRC + GRESTORE + START + 1024 NOOP clocks before
                re-testing

    result      0 dynamic words, every time. Both readbacks complete.

All command streams are accepted (`{:ok, 143364}`), and plain readback is
bit-exact and repeatable, so the path itself is sound. Nothing in these designs
changes between captures.

### The synthesis worth keeping

Two independent observations now point the same way:

    the fabric AXI slave never responds  (read hangs the CPU, any bitstream)
    no flip-flop anywhere changes state  (full tile, design's own columns)

The simplest thing that explains BOTH is that **the PL is configured but not
running** -- global set/reset still asserted, so nothing clocks and no slave
answers. That is one hypothesis covering two symptoms that were previously
being chased separately.

It is NOT yet established. `PCFG_DONE` is set, and an explicit
`RCRC / GRESTORE / START` plus 1024 clocks changed nothing -- though if DONE is
already high, `START` is a no-op, so that test is weaker than it looks.

Note the shape is familiar: the readback bug earlier tonight was also "the
engine needs clocks after the command stream ends, and devcfg stops providing
them." A startup sequence that stalls for the same reason would be the same bug
in a different phase. Worth checking whether `devcfg_load` sends trailing clocks
after the final word of the `.bin`.

## 21. prjxray's zynq7 CMT documentation verified bit-exactly on silicon

Round trip: FASM feature -> prjxray zynq7 segbits -> predicted frame bit ->
actual bit read back off the device. Design `mmcm_zinv`, tile
`CMT_TOP_L_LOWER_B_X178Y61` (`0x00402400`), minors 28 and 29.

    assertions checked      209   (206 must-be-1, 3 must-be-0)
    disagreements             0
    bits set on silicon     208
    bits unexplained          0

**Every bit set in that tile is accounted for by a documented feature, and every
documented feature lands exactly where prjxray says.** No discrepancies, no
undocumented bits.

### The methodological trap, which cost an hour and nearly produced a false claim

Two bits (`28_1560`, `29_1558`) initially looked undocumented. They are not.
Tile windows **overlap within a frame**, and segbits are **tile-relative**:

    CMT_TOP_L_LOWER_B_X178Y61   offset 0    words 49   frames 30   -> words 0..48
    HCLK_CMT_L_X178Y78          offset 45   words 10   frames 30   -> words 45..54
    INT_L_X72Y74                offset 48   words 2    frames 28   -> minors 0..27 only

Words 45-48 of minors 28/29 are claimed by BOTH the CMT tile and `HCLK_CMT_L`.
Treating the CMT's whole 0..48 window as CMT-owned attributes the HCLK tile's
bits to the CMT. Converting properly:

    HCLK_CMT_L.HCLK_CMT_MUX_MMCM_CLKIN1.HCLK_CMT_CCIO2 = 28_120 29_118
    absolute = offset*32 + b = 45*32 + 120 = 1560
             = 45*32 + 118 = 1558

Exactly the two bits. One documented feature of a neighbouring tile.

**Rule: never attribute a frame bit to a tile without resolving ownership
through `(offset, words, frames)` across every tile sharing that baseaddr.**
`frames` matters as much as `offset` -- `INT_L` also covers word 48 but has only
28 frames, so it cannot own anything in minors 28/29.

This is the exact shape of error that produces bogus "undocumented bit"
discoveries, and it would have survived review by anyone who did not re-derive
the window arithmetic.

### Two claims corrected

* Earlier in this session: "zynq7 has no CMT segbits, it falls back to artix7."
  **Wrong.** `zynq7/segbits_cmt_top_l_lower_b.db` exists (403 lines) at the
  FAMILY level; the earlier check looked in the PART directory
  (`zynq7/xc7z020/`), where segbits never live. The proposed "contribute missing
  zynq7 CMT segbits" PR is void.

* zynq7 and artix7 CMT databases genuinely differ (403 vs 405 lines, with real
  content differences in the `CMT_LR_LOWER_B_MMCM_CLKFBIN` pips). The first
  verification pass used artix7 by mistake; redoing it against zynq7 gave the
  same 209/0 result, so the conclusion survives -- but the correct database is
  zynq7 and any future work must use it.

### What this is worth to the community

Not a new feature. A **hardware verification** of an existing database on a part
whose CMT documentation was, as far as this project can tell, never checked
against real zynq7 silicon without vendor tooling: 209 bit-level assertions,
zero failures, entirely through PCAP readback.

---

## 22. The readback stream has a 14-word lead that no Xilinx document mentions

### The claim

A PCAP frame readback on xc7z020 does **not** begin with the frame data, and it
does not begin one pad frame in either. It begins with **14 words** of lead,
*then* the one-frame configuration pipeline pad, *then* the requested frames.

    raw readback stream
      [ 0 .. 13 ]        14 words of lead      <- undocumented
      [ 14 .. 114 ]      pipeline pad frame    <- XAPP1230 documents this one
      [ 115 .. ]         frame data            <- what you asked for

Every readback in this project before now used `Enum.drop(101)` -- the pad frame
alone -- on the strength of XAPP1230's "32530 frames + 1 frame + 10 words". That
is off by 14 words, and a 14-word displacement is the worst possible kind of
error: shifted routing data still looks exactly like routing data, so nothing
downstream complains. It attributes every bit to the wrong position silently.

### How it was measured, three independent ways

Ten frames at `FAR=0x900` on `of_s9`, compared against `base.frames`:

    base[0]  = 0x00020800     silicon[14] = 0x00020A80   (known 1-bit routing diff)
    base[10] = 0x06020800     silicon[24] = 0x06020800
    base[85] = 0x06020000     silicon[99] = 0x06020000

and decisively by the **frame ECC**, which lives in word 50 of a frame
(section 15) and was found at word 64 -- `0x1A6D`, a 13-bit value sitting among
`0x06020800`-class routing words. 64 - 50 = 14, matching the other two.

Applying the corrected offset reproduces the known answer exactly:

    frame 0x900, offset 115, 3 differing words out of 101
      word  0   base 0x00020800   silicon 0x00020A80
      word  9   base 0x00000000   silicon 0x00040000
      word 50   ECC, device-computed

which is word-for-word the result recorded earlier in HANDOFF.md.

### CORRECTION: the lead is NOT a constant. It changes between boots.

This section first claimed the lead was a fixed 14, on this evidence, all of
which is real and all of which was taken within a single boot:

  - **5 consecutive identical reads**: lead = 14 every time.
  - **request sizes 6, 8, 10, 14, 20, 30 frames**: lead = 14 every time.
  - identical for FAR 0x900 and FAR 0x402400.

The very next boot gave **lead = 0**. Same board, same bitstream
(`mmcm_zinv`), same tile, same code, mirrored result:

    boot A   lead 14   209/209 assertions agree at offset 115,  13/209 at 101
    boot B   lead  0   209/209 assertions agree at offset 101,  13/209 at 115

So it is stable WITHIN a boot and varies BETWEEN boots, which is the most
misleading shape this could have taken: it looks like a constant for exactly as
long as you are in a position to check it. An earlier revision of
`silicon_sweep.exs` hardcoded 14 on the strength of the measurements above and
was wrong on the next power-up.

**The lead must be measured on every read.** Not per session, not per boot --
per read. What varies with it is not yet known; FCLK, engine state at load
time, and the DESYNC history of the previous stream are all untested
candidates.

### Detecting alignment without knowing the design

`base.frames` cannot serve as the alignment reference in general -- it comes
from a different build than whatever is loaded, so a mismatch is ambiguous
between "misaligned" and "different design". The frame ECC can, and it is the
only field in a frame whose value range is known a priori:

  - 13 bits wide, so always `< 0x2000`
  - recurs every 101 words
  - non-zero in any frame that has content

Sliding a 101-tooth comb over the raw stream and scoring how many teeth land on
a **non-zero** 13-bit value locates the frame grid with no knowledge of the
design under test. Implemented as `RbCheck.align/1`.

Three traps, all hit, all worth recording because each produced a confident
wrong answer:

  1. **`< 0x2000` alone is degenerate.** These frames are mostly zeros, and zero
     passes the test, so nearly every offset scored 1.0. The non-zero
     requirement is what makes the comb discriminate.
  2. **Same-phase offsets are not competitors.** 115, 216, 317 ... all satisfy
     `rem(o,101) == 14` and necessarily score identically, so a perfect
     detection reported itself as a dead tie. Confidence must be measured
     against a *different* phase.
  3. **Empty frames are not evidence.** An all-zero frame has an all-zero ECC
     legitimately. Scoring them as misses dropped a correct detection from 1.00
     to 0.76 over sparse regions -- which is exactly the regime `:census` runs
     in, on a mostly-unused tile.

The detector returns the phase; the pad frame is then dropped by construction.
Deriving the offset as `phase + 101` rather than taking the best-scoring offset
matters: once empty frames are excluded the pad frame becomes invisible to the
scorer, and the argmax drifts to offset 14, which indexes every frame one too
early.

### The second consequence: a 30-frame request does not return 30 frames

The lead is not free. `words_for(n) = (n+1) * 101` sizes the DMA for the pad
frame only, so 14 words of lead push the tail of the last frame past the end of
the buffer and it is discarded as a short chunk:

    request 30 frames -> 3131 words -> drop 115 -> 3016 words -> 29 full frames

**Minor 29 comes back missing, silently.** For the CMT that is catastrophic and
almost invisible: 120 of the 209 documented assertions live in minor 29, so
they all read as zero, and a tile that is 91/209 correct looks like a
half-right database rather than a truncated read.

Request `n + 2` frames to get `n` -- `Readback.request_frames/1`. Ask the
command stream and the DMA for that SAME count.

Do **not** instead widen the DMA past the engine's request. Both asymmetric
variants were tried and both stalled the engine, costing a power cycle each:

    DMA 3232 / engine 3131    inverted the asymmetry outright
    DMA 3232 / engine 3333    stalled anyway, on the SECOND read after a load,
                              having succeeded on the first

The second is the interesting one: the engine did not deliver 3232 words
despite being told to produce 3333, so **its output is not governed by the
type-2 count alone**. The asymmetric-lengths rule in HANDOFF.md holds for the
case it was measured on -- collecting far fewer words than requested, as in a
short register read -- and does not generalise to collecting one frame fewer.

The symmetric form, asking for exactly what is collected, has run many
consecutive reads across both boots without a stall. That is what the harness
does now.

### Verified: the CMT documentation result reproduces exactly

The decisive test, on design `mmcm_zinv`, tile `CMT_TOP_L_LOWER_B_X178Y61`,
against the same 209 assertions as section 21 -- read 32 frames, then score the
identical assertion set at each candidate offset:

    offset 101   (pad frame only, the old assumption)     13 agree, 196 disagree
    offset 115   (pad frame + measured 14-word lead)     209 agree,   0 disagree

An exhaustive scan of offsets 0..400 puts 115 first at 91/209 on the truncated
30-frame read and second place at 52 -- the ECC comb, the `base.frames`
comparison and this assertion set all pick the same offset independently.

So **section 21 stands, and now stands on a measured alignment rather than an
assumed one.** The census (3136/3136) is in the same position: it wrote and
read the same window through the same path, so a constant displacement affects
both sides equally.

What remains genuinely unknown is **what** the lead depends on. It is no longer
a blocker: the alignment is measured per read by a detector that has now been
validated twice, on OPPOSITE answers, each time confirmed independently by the
209-assertion set. A detector that gets 115 right on one boot and 101 right on
the next is doing real work, which a constant cannot.

### Boot C, and the final detector

A third boot gave **lead 0** again, so the observed distribution is 14, 0, 0 --
enough to prove it varies, not enough to say what it depends on.

Verification on boot C, through `SiliconSweep.readback_tile/1` (the harness
path, not a bespoke probe): **nine consecutive reads, 30 frames each, 209/0
assertions every time, DMA queue idle afterwards.** No stall.

The detector ended up with three independent signals, added in this order
because each was forced by a case the previous one could not settle:

  1. **ECC comb** -- teeth every 101 words landing on a non-zero 13-bit value.
     Settles the sparse case.
  2. **Distinctness** -- a frame's ECC is effectively a pseudorandom 13-bit
     number, so teeth should mostly DIFFER. Structured configuration data
     repeats. Necessary because a rival phase over a dense region scored a
     perfect 1.0 hit rate.
     (Count distinctness over the SAME filtered set as the hits. Counting it
     over all teeth while counting hits over only ECC-shaped ones yields
     `distinct/hits > 1` and a "hit rate" of 1.091.)
  3. **The zero pad frame** -- the pipeline pad is all zeros whatever the
     design, which is a fact about the configuration engine and not about the
     bitstream. This is the one that settles the dense case: over FAR 0x900 a
     rival phase matched on hit rate AND distinctness, because dense routing
     data is full of small varied non-zero words. It cannot fake 101
     consecutive zeros in the right place.

Signal 3 is the strongest and the cheapest, and in hindsight should have been
first. It is kept as a tiebreak rather than the sole test because it assumes
the pad frame is present, which is exactly the kind of assumption this section
exists to warn about.

### The detector's confidence threshold

Every verified-correct detection so far:

    boot A, FAR 0x900     hit 1.000   runner-up 0.600   margin 0.40
    boot A, CMT tile      hit 0.833   runner-up 0.286   margin 0.55
    boot B, CMT tile      hit 0.786   runner-up 0.333   margin 0.45

**Margin is the discriminating statistic, not absolute hit rate.** An absolute
threshold of 0.9 -- the first thing tried -- would have rejected two of these
three, both independently confirmed correct. The threshold is now
`rate >= 0.7 and rate - runner_up >= 0.25`.

### Also: the PL is NOT configured at boot

`PlLoad.preflight/0` before the first load on a fresh boot:

    pcfg_done: false

The bitstream was removed from the SD card's boot partition to fix a U-Boot
hang, and nothing replaced it. So on a fresh boot the fabric is empty, and a
readback returns a stream of zeros that completes cleanly and looks exactly
like a broken instrument. It cost most of an hour here. The gate is
`PlLoad.pcfg_done?/0`, and it is PS-side and cannot hang.

### The mistake this cost, recorded because it is the easy one to repeat

Raising `words_for/1` from `(n+1)*101` to `(n+2)*101` to cover the lead, while
`arm_sequence/2` still computed its type-2 count as `(n+1)*101`, **inverted the
asymmetric-lengths rule**: the DMA was told to collect 3232 words from an engine
that had been told to produce 3131. It waited for 101 words that were never
coming, and devcfg wedged on the first call -- one power cycle.

The two quantities are one decision and must be edited as one:

    words_for(n)     = (n + 2) * 101      what the DMA collects
    engine_words(n)  = (n + 3) * 101      what the command stream requests

`engine_words` is now derived from `words_for`, so the surplus cannot be lost
by editing one of them. Over-production is free -- the extra words are
discarded by DESYNC. Under-production costs a power cycle every time.

---

## 23. Everything re-verified through the corrected instrument

Section 22 changed how frames are located, which means every earlier claim was
derived through a reader that has since been shown to be wrong on some boots.
So they were re-run, on boot C, through the harness path.

### The census stands

    census over 3136 candidate bit positions in CMT_TOP_L_LOWER_B_X178Y61
    candidates 3136    real_cells 3136    pruned 0

Unchanged from section 17. The dark space is still not dark.

### The round trip, which is the strongest single check in this project

Write, measure, restore, measure again -- with a prediction made in advance:

    baseline                        209 agree, 0 disagree
    after census writes all ones    206 agree, 3 disagree
    after reloading mmcm_zinv       209 agree, 0 disagree

The assertion set contains **206 must-be-1 and 3 must-be-0**. Setting every bit
in the tile to 1 should therefore break exactly the three must-be-0 assertions
and leave all 206 must-be-1 intact. That is precisely what happened, to the
bit.

This ties together four things that had only ever been checked separately:

  * the WRITE path puts bits where it claims to
  * the READ path finds bits where it claims to
  * prjxray's zynq7 CMT segbits name the right positions
  * a reload fully restores the tile, so experiments are reversible

A displaced reader could not produce 206/3. A misdirected writer could not
either. Getting the exact predicted split is a coincidence that has to be
engineered.

### Stability

Nine consecutive `readback_tile/1` calls on boot C, plus the census write and
the reload round trip: no stall, DMA queue idle throughout, 30 frames returned
every time. The symmetric length configuration is sound.

---

## 24. The mirror census: 2928 positions proven bidirectional

### Why the all-ones census was only half a result

`:census` writes 1 to every candidate and keeps whatever reads back 1. That
cannot distinguish

    a real cell currently holding 1        from
    a position that is not a cell and reads as 1

Both give the same answer, and "3136 of 3136" is exactly what a stuck-high
readback would also produce. The claim needs the mirror.

### Most of the mirror was already collected, for free

The round trip in section 23 read the tile at two known states -- pristine
(`clean`) and post-all-ones (`dirty`). Cross-tabulating all 3136 candidates
across those two reads costs no board transactions at all:

    clean 0, dirty 1     2928     held 0, then held 1  -> PROVEN storage
    clean 1, dirty 1      208     only ever observed at 1

So **2928 of 3136 positions are demonstrated read/write configuration cells**,
observed holding both values. That is a much stronger statement than the
original 3136/3136, and a more honest one.

The residual 208 is not a mystery: it is exactly the "208 bits set on silicon"
from section 21 -- the documented features the design actually uses. They are
1 in the pristine bitstream, so an all-ones write tells us nothing new about
them.

### RESOLVED: all 3136 positions are proven bidirectional

The all-zeros write completed after the defect below was fixed:

    clean 0 -> zeroed 0     2928
    clean 1 -> zeroed 0      208     <- the residual, now driven to 0
    still reading 1            0

Combining with the all-ones census, every one of the 3136 candidate positions
has now been observed holding **both** values:

    2928    0 pristine, 1 after all-ones write
     208    1 pristine, 0 after all-zeros write

**All 3136 of 3136 are demonstrated read/write configuration cells.** Not
"stuck at 1 after a write that set everything to 1" -- actually storage,
proven in both directions.

### The assertion set lands exactly where predicted in all three states

    pristine      209 agree,   0 disagree
    all ones      206 agree,   3 disagree     (the 3 must-be-0 flip)
    all zeros       3 agree, 206 disagree     (the 206 must-be-1 flip)

206 must-be-1 and 3 must-be-0. Setting the tile to all ones should break
exactly the three zeros; setting it to all zeros should break exactly the 206
ones. Both predictions were written down first and both came out to the bit.

That is a complete bidirectional round trip through the write path, the read
path, and prjxray's zynq7 CMT segbits simultaneously. A displaced reader, a
misdirected writer, or a wrong segbits database each fail this in a different
and visible way.

The DMA queue was idle afterwards -- the `write_frames/2` fix below is
confirmed on silicon.

### Closing the last 208 required an all-ZEROS write, and that found a defect

The experiment is one write and one read: zero minors 28/29 across the tile
window, read back, expect 3136 zeros. The first attempt did not complete,
because the write exposed a real bug.

**`write_frames/2` did not append the pipeline pad frame.** It built its
payload with `List.flatten(frames)` while `write_sequence/2` declares an FDRI
packet of `(n+1)*101` words. The engine therefore sat mid-packet waiting for
101 words that never arrived, consumed the trailing DESYNC as frame data, and
the next readback stalled.

Three things make this worth recording rather than just fixing:

  * The write reported `:ok`. It *was* successful as far as it went; the
    deficit is invisible until the next read.
  * The failure presents as a **broken reader**. Time was spent last session
    on exactly that misattribution.
  * `:census` was never affected, because `write_all_ones/2` already used
    `write_payload/1`. Two writers, one of them correct, and the incorrect one
    is the one `poke_load_test/4` uses -- so the entire `:functional`
    strategy would have hit this on its first poke.

Fixed: `write_frames/2` now uses `write_payload/1`. Any future frame writer
must go through `write_payload/1`; flattening a frame list directly is the
error, and it has now caused two distinct failures in this project.

---

## 25. Writes are confined to the tile window

The census and the mirror both compare only the positions they wrote, so
neither can see collateral damage -- and collateral damage is exactly what
would invalidate attributing an observed behaviour change to the poked bit.

Two escapes are possible, and reading a WIDER window than the tile checks both
at once. Ones written into minors 28/29 words 0..48, then 36 frames compared
against the pristine image word for word:

    frames compared          36     (tile is 30 -- minors 30..35 are neighbours)
    words changed            98     = 2 minors x 49 words, the whole window
    intended changes         98
    COLLATERAL CHANGES        0

Zero escape in either direction:

  * **within a frame** -- words 49..100 belong to tiles that share the
    baseaddr (`HCLK_CMT_L` at offset 45, `INT_L` at offset 48; section 21
    established these windows overlap). None moved.
  * **across frames** -- minors 30..35 lie past the tile's 30 frames
    entirely. None moved.

Alignment was measured as lead 0 on both the before and after reads, so the
comparison is between two correctly-indexed images rather than two guesses.

This is what licenses the whole poke-and-observe method: a behaviour change
after a poke can be attributed to the poked bits, because nothing else moved.
