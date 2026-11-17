# STREAM_RX session log — 2026-08-03 (Fable, session 2)

> Raw session log: records what was believed at the time. Where it disagrees
> with `nerves_system_libresdr/README.md`, its `docs/`, or `nervezynq/AGENTS.md`,
> those win.


Picking up STREAM_RX_HANDOFF.md. Everything below either happened this
session (marked measured) or is staged and waiting on a gate.

## Measured this session

* **Silicon == source confirmed.** The shipped `hp_dma_s0.bin` auto-advances
  the capture read pointer: seek-to-0 then `Fabric.read_repeat(0x28, 16)`
  returned the identical 16 words as the addressed readout
  (`match=true distinct=16`, live RF in the buffer). Tier 0's ~200x readout
  is therefore a one-line software change whenever wanted (parked by
  explicit decision — this session went straight at the DMA path).

* **The toggle-CDC + register-FIFO stream fabric is unroutable on this
  part/flow.** 0 of 167 seeds across two variants (16-deep: 46/46 failed,
  `axi_clk -> SLICE CLKINV_OUT`, router debug shows 660 blocked leaf wires
  held by `data_clk`; 8-deep: signature flips, `data_clk` fails with 413
  wires held by `axi_clk`). Mechanism: the 64-bit cross-domain bus makes
  the placer interleave the two clock islands tile-by-tile, and the
  nextpnr-xilinx clock router cannot feed both clocks into the leaves at
  that density. Whichever clock routes second loses.

* **Elaborator/validator findings** (both filed in-code where hit):
  * `hdl_case` no-match yields 0 — it does NOT retain a prior default
    assignment. Caught by RegFIFO16's own testbench (r0 read as 0). All
    case arms must be explicit.
  * Instance-local `sync_read:` clocks do not resolve
    (`ElabError: no clock named :rd_clk`). Sync-read memories work at top
    level only — why Hw.StreamBRAMFIFO's logic is inlined in top.ex.
  * The hard CDC validator (`validate.ex` E040) models only direct
    reg->reg crossings; its whitelist set has no writer. Gray-coded
    crossings need the same comb-fed shape Sync2 uses.

## The design that came out of it (staged, in the seed lottery now)

    LVDS -> Hw.AD936xFramePacker (DATA_CLK) ----\
    {~ctr,ctr} 32-bit counter @ DATA_CLK/4 -----+--> 1024x64 dual-port BRAM
                                                     (write port DATA_CLK,
                                                      read port AXI_CLK — the
                                                      capture-bank idiom)
                                                       |
                        11-bit gray write pointer -> 2-flop sync -> count
                                                       |
                       Hw.AXIHPWriter BURST_LEN 16, PIPELINED_SOURCE 1
                                                       |
                                    HP0 -> DDR ring 0x3FF0_0000 (1 MB)

* Word format (single source of truth = Hw.AD936xFramePacker moduledoc,
  mirrored in hp_stream.exs): [11:0] I1, [23:12] Q1, [35:24] I2,
  [47:36] Q2, [61:48] SEQ mod 16384, [62] ERR (first frame after resync),
  [63] 0. Raw 12-bit two's complement, nibble_swap:false edge assembly
  untouched. One frame per beat: frame boundary == beat boundary == burst
  divisible; every word self-identifies via SEQ.
* Both producers write the BRAM from the DATA_CLK side — so counter mode
  now REQUIRES DATA_CLK alive (SDR.open first). Recorded trade: the +1
  oracle exercises the exact radio path at the exact radio word rate, but
  the V0 "DMA without radio" regression is gone.
* Engine gained PIPELINED_SOURCE (WVALID 1,0 gapped beats, ~400 MB/s
  ceiling vs 64 MB/s need at 8 Msps) to match the BRAM's strobed read
  port. Fully testbenched (test/axi_hp_writer_pipelined_test.exs) — the
  BRAM FIFO control logic reduced to pointers precisely so the only
  untestable element is the BRAM construct the capture banks already
  proved.
* EMIO map (bank 2 out): [0] enable, [1] source (0 ctr / 1 radio),
  [2] sticky-flag clear. Status adds [60:58] overrun count, [61] overrun
  sticky (= count>1024, producer lapped), [62] packer sync_lost,
  [63] source readback. All else unchanged from hp_dma_s0.

Tests: 32/32 green (packer 8, RegFIFO8 7, RegFIFO16 7, engine legacy 8+,
engine pipelined 2). RegFIFO8/16 stay as tested library components; the
shipped design uses the BRAM FIFO.

## Software staged (serve dir has all three)

* `hp_stream.exs` — Nervezynq.HPStream: GPIO EMIO control/status (never
  AFI!), ring reader with wrap, `rate_test/1` (Gate A+D), `capture_burst/2`
  (gapless ≤ ~960 KB with SEQ proof — the beacon-depth capture),
  `stream_rx/2` (decimated newest-window delivery for the waterfall),
  decode + seq/counter checkers.
* `sdr.exs` — gains stream_rx/stream_stop/stream_capture delegating to
  HPStream.
* `wf_tap.exs` — `{:mode, :stream}` command: rows become newest-N-frames
  reads from the ring, decoded board-side to the SAME wire format, so
  NzScope needs zero changes. Meta gains stream?/seq_holes.

## Board gates (when a seed routes: stage as taps/serve/hp_dma_s1.bin)

    # load: PlLoad bracket — invalidate -> devcfg_load -> PCFG_DONE -> authorise
    # then the ritual:
    {:ok, _} = Nervezynq.SDR.open()            # THR_CNT, guard, magic, radio
    Code.compile_file("/data/hp_stream.exs")
    Nervezynq.HPStream.setup()

    # Gate A — counter continuity through the REAL path (radio-rate):
    Nervezynq.HPStream.rate_test(500)
    #  expect: mb_per_s ~= DATA_CLK/4 * 8B (64 MB/s at 32 MHz DATA_CLK),
    #  tail_4k %{gaps: 0, bad_words: 0}, bresp_errs 0, smoke_ok true

    # Gate B — BIST known-answer THROUGH the DMA path:
    {:ok, _} = Nervezynq.AD9363.bist_tone(:rx, 0, 0, 0)
    {:ok, cap} = Nervezynq.HPStream.capture_burst(65_536)
    #  cap.seq.holes == 0, then decode invariants:
    #  deg_per_sample 11.25 +-0.5, mag_cv < 1e-2 on ch1 AND ch2
    #  (validate via MIMO-style stats over cap.ch1/ch2 — helper in gate script)
    Nervezynq.AD9363.bist_tone(:disable)

    # Gate C — gapless across wraps: capture_burst(917_504) twice,
    #  seq.holes == 0 both times (start offset forces >= 1 wrap on the 2nd)

    # Gate D — sustained radio stream: stream_rx(self()), watch 60 s:
    #  overrun_sticky never set, sync_lost never set, seq holes only
    #  between polls (lapping), never within a window

## Open items

* Seed lottery for the BRAM-FIFO netlist still running at session close of
  this note (sweep 0..200). If it stays dry: next levers are (a) control-
  rebuild of HEAD top.ex to recalibrate the lottery baseline, (b) trimming
  IDELAY VAR_LOAD plumbing if it can be spared, (c) the nextpnr router-pair
  patches queued in ZINV_PR.md's "after filing" list.
* MIMO.@fabric_needs_nibble_swap default still true (runtime probe still
  pending — SDR_V1 next-step #1). The stream path pins false everywhere.
* NzScope: nothing needed for stream mode (board-side decode decision),
  but a host-side decode port remains the right move if anyone ever ships
  raw beats at higher rates.

## Addendum — same session, after regroup

### Tier 0 SHIPPED and measured (the waterfall is live)

`LVDSProbe.capture/1` now does seek-to-0 + `Fabric.read_repeat(0x28, n)`:

    rx(1000):   ~2,500 ms -> 35 ms   (70x wall-clock; readout itself ~200x)
    selftest(): pass=true, ch1 & ch2 deg_per_sample 11.25, mag_cv 3.4e-4,
                60 ms total — the known-answer gate through the NEW readout
    waterfall:  ~11-12 rows/s at interval 50 ms; ~25 rows/s at {:interval, 0}

Hot-loaded on the board (served as lvds_probe.exs) AND committed to
lib/nervezynq/lvds_probe.ex, so the next firmware build carries it.

### The DMA bitstream is blocked on a characterized router cliff

Control + bisect results (all same day, same toolchain):

    pre-revision top (control):        ROUTED seed 8 (0..7 failed) — ~1/9 odds
    stream top, RegFIFO16 (axi FIFO):  0/46
    stream top, RegFIFO8:              0/121
    stream top, BRAM FIFO:             0/201
    V-packer (control + packer ONLY):  0/50   <- +~200 data_clk FFs
    V-bram (stream minus packer):      0/50   <- +~60 data_clk FFs + 2 BRAM

Every failure: clock arc to SLICE CLKINV_OUT, the other clock's wires
blocking (660 data_clk-held wires vs axi_clk, 413/516 axi_clk-held vs
data_clk — from the --debug who-blocks trace). Conclusion: nextpnr-xilinx
(ourfork, WITH fix/router-reserve-parallel-pips merged) routes the two-clock
baseline at the edge of its capability; ANY growth of the DATA_CLK domain
falls off the cliff. This is a router capacity defect, not a lottery —
wip/clock-router-retry-DISPROVEN already rules out the naive fix.

Bisect variants preserved: designs/libresdr_radio/top.ex.vpacker,
top.ex.vbram, top.ex.control (pristine hp_dma_s0 source).

### Paths forward, ranked

1. Trade, don't add: drop the 8-bank snapshot capture from the stream
   bitstream (the DMA capture_burst replaces it, 128x deeper, SEQ-proven);
   rollback = reload hp_dma_s0.bin. Frees more DATA_CLK budget than the
   packer + ring writer cost. One focused session incl. software rerouting
   of rx/1 + selftest onto the stream.
2. Router surgery: the defect is now precisely characterized (sequential
   clock routing, no rip-up of blocking nets, whichever clock routes second
   starves). tool/router-arc-diag is the instrument; days not hours.
3. With Tier 0 shipped the pressure is off: the waterfall is watchable
   today, and DMA remains what it always was — the gapless/beacon-depth
   path, not the only path to a usable scope.

## DECISION: fix the router (campaign plan for next session)

Chosen over the stream-only-bitstream workaround (which stays available as
a fallback experiment if the router work stalls). Rationale: removes the
seed lottery from every future revision including TX, instead of designing
around it forever. Precedent: the ZINV CMT fix — same shape, worked.

### The reproducer kit (already on disk — do not rebuild it)

* FAILS deterministically in ~5 s: `designs/libresdr_radio/build/libresdr_radio.json`
  (the stream netlist) at any seed; also the preserved variants
  `top.ex.vpacker` / `top.ex.vbram` (re-synth to get their jsons).
* PASSES: `top.ex.control` (hp_dma_s0 source) — routed seed 8 on this exact
  toolchain, same day. Perfect A/B pair, both two-clock designs.
* Failure signature: `ERROR: Failed to route arc N of net '<clk>' from
  SITEWIRE/BUFGCTRL_X0Y1[67]/O to SITEWIRE/SLICE_XxYy/CLKINV_OUT`.
* The forensic one-liner (who holds the wires the clock needs):
  run nextpnr with `--verbose --debug`, then
  `awk '/routing clock .<clk>./{f=1} f&&/skipping unavailable wire/' log |
   grep -o 'used by net .*' | sort | uniq -c | sort -rn`
  Measured: 660 (data_clk blocking axi_clk, FIFO16 netlist); 413 / 516
  (axi_clk blocking data_clk, FIFO8 / BRAM netlists).

### The defect, stated precisely

The xilinx clock pre-router routes clock nets SEQUENTIALLY (log: "routing
clock 'X'"), net-at-a-time, and when an arc's candidate wire is "used by
net Y" it SKIPS the wire — no rip-up, no negotiation, no retry with
stolen resources. On a two-clock design near leaf capacity, whichever
clock routes second starves. Seed changes only shuffle placement, which
is why it presents as a lottery until the domains grow.

### Attack order

1. READ FIRST: `wip/clock-router-retry-DISPROVEN` — learn why the naive
   retry failed before proposing anything. Also `tool/router-arc-diag`
   (the instrument) and `fix/router-reserve-parallel-pips` (merged; its
   wire-vs-pip comparison fix is adjacent code).
2. Candidate mechanisms, cheapest first:
   a. Interleave: route clock ARCS round-robin across all clock nets
      instead of net-at-a-time — turns starvation into sharing without
      any rip-up machinery.
   b. Clock-vs-clock rip-up: on arc failure, allow evicting another
      CLOCK net's segment and re-routing that net's affected arcs
      (bounded retry count). Signal nets stay untouched.
   c. Full negotiated congestion (PathFinder-style history cost) for the
      clock pass — the principled fix, most work.
3. Success gates, in order: V-bram json routes at ≥ control-like rates;
   full stream json routes; control STILL routes; fasm_audit clean on the
   result; then silicon: PlLoad bracket + Gate A (counter continuity) +
   Gate B (BIST 11.25° through the DMA path).
4. Upstream: PR with the A/B reproducer pair + wire-holder histograms,
   ZINV_PR.md template style. This is exactly the "router pair" slot its
   after-filing list reserved.

### Standing fallbacks if the campaign stalls

* Stream-only bitstream (no capture banks, ~control-sized DATA_CLK load,
  hot-swap against hp_dma_s0 via PlLoad) — 2-hour experiment, would give
  first gapless samples without the router fix.
* The full software stack + gates runbook above stay valid for whichever
  bitstream arrives first.

---

# Session 3 addendum — the router was framed; the placer did it (2026-08-03)

Campaign opened per the plan above: interleave first, then rip-up. It never
got to rip-up, because the first cheap experiment plus one forensic run
overturned the diagnosis. Everything below is measured, same toolchain, same
day.

## The chain of evidence

1. **Arc interleave alone changed the symptom, not the verdict.**
   `fix/clock-router-arc-interleave` (8169783): routeClock() split into
   identify-then-route, clock ARCS round-robined across nets. Stream
   netlist: still 0/20 — but the failing net now varies per seed (14
   axi_clk / 6 data_clk) instead of always-whichever-routed-second.
   Starvation became sharing. Ordering was not the capacity problem.

2. **The forensic run found the real address.** With the interleaved debug
   log (arc headers now name their net), EVERY failing arc's backward
   search reports exactly ONE blocked candidate wire:
   `SITEWIRE/SLICE_XxYy/CLK used by net <the other clock>` — the sink
   slice's own clock input, inside the site. Not distribution congestion:
   the placer log ("AP soln") shows e.g. SLICE_X30Y107 holding
   AFF/BFF/B5FF on data_clk and A5FF on axi_clk. A slice has ONE clock
   input. **Mixed-clock slices are unroutable by construction.** The
   413..660 blocked-wire histograms of session 2 were aggregate BFS
   exploration noise across whole nets; per failing arc it was always one
   wire. (wip/clock-router-retry-DISPROVEN is hereby vindicated: its
   result was correct, no retry fixes an illegal placement.)

3. **Hole 1 — detection blindness** (3fe5e76): fixupPlacement()'s repair
   pass collected strands via isValidBelForCell(cell, own-bel) — static
   per-cell gates only, blind to conflicts BETWEEN cells. Extended
   detection to tile level (isBelLocationValid per member); relocation
   machinery unchanged (it already re-verifies destination tiles); loud
   post-repair audit for tiles it cannot move (carry, stamped). Result:
   260 relocations fired... and the sweep was STILL 0/20, because —

4. **Hole 2 — the frozen fast-path** (152c415, the actual defect):
   xc7_logic_tile_valid()'s fully-frozen fast-path skips ALL tile checks
   when every occupied bel is bound >= STRENGTH_STRONG, intended for
   Vivado-stamped imports ("frozen == stamped: bound STRENGTH_USER" — its
   own comment). But the heap legaliser's chain path binds every ordinary
   LUT+FF cluster STRENGTH_STRONG, so any tile of chain-placed user logic
   was NEVER validated — heap's own isBelLocationValid() calls returned
   true without looking. That is how mixed slices were both CREATED
   (legalise couldn't see them) and MISSED (audit couldn't either).
   Threshold changed to STRENGTH_USER.

## Results

    stream netlist (BRAM FIFO):  0/201  ->  20/20 routed
    control (hp_dma_s0 source):  ~1/9   ->  9/9 routed
    regress.sh:                  6 passed, 0 unexpected
    fasm_audit (stream, seed 1): 5491 features, 0 undocumented, clean
    post-place audit:            0 invalid tiles remaining

**The seed lottery is over.** It was never a lottery: a seed routed iff its
placement left no slice mixed-clock. 1-in-377 on the old revision, 1-in-9 on
control, 0 once the DATA_CLK domain grew — all one defect, now closed. This
also explains V-packer/V-bram: any domain growth added boundary slices and
collision probability, nothing about FIFOs or BRAMs mattered.

## Staged for silicon

* `taps/serve/hp_dma_s1.bin` (+ .bin.gz) — the stream bitstream, seed 1,
  through the fixed toolchain. Gates A–D runbook above is unchanged and
  waiting. House rule: no nextpnr change is finished until the radio
  decodes at deg_per_sample 11.25 / mag_cv ~3e-4 through the DMA path.
* PLACER_PR.md — upstream package (ZINV_PR.md style), gated on silicon.
  Cherry-pick order for the PR branch: 152c415 then 3fe5e76.

## Branch state (nextpnr-xilinx)

* `fix/postplace-controlset-repair` — 2 commits, the fix. In ourfork.
* `fix/clock-router-arc-interleave` — 1 commit, kept: honest hygiene
  (starvation → sharing), measurably NOT sufficient alone, harmless and
  inert once placements are legal. In ourfork.
* `wip/clock-router-retry-DISPROVEN` — unchanged, correctly labeled.
* rebuild-ourfork.sh TOPICS updated (9 branches); BRANCHES.md regenerated.

---

# Session 3, silicon addendum — Gates A/B/C GREEN, GUI drew the stream, Gate D hung the board

Same day, board `lottery-lab`, all through the fixed toolchain. Chronology
matters here; everything below is measured.

## The netlist mixup, caught and corrected

The 20/20 sweep above ran on what `build/libresdr_radio.json` contained —
which turned out to be the preserved **V-bram bisect variant** (stream minus
packer) from session 2's last lottery, not the full stream design. Caught on
silicon: counter mode streamed, radio mode produced zero words, and the
routed json contained `sbuf`/`pat_lo` but no packer identifiers at all. A
fresh `build.exs --seed 1` from the actual `top.ex` produced the true
netlist (packer present, md5 6c9435f0...): **routed 10/10 seeds, fasm_audit
clean (5458 features, 0 undocumented)**. The fix holds for the real design;
the V-bram bitstream is preserved as `taps/serve/hp_dma_vbram_s1.bin`
(counter-mode DMA proven on silicon through it). Lesson re-learned: check
the json's identifiers against the top you think you built before shipping
a bitstream named after it.

## Silicon gates (true stream bitstream, `taps/serve/hp_dma_s1.bin`, seed 1)

* PlLoad bracket: load ok, PCFG_DONE, magic 0x45484431 — twice (v-bram then
  true stream), zero drama.
* **Gate A GREEN**: `rate_test(100)` = **64.0 MB/s** (DATA_CLK 32 MHz / 4 x
  8 B exactly), tail-4k gaps 0, bad_words 0, bresp_errs 0, no overrun.
  Two software defects found by the gate and fixed in `hp_stream.exs`
  (both copies): `@burst_bytes` was 64 but a burst is BURST_LEN 16 x 8 B =
  128 (halved every rate report and mis-padded the tail guard — measured
  50,518 bursts/101 ms only squares with 128 B), and the fabric burst
  counter is 16-bit so `rate_test` windows > ~130 ms alias (rate_test(500)
  reported 53,886 bursts where ~250,000 happened; default now 100 ms).
* **Gate B GREEN — the acceptance criterion, through the DMA path**: BIST
  Fs/32 tone, `capture_burst(65_536)`: 8,192 frames, **seq holes 0,
  deg_per_sample 11.25 exactly on ch1 AND ch2, mag_cv 3.45e-4** (snapshot
  path reads 3.4e-4 — same silicon truth through a completely different
  transport). Packer field walk, edge assembly, FIFO, writer, ring, decode:
  all correct.
* **Gate C GREEN**: `capture_burst(917_504)` twice — 114,688 frames each,
  seq holes 0 both, multiple ring wraps. Beacon-depth gapless capture works.
* Incidentally proven: frame_pair on silicon walks a clean one-value-per-
  cycle [3,1,0,2] (measured off the capture banks of the same bitstream),
  and the snapshot path coexists with the stream fabric (selftest 11.25 /
  3.4e-4 on the stream bitstream).

## The GUI drew the stream

`wf_tap.exs` compiled, `WFTap.start()`, NzScope up on the Mac,
`{:mode, :stream}` sent through the link: **tap reported
`mode: :stream, seq: 999` at 07:16:43** — ~1,000 rows served in ~90 s
(~11 rows/s at interval 50), each row the newest 1020 frames cut from a
ring that never blinks. The waterfall was live on the DMA path.

## Gate D FAILED: hard hang under sustained stream (~2 min in)

At ~07:17, during sustained streaming with concurrent control-plane
traffic (tap rows + HPStream.status polls from a second process + an SDR
status round-trip moments earlier), the board hard-hung: ssh timed out,
tap stopped mid-stream with no tcp_close, ping 100% loss. The classic
no-oops CPU wedge from the hazards list. Power cycle required.

What is NOT suspect: the ring reads (mmap DDR, PS-side), EMIO status
(GPIO, PS-side) — both ran ~1,000 times before the hang. What IS suspect:
a GP0 AXI-Lite fabric read or AD9363 SPI access (the periodic
`SDR.status` the tap answers) while HP0 masters DDR at a sustained
64 MB/s — an interconnect interaction the 200 ms counter windows and
~14 ms capture_burst enables never held open long enough to expose. Note
the stream ran clean for ~90+ s first: this is a sustain/interaction
defect, not a data-path defect.

### Next-session bisect (after power cycle; runbook unchanged, all files staged)

1. Reload + open + setup (5 commands, all in this doc). Stream enabled,
   tap OFF, no status polls: does it survive 10 min? (isolates pure HP0
   sustain)
2. + tap rows, no SDR.status: 10 min.
3. + SDR.status / Fabric reads each second: if THIS kills it, the fix is
   likely rationing fabric/SPI access while the stream runs (or QoS
   registers — carefully, they live in SLCR not AFI).
4. Watchdog idea worth considering regardless: the tap could skip
   SDR.status while in :stream mode and answer from cached driver state —
   removes the suspect access from the hot path entirely.

## Score

Everything up to sustained streaming is DONE and measured: the bitstream,
the transport at rate, the known-answer through DMA, gapless at beacon
depth, and the GUI drawing stream rows. What remains is one sustain bug
between a working waterfall and a *permanently* working one.
