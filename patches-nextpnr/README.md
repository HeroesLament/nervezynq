# nextpnr-xilinx CMT emitter patches — 2026-08-02 session

Four `git am`-able patches closing rows 1/4/6/10 of the CMT_PARITY_GAP.md
emitter table. All verified in a clean sandbox against upstream HEAD c13fcbf
(identical file content to `stable-backports` 62839b3 for every touched
region): each applies clean, each builds, and the full set merges
conflict-free **alongside `fix/cmt-zinv-polarity`** in any order — the
STARTUP_WAIT insertion point was chosen away from the ZINV lines
specifically so ourfork's octopus rebuild stays clean. The integration of
all five builds to 100%.

    0001  CLKOUT*_DUTY_CYCLE on MMCM+PLL counters      (gap row 1)
          duty=0.5 reduces bit-exactly to the old floor(divide/2) behaviour,
          so every existing design emits identical FASM.
    0002  refuse fractional divides on PLLE2_ADV        (gap row 10, DRC)
    0003  emit STARTUP_WAIT                             (gap row 6)
    0004  POWER_REG 0xFFFF when FRAC in use             (gap row 4)

## Suggested topic-branch layout (fits rebuild-ourfork.sh rules: ≤3 commits each)

    cd ~/src/openxc7/nextpnr-xilinx
    git checkout -b fix/cmt-clkout-counters stable-backports
    git am 0001-*.patch 0002-*.patch
    git checkout -b fix/cmt-startup-wait stable-backports
    git am 0003-*.patch
    git checkout -b fix/mmcm-frac-power-reg stable-backports
    git am 0004-*.patch

then add the three branches to TOPICS in scripts/rebuild-ourfork.sh and
re-run it. Nothing here touches your existing branches.

## Verification status, honestly

* Sandbox: compile only, plus merge-matrix. NO nextpnr run (no chipdb here),
  NO silicon.
* 0001 at duty=0.5 and 0002/0003 with default attributes are FASM-no-ops by
  construction — `regress.sh` should show byte-identical output for the
  radio design; that is the cheap first check.
* Silicon acceptance owed, per patch:
  - 0001: one build with e.g. CLKOUT1_DIVIDE=10, CLKOUT1_DUTY_CYCLE=0.3 →
    readback: HIGH_TIME=3, LOW_TIME=7, EDGE=0 per segbits.
  - 0003: readback of the STARTUP_WAIT bit; the hold-DONE behaviour also
    interacts with COR0 LOCK_CYCLE (not modelled — noted in-source).
  - 0004: a fractional build (e.g. CLKFBOUT_MULT_F=10.125) locking, plus
    readback of POWER_REG[15:0]=0xFFFF. XAPP888-derived; no golden checked.
  - 0002 is refusal-only; a non-integer PLL divide must now fail the build.

## Still open from the gap table (not attempted, reasons)

* CLKOUT4_CASCADE (row 2): needs the MX field semantics; I was not confident
  of the encoding without a golden or a DRP experiment, and a guessed MX
  value on silicon is exactly the class of confident-wrong this project
  keeps burning power cycles on. The honest path: one EMIO-oracle experiment
  with MX swept over its 4 values, or a borrowed Vivado golden.
* Fine phase shift / USE_FINE_PS (row 3), SS_EN (row 7), COMPENSATION
  BUF_IN/EXTERNAL (row 8), CLKIN2/dynamic CLKINSEL (row 9), VCO-range DRC
  (row 11).
