# PR package: fix/cmt-zinv-polarity → openXC7/nextpnr-xilinx

Verified in a clean sandbox 2026-08-02: commit b7345b5's diff applies without
fuzz to upstream HEAD c13fcbf and the full xilinx arch builds to 100%
(`cmake -DARCH=xilinx`, gcc 13, Release). Upstream's 18 commits since your
base touch none of fasm.cc / pack_clocking_xc7.cc / pins.cc.

## Filing commands (do NOT rebase your existing branch — cherry-pick to a new one)

    cd ~/src/openxc7/nextpnr-xilinx
    git fetch origin
    git checkout -b pr/cmt-zinv-polarity origin/stable-backports
    git cherry-pick b7345b5                      # verified clean at c13fcbf
    gh repo fork openXC7/nextpnr-xilinx --remote=fork
    git push fork pr/cmt-zinv-polarity
    gh pr create --repo openXC7/nextpnr-xilinx --base stable-backports \
        --head <your-gh-user>:pr/cmt-zinv-polarity \
        --title "$(sed -n 's/^## Title: //p' ~/src/nervezynq/ZINV_PR.md)" \
        --body-file /tmp/pr_body.md

`fix/cmt-zinv-polarity`, `stable-backports`, `ourfork` and all backups stay
untouched. (Upstream's default branch IS `stable-backports` — that is the PR
base.)

## Title: xilinx: fix inverted ZINV_RST/ZINV_PWRDWN polarity on MMCME2_ADV/PLLE2_ADV

## Body (copy below this line into /tmp/pr_body.md)

---

`write_pll()` and `write_mmcm()` emit the CMT's invertible-pin bits
un-negated, under a comment that has been in the tree a long time:

    // FIXME: should be INV not ZINV (XRay error?)

It is not an XRay error. `ZINV_*` is prjxray's Z-inverted encoding — the bit
is SET when the pin is NOT inverted — and `fasm.cc` already writes
`!IS_x_INVERTED` for every other ZINV feature it emits: ILOGIC/OLOGIC
`ZINV_D`, `IFF.ZINV_C`, `IFF.ZINV_OCLK`, `ZINV_T1`, `ZINV_ODATAIN`, BUFGCTRL
`ZINV_CE0/S0`, BUFHCE `ZINV_CE`, and the RAMB `ZINV_` loop. The two CMT
writers are the sole exception. (`INV_CLKINSEL` on the next line is a
genuinely INV-encoded bit — note the name — and was always correct, which is
presumably what produced the FIXME.)

Consequence: with RST at its normal inactive level and not inverted, the
un-negated form leaves `ZINV_RST` clear, which inverts RST, so the CMT sees
reset asserted forever and LOCKED can never rise. Whether a given design
locks then depends on whether the netlist happens to set `IS_RST_INVERTED` —
i.e. the error inverts the *intent* in every case, which is why CMTs under
the open flow have appeared to work for some netlists and not others.

This patch negates the four CMT ZINV writes (`ZINV_RST`, `ZINV_PWRDWN`,
`ZINV_PSEN`, `ZINV_PSINCDEC`) to match the rest of the file.

### Hardware evidence (xc7z020clg400-1, LibreSDR; no vendor tools anywhere in the loop)

Paired A/B against the SAME routed design — the two features appended to an
already-routed `.fasm`, so control and candidate differ by exactly bits
`28_111` and `29_111`:

    control (as routed)      LOCKED 0    CLKOUT0     0 ticks     0.000 MHz
    + ZINV_RST/ZINV_PWRDWN   LOCKED 1    CLKOUT0 19784 ticks    99.919 MHz

End-to-end through the patched flow on a different seed (also exercising the
predicted feature swap in the emitted FASM — `ZINV_PSEN`/`ZINV_PSINCDEC` out,
`ZINV_RST`/`ZINV_PWRDWN` in):

    seed 3, full flow        LOCKED 1    CLKOUT0 19784 ticks    99.986 MHz

99.9 MHz is `CLKFBOUT_MULT_F=10 / CLKOUT0_DIVIDE_F=5`, so the MMCM is
genuinely multiplying, not merely reporting a lock bit.

Bit-level confirmation via PCAP configuration readback of the running
device: comparing pre-fix and post-fix builds across **all 30 frames** of
`CMT_TOP_L_LOWER_B_X178Y61` (3030 words, device-computed ECC word excluded),
exactly two bits differ:

    minor 28, word 3   0x00004000 -> 0x0000C000   bit 111
    minor 29, word 3   0x00004000 -> 0x0000C000   bit 111

named by prjxray zynq7 as `MMCME2_ADV.ZINV_PWRDWN` (28_111) and
`MMCME2_ADV.ZINV_RST` (29_111), both going clear→SET. The patch's entire
effect on the tile's configuration memory is those two documented cells.

Additionally, the post-fix bitstream was checked against the zynq7 segbits
database bit-for-bit on silicon: 209 assertions (206 must-be-1, 3 must-be-0),
0 disagreements, 0 unexplained set bits in the tile. Since that build was
emitted through current `write_mmcm()`, this also silicon-verifies the
golden-derived LKTABLE / TABLE / FILTREG1 / POWER_REG / `COMP.Z_ZHOLD`
values on a zynq7, complementing the VC707 golden comparisons already cited
in the source.

Scope note: `ZINV_PSEN`/`ZINV_PSINCDEC` are negated on the same encoding
argument; the test design does not exercise fine phase shift, so those two
rest on consistency with the other 200+ ZINV features rather than a direct
silicon A/B.

---

## After filing

* Mark `fix/cmt-zinv-polarity` as filed in BRANCHES.md via rebuild-ourfork.sh
  (it regenerates; update the "None filed upstream yet" line in the script's
  heredoc).
* Queue next: `fix/ilogic-iffdelmux` and `fix/iserdes-ofb-tieoff` (same
  defect shape, same evidence style), then `fix/bram-x9-parity-guard`,
  `fix/idelay-requires-idelayctrl`, and the router pair.
