# CMT documentation & openXC7 enablement — distance to Vivado-parity

Desk gap analysis (HANDOFF step 4). No board needed for any claim here.
Sources: openXC7/prjxray-db @ 7a36171 (2026-07-28), openXC7/nextpnr-xilinx @
c13fcbf (2026-08-03, upstream HEAD), SILICON_MAP.md sections 16–25.

## The definition, so "parity" is falsifiable

For the CMT, Vivado-parity means: **any MMCME2_ADV / PLLE2_ADV instantiation
that Vivado accepts produces, through yosys → nextpnr-xilinx → fasm2frames, a
bitstream whose CMT tile contents are attribute-for-attribute equivalent to
Vivado's, and which locks and produces the commanded clocks on silicon.**

That decomposes into four independent ledgers: the database (do bits have
names), the emitter (does nextpnr write them), verification (is any of it
true on silicon), and upstreaming (does anyone but this bench benefit).

## The finding that changes the plan: upstream has active CMT investment — and still ships the ZINV bug

CORRECTION (after inspecting the connected ~/src/openxc7 tree): the
`stable-backports` base (62839b3, 2026-07-28) **already contains** all of the
upstream CMT work listed below — upstream HEAD is only 18 commits ahead, none
touching fasm.cc, pack_clocking_xc7.cc or pins.cc. So there is no meaningful
rebase debt, the ZINV patch applies to HEAD without fuzz (verified: applies
clean and builds to 100% at c13fcbf in a clean sandbox), and — the good part —
the 209/0 silicon run was emitted THROUGH this code, so upstream's
golden-derived constants are already zynq7-silicon-verified by that run.

Upstream nextpnr-xilinx (in the base and at HEAD) contains substantial CMT
work:

* LKTABLE computed per CLKFBOUT_MULT for **both** MMCM and PLL (the PLL one
  fixed "open-flow PLL designs silent on HW while Vivado's worked")
* TABLE/FILTREG1 swap fixed (TABLE = XAPP888 filter word, FILTREG1 = 0x8),
  verified against Vivado goldens on VC707
* COMPENSATION → `COMP.Z_ZHOLD` for both INTERNAL and ZHOLD, per a re-fuzzed
  031-cmt-mmcm database; bare `COMP.ZHOLD` retired
* POWER_REG = 0x100 (was 0xffff)
* Unused counters programmed as divide-by-1 + NO_COUNT to match goldens
* Const-tied DRP/control pins (DEN, DWE, DCLK, DADDR, DI, PSCLK, PSEN,
  PSINCDEC, **RST**, PWRDWN, CLKINSEL) now **disconnected** rather than routed
  from fabric IMUXes — Vivado leaves them unrouted
* BUFR packing support (BUFR_BUFR bel mapping)

**And the ZINV polarity bug is still there at HEAD** — `fasm.cc:2253-2255`
(PLL) and `2396-2398` (MMCM) still write `IS_x_INVERTED` un-negated under the
same `// FIXME: should be INV not ZINV (XRay error?)` comment. The
`fix/cmt-zinv-polarity` branch is not upstream, and none of the seven topic
branches has been filed (`rebuild-ourfork.sh`: "None filed upstream yet").

Two consequences:

1. **The ZINV PR is now more valuable, not less.** Upstream has invested in
   CMT correctness against Vivado goldens and still carries the reset-polarity
   defect at HEAD (fasm.cc:2253/2396). The whole-tile two-bit diff
   (28_111/29_111, SILICON_MAP §18) is PR-ready evidence of exactly the kind
   their golden-matching campaign respects, and the PR can additionally hand
   them zynq7 silicon verification of their own TABLE/FILTREG1/POWER_REG/
   Z_ZHOLD choices for free.
2. **No rebase debt.** The 18-commit delta to HEAD is LUT6_2/timing/router2/
   xdc work; cherry-picking b7345b5 onto origin/stable-backports is clean
   (verified by apply+build). File it as a NEW branch (pr/cmt-zinv-polarity);
   the existing topic branches stay untouched. See ZINV_PR.md for the full
   package.

## Ledger 1 — database (prjxray zynq7). Status: effectively complete for the user-visible primitives

`segbits_cmt_top_l_lower_b.db`: 142 features / 522 bit positions, all in
minors 28/29. `segbits_cmt_top_l_upper_t.db`: 127 features / 475 positions.
Together they cover the full XAPP888 DRP register map: per-counter
HIGH/LOW_TIME, PHASE_MUX, DELAY_TIME, EDGE, NO_COUNT, MX, FRAC(+WF_R/WF_F),
DIVCLK, LKTABLE[39:0], TABLE[9:0], POWER_REG[15:0], FILTREG1/2, LOCKREG1-3,
ZINV_*, INV_CLKINSEL, SS_EN, STARTUP_WAIT, COMP, and the CLKIN1/CLKIN2/CLKFBIN
input muxes. There is no *named-attribute* documentation gap for
MMCME2_ADV/PLLE2_ADV — parity work here is verification, not discovery.

What remains genuinely dark, with honest scope:

* **2,614 of 3,136 bit positions in MMCM minors 28/29** (and a comparable
  residue in the PLL tile) are proven bidirectional storage (§24) with no
  name. Parity does **not** require knowing what they do; it requires
  confidence Vivado never sets them. Current evidence: one design, 208 set
  bits, zero unexplained (§21). Strengthening this is a verification task
  (below), and the DRP-differential idea (falsify-first, HANDOFF step 1)
  remains the cheap route to *naming* them if wanted.
* **Minors 0–27 of the CMT tile window** (49 words × 28 frames) have no
  documented features at all. Same status: dark, but nothing observed set
  there.
* **Tiles with no bit space assigned in tilegrid**: CMT_TOP_*_LOWER_T /
  UPPER_B, CMT_FIFO_L/R, CMT_PMV — the PHASER / IN_FIFO / OUT_FIFO / PMV
  territory. Explicitly **out of scope**: Vivado does not offer these to
  users outside MIG, so they do not gate user-visible parity.
* HCLK_CMT_L: 660 documented features (all clock-mux pips), 2% ever emitted —
  documented but unverified routing into the CMT. This is the darkest region
  the project actually depends on (SILICON_MAP §11).

## Ledger 2 — emitter (nextpnr-xilinx fasm.cc). The finite feature-level gap

Attributes Vivado accepts that the emitter at HEAD cannot express, measured
against the segbits feature list (14 documented features are unreachable by
any input):

| # | Attribute | Documented bits it needs | State at HEAD |
|---|---|---|---|
| 1 | CLKOUT*_DUTY_CYCLE ≠ 0.5 | *_HIGH_TIME/*_LOW_TIME/*_EDGE | `// FIXME: variable duty cycle` — high/low derived from divide only |
| 2 | CLKOUT4_CASCADE | *_CLKOUT2_MX (10 features, MMCM+PLL) | Never emitted |
| 3 | USE_FINE_PS / dynamic phase | POWER_REG value, PS port kept live | PSCLK/PSEN const-ties disconnected; fine-PS path never built; POWER_REG hardcoded 0x100 |
| 4 | Fractional + POWER_REG | POWER_REG=0xFFFF when FRAC in use (XAPP888) | FRAC bits emitted but POWER_REG stays 0x100 — latent wrong-value bug, invisible to name-level audit |
| 5 | Fractional + phase combined | PHASE_MUX_F full math | Partial (WF_F/frac_shifted); XAPP888 frac-phase formulas incomplete |
| 6 | STARTUP_WAIT=TRUE | STARTUP_WAIT | Silently ignored, no DRC |
| 7 | SS_EN/SS_MODE/SS_MOD_PERIOD | SS_EN + LOW_SS filter row | Filter table exists but only via non-Vivado BANDWIDTH="LOW_SS" string; real attributes unmapped |
| 8 | COMPENSATION=BUF_IN/EXTERNAL | input-mux features | `log_error` — hard unsupported |
| 9 | CLKIN2 / dynamic CLKINSEL | CMT_LR_*_CLKIN2 muxes | Documented, unexercised, packer path unknown |
| 10 | PLLE2 non-integer divide | (should be *refused*) | `write_pll_clkout` computes FRAC for CLKOUT1/CLKFBOUT — PLLE2 has no fractional counters; needs a DRC refusal, not emission |
| 11 | VCO/divide range DRC | n/a | Only MULT 1..64 checked; Vivado validates VCO 600–1200/1440 MHz, CLKIN period, divide ranges |

Rows 1, 2, 6 are pure desk work with cheap silicon acceptance via the
readback instrument. Rows 3–5, 7 need XAPP888 math plus one oracle
measurement each. Rows 10–11 are DRC (the "no DRC" hazard, SILICON_MAP,
cross-cutting hazard 1).

## Ledger 3 — silicon verification. What the instrument has banked vs owes

Banked (all §§16–25, reproduced through the harness path):

* 209/209 segbits assertions, three states (pristine / ones / zeros), the
  predicted 206/3 and 3/206 splits exact — write path, read path, and
  database verified simultaneously
* 3,136/3,136 positions bidirectional; confinement 0 collateral over 36
  frames; readback deterministic; alignment measured per read

Owed, in rising cost order:

* **PLLE2_ADV post-fix lock + assertion set** — still UNV. One build, one
  load, one `readback_tile`. Also acceptance for upstream's computed PLL
  LKTABLE on zynq7.
* **Upstream-HEAD acceptance run** — rebase, rebuild, `fasm_audit`, one MMCM
  build, assertion set. Verifies TABLE/FILTREG/POWER_REG/Z_ZHOLD choices on
  zynq7 silicon (upstream verified them only against VC707 goldens).
* **Per-attribute readback sweep** — the parity certificate. Enumerate the
  emitter-supported attribute space (all 7 CLKOUTs, odd/even divides, phases,
  3 BANDWIDTHs, frac on CLKOUT0/FB), predict bits from segbits, build few
  dense designs, assert each. This generalises the 209-assertion set from
  "the one design we ship" to "the attribute space we claim".
* **Functional oracle** (EMIO GPIO counter, HANDOFF steps 2–3) — upgrades
  every claim from "bits land where prjxray says" to "the output frequency is
  the commanded one". Also the only oracle that survives the dead fabric AXI.
* **Dark-bit confidence** — more distinct Vivado-legal configurations through
  the assertion path; every one that shows 0 unexplained set bits tightens
  "Vivado never writes the undocumented 2,614". (DRP falsification first if
  the naming campaign is wanted; it is not parity-gating.)

## Ledger 4 — upstreaming. Zero of seven filed

`fix/cmt-zinv-polarity` plus six others sit on topic branches, deliberately
kept one-commit-filable, none filed. For "openXC7 enablement" this ledger is
the whole point: parity achieved on one bench and not upstreamed enables
nobody. Order of filing: cmt-zinv-polarity first (bit-level silicon evidence
in hand, upstream actively working the area, bug present at HEAD), then
ilogic-iffdelmux and iserdes-ofb-tieoff (same defect shape, same evidence
style), then bram-x9-parity-guard, idelay-requires-idelayctrl (DRC), and the
router items.

## What parity does NOT include, stated so the claim stays honest

* PHASER/IN_FIFO/OUT_FIFO/PMV tiles — not user-visible in Vivado, no bit
  space in tilegrid, excluded.
* The clock-router seed lottery (38% route rate, arch.cc:1840) and the CE
  routing defect — these gate *usability* of openXC7, not CMT parity, and are
  tracked separately.
* GCAPTURE-based dynamic verification — measured dead on this setup; the EMIO
  oracle replaces it.

## The ordered list (falsification cost, cheapest first)

1. **File the ZINV PR** — package ready (ZINV_PR.md): applies clean and
   builds at upstream HEAD, silicon evidence in hand. Desk only; highest
   community value per hour. (The rebase step dissolved: base already
   contains upstream's CMT work, 18-commit delta touches nothing relevant.)
2. **Refresh `stable-backports` to HEAD at leisure, rebuild ourfork** — no
   CMT interaction; do it whenever the next nextpnr change is needed.
3. **PLLE2 silicon acceptance** — one build, one read; closes the last UNV hard block.
4. **Emitter rows 1/2/6 (duty, cascade, startup_wait) + DRC rows 10/11** — desk + readback acceptance; each is a self-contained upstreamable commit.
5. **Per-attribute readback sweep** — the parity certificate artifact.
6. **EMIO functional oracle** — unlocks frequency-level claims and the `:functional` strategy for dark bits.
7. **DRP premise falsification, then the dark-bit campaign** — optional beyond parity; do only if naming the 2,614 is a goal in itself.

After 1–5, the claim "zynq7 CMT at Vivado-parity for MMCME2_ADV/PLLE2_ADV
static configuration, silicon-verified without vendor tools" is defensible.
6 upgrades it to functional parity. 7 goes beyond what Vivado's own users
get.
