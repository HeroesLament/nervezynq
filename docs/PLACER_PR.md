# PR package: fix/postplace-controlset-repair → openXC7/nextpnr-xilinx

Two commits, one defect: mixed-clock slices ship to the router as legal
placements. NOT yet sandbox-verified against upstream HEAD (the ZINV_PR.md
step that must run before filing): cherry-pick both commits onto
origin/stable-backports in a clean tree and confirm the xilinx arch builds
before opening the PR.

HOUSE RULE GATE: not filed until the radio decodes on silicon through a
bitstream from the fixed toolchain (deg_per_sample 11.25 / mag_cv ~3e-4,
Gates A+B of STREAM_RX_SESSION.md). Toolchain-level evidence is complete;
silicon evidence is pending as of 2026-08-03.

## Filing commands (after silicon; do NOT rebase the existing branch)

    cd ~/src/openxc7/nextpnr-xilinx
    git fetch origin
    git checkout -b pr/postplace-controlset-repair origin/stable-backports
    git cherry-pick 152c415 3fe5e76      # threshold fix first, then detection
    gh repo fork openXC7/nextpnr-xilinx --remote=fork
    git push fork pr/postplace-controlset-repair
    gh pr create --repo openXC7/nextpnr-xilinx --base stable-backports \
        --head <your-gh-user>:pr/postplace-controlset-repair \
        --title "$(sed -n 's/^## Title: //p' ~/src/nervezynq/PLACER_PR.md)" \
        --body-file /tmp/pr_body.md

## Title: xilinx: stop mixed-clock slices escaping placement validation

## Body (copy below this line into /tmp/pr_body.md)

---

A 7-series slice has exactly one clock input. A slice packed with FFs from
two different clock nets is therefore unroutable by construction: the clock
pre-router finds the CLK site wire held by the other net with no alternative
(the sink is inside the site), and the general router cannot reach a SLICE
clock pin through fabric at all. The resulting error —

    ERROR: Failed to route arc N of net '<clk>',
           from SITEWIRE/BUFGCTRL_XxYy/O to SITEWIRE/SLICE_XxYy/CLKINV_OUT

— names the router, but the placement was illegal before routing began.

Two holes let such slices through:

1. `xc7_logic_tile_valid()`'s fully-frozen fast-path returns valid with no
   checks when every occupied bel is bound at `belStrength >=
   STRENGTH_STRONG`. Its own comment states the intended marker ("frozen ==
   stamped: bound STRENGTH_USER by the BEL-attr placer"), but the heap
   legaliser's chain path binds every ordinary LUT+FF cluster with
   STRENGTH_STRONG — so any tile populated entirely by chain-placed user
   logic was never validated at all, control sets included. The legaliser's
   own `isBelLocationValid()` calls hit the fast-path and returned true
   without looking. Fixed by requiring STRENGTH_USER.

2. `fixupPlacement()`'s validity-repair pass collected stranded cells via
   `isValidBelForCell(cell, its-own-bel)` — a static per-cell gate that
   cannot see conflicts BETWEEN cells. Detection is extended to tile level
   (`isBelLocationValid` on each member's bel); the existing relocation
   machinery already re-verifies destination tiles on every member after
   trial-binding, so it needed no change. Tiles the pass cannot legalise
   (carry chains, BEL-stamped imports) are now named loudly instead of
   failing later in the router with the misleading arc error.

### Evidence (xc7z020clg400-1, LibreSDR; no vendor tools in the loop)

A two-clock SDR design (LVDS DDR capture domain + AXI domain) at three
sizes, same toolchain, same day, netlists held constant per sweep
(deterministic elaboration):

    before                          after
    stream netlist   0/368 seeds    20/20 seeds routed
    (three FIFO variants: 46+121+201)
    control netlist  ~1/9 seeds     9/9 seeds routed

Every pre-fix failure was a clock arc into a SLICE CLKINV_OUT. With
`--debug`, each failing arc's backward search reports exactly ONE candidate
wire, `SITEWIRE/SLICE_XxYy/CLK`, "used by net <the other clock>" — and the
placer log confirms FFs of both clocks assigned to that slice (e.g.
SLICE_X30Y107: AFF/BFF/B5FF on data_clk, A5FF on axi_clk). Post-fix, the
post-place audit reports zero invalid tiles and fasm_audit over the routed
result examines 5491 emitted features with 0 undocumented emissions.

The "seed lottery" this design suffered (1 routed seed in 377 on an earlier
revision) is fully explained: a seed routed iff its placement happened to
leave no slice mixed-clock. Growth of either clock domain raised the
collision count and the lottery collapsed to 0 — presenting as a router
capacity cliff.

What is NOT claimed: that the clock router is defect-free. Its net-at-a-time
routing with no rip-up is real (see companion branch
fix/clock-router-arc-interleave, which routes clock arcs round-robin across
nets); on this design it was measurably not the cause — with interleaving
alone, failures persisted and merely redistributed between the two nets
(14/6 vs always-the-second), and with the placement fixed, both the
interleaved and the original router route 20/20.

---

## After filing

* Mark `fix/postplace-controlset-repair` as filed in BRANCHES.md via
  rebuild-ourfork.sh.
* `fix/clock-router-arc-interleave` is separable and optional: a hygiene
  improvement (starvation → sharing) with honest evidence that it does NOT
  fix this defect alone. File only with that framing, or hold until a design
  that genuinely exhausts clock leaf capacity exists.
* `wip/clock-router-retry-DISPROVEN` stays as-is — its measurement was
  correct: no amount of retry fixes an illegal placement.
