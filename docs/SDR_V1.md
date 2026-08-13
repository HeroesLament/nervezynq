# Nervezynq.SDR V1 — basic SDR functionality, up on silicon

Session 2026-08-02, board `lottery-lab`, bitstream `hp_dma_s0.bin`
(libresdr_radio + HP0 DMA, seed 0). A bladeRF-shaped Elixir facade over the
proven AD9363 + LVDS + MIMO stack. Hot-loaded, no firmware rebuild. All
results below are measured on the board this session.

## The API (file: nervezynq/scripts/sdr.exs, served as taps/serve/sdr.exs)

    Nervezynq.SDR.open(frequency:, sample_rate:, gain_db:)  -> {:ok, state}
    Nervezynq.SDR.set_frequency(hz)                          -> {:ok, %{lo: ...}}
    Nervezynq.SDR.set_sample_rate(hz)                        -> re-runs clock+analog
    Nervezynq.SDR.set_gain(db) / set_gain_mode(:mgc)
    Nervezynq.SDR.enable(:rx | :alert | :fdd)
    Nervezynq.SDR.rx(n)          -> {:ok, %{ch1: [{i,q}], ch2: [{i,q}], ...}}
    Nervezynq.SDR.rx_binary(n)   -> interleaved s16 IQ, ch1
    Nervezynq.SDR.selftest()     -> BIST known-answer, {pass: bool, ...}
    Nervezynq.SDR.status()       -> ENSM, LO, VCO lock, DATA_CLK
    Nervezynq.SDR.close()        -> ENSM to ALERT

## Verified this session

    open(2.412 GHz, 8 Msps, 40 dB)
      data_clk_mhz 32.01, data_clk_agrees true
      (predicted from ADI divider table == measured by fabric edge counter)

    selftest()  (Fs/32 BIST tone, the known-answer gate)
      pass: true
      ch1 & ch2: deg_per_sample 11.25, mag_cv 3.4e-4, mag_mean 2047.8
      — the exact textbook decode; matches every prior good capture

    rx(1000)  (live RF, BIST disabled, real antenna energy)
      1000 sample pairs/channel, ch1 mag_mean 71, DC term -40
      — a working UNcalibrated receiver: the DC offset is the untranscribed
        DC cal the Bringup moduledoc warns about, present as predicted

    set_frequency(2.437 GHz)   VCO relocked, actual_hz 2436999999 (1 Hz off)
    set_gain(20)               band 1 index 25, actual 20 dB
    rx(256) after retune       256 pairs, rx_locked true

## The one fix this shook out

`MIMO`'s `@fabric_needs_nibble_swap` default predates the fabric sample-order
fix (HANDOFF remaining-work #1, `sample_a = {rise_q_d, rise_q}`), which THIS
bitstream carries. So the correct setting for this build is
**nibble_swap: false**, proven directly:

    nibble_swap false -> 11.25 deg, cv 3.4e-4, |z| 2047   (correct)
    nibble_swap true  -> 62 deg,    cv 0.376,  |z| 1714   (wrong)

The driver pins `@nibble_swap false` and passes it explicitly to every
decode rather than trusting the module default. When MIMO's default is
updated to match the shipped fabric, this can drop back to the default —
but pinning it is correct until then, and it is documented in-file with the
measurement.

## What V1 is NOT (all by design, all with a landing spot)

* NOT streaming — `rx/1` is snapshot capture (≤1020 pairs, gapless within a
  capture, dead time between). The HP0 DMA engine is proven
  (HPDMA_SESSION.md) and is the V2 path; it needs the sample-pack + FIFO
  fabric revision, then lands as `stream_rx/2`.
* NOT lab-calibrated — no DC-offset or quadrature-tracking cal yet. Signals
  are real; absolute numbers are not trustworthy. Transcribing ADI's cal
  steps is the quality lever.
* NOT TX — no fabric TX path exists (O-side campaign).

## Standing platform note baked into open/1

`open/1` releases the FCLK throttle (SLCR THR_CNT, the 2026-08-02 root cause
of "dead" fabric AXI), refreshes the Fabric guard, and proves the magic
register before touching the radio — all idempotent. After a reboot,
`open/1` is the entire bring-up ritual from a cold IEx (after the usual
inets + compile + Devcfg/DmaBuf bootstrap).

## Next, in order

1. Update `MIMO.@fabric_needs_nibble_swap` (or make it a runtime capability
   probe) so the pin in the driver becomes redundant.
2. `stream_rx/2` over HP0 DMA — the V2 milestone, and where the beacon-depth
   capture the SDR plan needs actually comes from.
3. DC-offset + quadrature cal for a spectrum worth trusting.
4. A GenServer wrapper so the driver survives as owned process state rather
   than an Agent — natural once it's compiled into the firmware image
   instead of hot-loaded.
