# RF first light: two-board over-the-air link at 2.4 GHz

Session 2026-09-23 evening into 2026-09-24 morning. First transmission from
this project, first two-board measurement, first carrier frequency offset
(CFO) number between two LibreSDRs.

## Result

| Item | Value |
|---|---|
| TX board | `nerves-dr-a` (`lsdr-a`), AD9363 BIST tone at the TX control point |
| RX board | `nerves-dr-b` (`lsdr-b`), `SDR.open` defaults: 2.412 GHz, 8 Msps, 40 dB |
| TX LO | 2,412,999,998 Hz (programmed and read back; VCO 9.652 GHz, div 1) |
| RX LO | 2,412,000,000 Hz (read back) |
| Tone | BIST index 0 = Fs/32 = 250 kHz above TX LO |
| TX attenuation | 30.0 dB, both channels (read back) |
| Band | 2.4 GHz ISM, antennas, boards on one bench |
| Tone at RX | -6.5 dBFS, 69.9 dB above the median noise bin (1020-pt DFT) |
| **CFO** | expected 1,249,998 Hz, measured **1,244,237.8 Hz**, delta **-5,760.2 Hz = -2.387 ppm** (dr-a relative to dr-b) |
| CFO fit | 32,768-frame gapless HP0 DMA capture (4.096 ms, 0 SEQ holes), phase residual 0.0152 rad RMS over 1,024 decimated points: statistical uncertainty ~0.1 Hz |

## Spectrum while keyed (1020-point Hann DFT, ~7.8 kHz bins)

| Component | Predicted | Measured | Level |
|---|---|---|---|
| Tone | +1,250,000 | +1,243,808 | -6.5 dBFS |
| Image (TX LO - Fs/32) | +750,000 | +745,098 | -25.9 dBFS (-19.4 dBc) |
| TX LO leakage | +1,000,000 | +996,078 | -28.4 dBFS (-21.9 dBc) |
| RX DC | 0 | 0 | -32.6 dBFS (baseline -33.0) |

Image and LO leakage near -20 dBc are what an uncalibrated TX quadrature
path gives: `ad9361_tx_quad_calib()` is not transcribed yet. The tone at
-6.5 dBFS means the receiver is near compression with the boards this close;
use less RX gain or more TX attenuation for cleaner measurements.

Baseline (dr-a silent): nothing above 13 dB over the noise except RX DC.

## How the CFO was measured

`ocusync/tools/cfo.exs` on the Mac. Every spur sits at a multiple of Fs/32
from the tone (image -2, LO leakage -1, RX DC -5). Mixing the tone to 0 Hz at
its nominal offset and averaging in blocks of 32 samples puts a boxcar null on
every multiple of Fs/32, so all spurs cancel. The residual frequency is the
least-squares slope of the unwrapped phase of the block averages.

-2.4 ppm is a single pair at one temperature. OFDM carrier recovery budget
should assume the AD9363 reference tolerance, not this number.

## New code

| Path | What |
|---|---|
| `nervezynq/scripts/tx_tone.exs` (+ `taps/serve`) | `Nervezynq.TxTone`: `set_tx_lo/2`, `set_tx_atten/1`, `key/1`, `unkey/0`, `burst/2`. TX synth = RX synth block + 0x40, transcribed from no-OS `ad9361_rfpll_vco_init` / `ad9361_set_tx_atten` |
| `ocusync/tools/peaks.exs` | host-side windowed DFT peak list from a `rx_binary` dump |
| `ocusync/tools/cfo.exs` | host-side CFO from an HP0 `capture_burst(..., decode: false)` dump |

`SDR.open` already powers and CP-calibrates both synthesisers and enables TX;
it only ever tunes the RX LO. `TxTone.set_tx_lo/2` is the missing TX half.

## Board identity changes (same session)

- Both cards burned with `NERVES_SERIAL_NUMBER` (`lsdr-a`, `lsdr-b`). Hostnames
  `nerves-dr-a` / `nerves-dr-b`, VintageNetDirect subnets derived from them:
  dr-a 172.31.104.113 (Mac .114), dr-b 172.31.29.213 (Mac .214). The old
  fixed 172.31.248.125 no longer holds.
- `rootfs_overlay/usr/bin/usb-gadget-init` derives the ECM MACs and the USB
  serial from `boardid` (djb2 over the serial, 16 bits into
  `02:1a:35:HH:LL:22/23`). Before this, two boards on one Mac got one ECM
  interface between them. Firmware `6fb5359d`.
- `6fb5359d` also carries the post-`8b8c1a21` `pl.ex` / `lvds_probe.ex`
  changes, now running as firmware for the first time. Bring-up, `selftest`
  and HP0 DMA were all normal on it.
- Card 1's prior image is backed up at
  `nervezynq/boot-backup-20260923-card1/card1-first352M.img` (+ SHA256SUMS).

## Incidents, and the rules they produce

1. **Board-side compute over ssh exec outlives the client.** Two O(n^2) DFTs
   run in `ssh <board> '<expr>'` and interrupted with Ctrl-C kept running on
   dr-b, saturating both A9 schedulers; a trivial eval then took 61 s.
   Rule: boards dump raw samples, all analysis runs on the Mac.
2. **An interrupted ssh chain can leave a carrier up.** Key, capture, unkey as
   three separate ssh commands: the capture stalled on the loaded dr-b, and
   dr-a's ssh wedged (banner-exchange timeout, ping fine) while keyed. It was
   unkeyed by the chain eventually; both boards were power-cycled.
   Rule: use `TxTone.burst/2`, which unkeys on the TX board itself after a
   fixed time, never key/unkey as separate remote commands.
3. **dr-a hung once while idle**, ~20 min after boot, no bitstream loaded,
   nothing sent to it. Ping and ssh both dead; USB gadget still enumerated.
   After the power cycle its ssh host key had changed: `/data` came back
   empty, i.e. reformatted at boot. Cause unknown. If it recurs on dr-a only,
   suspect that card.
4. **Typing into a pane with a running command** feeds it to that command's
   stdin (a stdin-reading `grep` once, an `ssh` once). Only send to a pane
   once it is idle.
5. **`hello` atom decode failure** in `OcuSync.Link`: the host rejected board
   messages under `binary_to_term(..., [:safe])` because the shared modules'
   atoms were not loaded on the host. Fixed by loading them in `Link.init/1`.
   The Sim could not show this.

## TX quadrature calibration: converges, no measurable effect on the BIST tone (resolved 2026-09-26, below)

2026-09-24 morning, `TxTone.quad_cal/1` (transcribed `ad9361_tx_quad_calib` + phase search + `find_opt`),
dr-a TX LO 2.413 GHz, cal at 30 dB attenuation:

- CLKRF = CLKTF = 8 MHz, TX/RX NCO word 3 (1 MHz = BW/4, so no filter recal needed), decim 3,
  LPF/TIA match gain-table row 37.
- ADI's predicted RX phase 0x15 did not converge (`first_status 0`). The 32-phase search found one clean
  8-phase window, `###########oooooooo####...`, phases 11..18; phase 15 used. LO and SSB both converged.
- TX1 Out 1 corrections after cal: phase 197, gain 228, offset I 237, offset Q 241. Out 2 set all zero.

Over-air result, same setup before and after (3 s `burst`, 1020-pt Hann DFT on dr-b):

| | Pre-cal | Post-cal |
|---|---|---|
| Tone | -7.2 dBFS | -7.3 dBFS |
| Image (+745 kHz) | -14.8 dBc | -15.4 dBc |
| LO leakage (+996 kHz) | -18.4 dBc | -18.6 dBc |

No change beyond ~0.5 dB. Not yet explained. Candidates, neither tested:

1. The BIST TX injection point (`BIST_CTRL_POINT(0)`) is downstream of the quadrature-correction block,
   so a BIST tone cannot show the correction at all. no-OS does not say where it injects.
2. The correction set actually applied at this attenuation is not the one the cal reports (Out 1 vs Out 2,
   `REG_TX_FORCE_BITS` 0x09F).

A direct test (perturb the correction registers, watch LO leakage move) failed: in ALERT, writes to
0x092 return `:ok` but read back unchanged, so the registers hold the cal engine's values and a plain write
does not override them. The decisive test is real baseband through the fabric TX path, not a BIST tone.

## First fabric-sourced RF: DDR ring -> TX, and the quad cal resolved (2026-09-26 evening)

dr-a (`txdma_s25.bin`) keyed from its DDR TX ring, dr-b (`hp_dma_s1.bin`) receiving, same bench,
antennas and plan as the first-light session: TX LO 2,412,999,998 Hz, RX LO 2.412 GHz, 8 Msps,
TX 30 dB both channels. Ring = complex tone +Fs/32 (4096 cycles per 131072-frame ring, peak 1024 =
-6 dBFS, I = cos, Q = sin), TX2 zero, cyclic. `TxLoop.dma_burst/2` (board-side bounded burst,
TxTone.burst/2's rule) vs `TxTone.burst/2` (BIST tone, same offset) in the same minute; one 1020-frame
dr-b capture per burst, `ocusync/tools/peaks.exs` on the Mac (`ocusync/tools/rf_dma.sh <tag>` runs the
whole sequence). DMA underflow 0 in every burst.

| dBFS at dr-b (dBc re its own tone) | BIST | DDR, 0x007 = 0x00 | DDR, 0x007 = 0x08 | DDR, after quad cal (x2) |
|---|---|---|---|---|
| Tone +1.247 MHz | -8.2 | -18.3 | -15.3 | -15.4 / -15.4 |
| Image +745 kHz | -22.9 (-14.7) | -25.5 (-7.2) | -49.4 (-34.1) | -52.2 (-36.8) / -51.6 (-36.2) |
| LO leakage +996 kHz | -26.5 (-18.3) | below -31 | -41.7 (-26.4) | -47.3 (-31.9) / -47.9 (-32.5) |
| Spurs at TX LO +-2.0, -2.25 MHz | none | -28 to -30 | none | none |
| Noise median (baseline -76) | -74 | -70.3 | -75.9 | -75.6 / -75.8 |

1. **The tone is where it should be:** +1,244,0xx Hz, i.e. positive frequency (I = cos, Q = sin is the
   chip's convention) with the same -2.4 ppm CFO as first light.
2. **REG_TX_CLOCK_DATA_DELAY matters on air, not just in loopback.** At the boot value 0x00 the corrupted
   falling-edge (Q) words show as a -7 dBc image, spurs at +-Fs/4 around the TX LO and a 5 dB higher
   floor. `TxLoop.gate/1` and `dma_gate/1` restore 0x007 to what it was (0x00 on current firmware);
   `dma_burst/2` now sets 0x08 and leaves it. The firmware default change (`AD9363.data_port_setup`,
   0x00 -> 0x08) is written but not burned yet.
3. **The BIST tone's image is the BIST's own, not TX quadrature error.** Through the same uncalibrated
   analog path, in the same minute, the fabric tone's image is -34 dBc where the BIST's is -15 dBc. That is
   candidate 1 above, confirmed: a BIST tone cannot measure the TX quadrature path.
4. **The quad cal works.** Rerun on dr-a (converged, corrections phase 198, gain 229, offsets 237/241, within
   one LSB of 2026-09-24), the fabric tone's LO leakage drops ~6 dB (-26.4 -> -32 dBc) and its image ~2.5 dB
   (-34.1 -> -36.5 dBc), reproduced on two bursts. BIST tone unchanged, as before. Pre-cal is a single
   capture; the post-cal pair agrees within 0.6 dB.

Still open: whether ~-32 dBc LO leakage / ~-36 dBc image is this pair's floor or the cal's (offset
correction resolution, cal at a different NCO than the test tone, TX2 leakage adding at the RX antenna).
TX2 is transmitting its LO too (zero data, 30 dB): a test with TX2 at 89.75 dB separates the two.

## TX data port: FPGA -> AD9363 LVDS, validated by data-port loopback (2026-09-26, dr-a)

Fabric: ehdl `LibreSDRRadio.Top` + `Hw.AD936xTxPort` -> eight `ODDR` (SAME_EDGE)
-> `OBUFDS`, bitstream `hp_dma_tx_s25.bin` (seed 25, first try; FASM checked:
eight OLOGIC sites with `ODDR.DDR_CLK_EDGE.SAME_EDGE` + `DATA_RATE_OQ.DDR`,
nothing silently dropped). Pins from zynqsdr_rev5.pdf p16 (U2C), all bank 34:
FB_CLK N18/P19, TX_FRAME Y16/Y17, TX_D0..5 W14/Y14 T12/U12 U14/U15 T16/U17
V12/W13 V15/W15. The same page confirms RX_D1_N = V18 (previously inferred).

Method: no RF. REG_OBSERVE_CONFIG (0x3F5) bit 0 loops the AD9363's TX data
port into its RX data port (transcribed from no-OS `ad9361_bist_loopback()`
mode 1; `fix_ch_cross` is a no-op in 2R2T). The fabric sends a per-frame
pattern (I1 = ctr, Q1 = ~ctr, I2 = ctr halves swapped, Q2 = 0xA5C) and the
proven RX capture path scores every field of every frame
(`scripts/tx_loop.exs`, `Nervezynq.TxLoop`).

Findings, in the order they cost time:

1. **The loopback needs FDD.** ENSM RX: loopback reads constant 0xFFF. ENSM
   ALERT or TDD TX: one 6-bit word, frozen, replicated on every edge (the TX
   input and the RX output of the port do not both run). Only FDD passes data.
2. **FDD mode must be selected from ALERT.** `set_mode(true)` issued while in
   TDD RX, then `set_state(:fdd)`, times out in ALERT. ALERT first, then
   `set_mode(true)`, then `set_state(:fdd)` reaches 0xA, and only then does
   the TX VCO report lock (0x287 = 2). `TxLoop.fdd_enter/0` encodes the order.
3. **The edge order was right; the timing was not.** With REG_TX_CLOCK_DATA_DELAY
   (0x007) = 0x00, data and FB_CLK launch on the same ODDR edge and one edge
   polarity's words arrive mixed with their neighbours. A 256-cell sweep of
   0x007 (`TxLoop.eye/2`, default order, no swaps, FB_CLK not inverted) gives a
   diagonal plateau of **105/256 fully correct cells**, bounded below by
   `data_delay - fb_clk_delay >= 2` and extending to the register limit.
   **0x08** (FB_CLK 0, data 8): 5 x 1000 frames, every field of every frame
   correct. Now the default in `AD9363.data_port_setup/1` (takes effect with
   the next firmware; scripts write 0x007 until then).

`TxLoop.gate/1` is the regression: guarded (unlinked restore after 30 s),
transmitter at 89.75 dB attenuation throughout, 3 x 1000 frames at 0x08, then
restores 0x007 and ALERT/TDD/RX. Passed on dr-a.

Not yet done: the TX port is fed by a test pattern, not by the HP0 reader;
the forwarded FB_CLK's delay margin at other sample rates is unmeasured (the
plateau was taken at DATA_CLK 32.004 MHz, 8 Msps).

## Next

- DONE 2026-09-26: the two halves are joined (ehdl e21fa32). DDR TX ring
  `0x3FD0_0000` -> HP0 reader -> dual-clock BRAM FIFO -> `Hw.AD936xTxPort`,
  EMIO bank 2 [8] source, [9] enable, [10] cyclic, [11] run, bank 3 head.
  Silicon (`txdma_s25.bin`, `TxLoop.dma_gate/1`): marked DDR frames through
  the data-port loopback, 3 x 1000 all correct and +1-continuous, underflow
  0 at 8 M frames/s with the 1 MB ring wrapping.
- DONE 2026-09-26 evening: first fabric-sourced RF, and the quad cal
  question closed (section "First fabric-sourced RF" above).
- DONE 2026-09-26 21:30: a modulated waveform from the ring. OcuSync PHY v0
  (OFDM, 64-FFT) frames decoded over the air dr-a -> dr-b, QPSK 16/16 CRC-clean,
  EVM -20.4 dB. Details in notes/ocusync/02-phy.md "As built".
- Next: TX2 attenuated separately (LO leakage split) and dr-b RX quad cal,
  both aimed at the ~-22 dB EVM floor.
- Incident 3 (dr-a): `/data` was reformatted on two consecutive hard power
  cycles; dr-b's survived both. Suspect dr-a's card or data partition.
