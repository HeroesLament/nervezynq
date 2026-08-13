defmodule Nervezynq.AD9363.Bringup do
  @moduledoc """
  End-to-end receive bring-up: reset through to the ENSM sitting in RX with the
  LVDS data port transmitting.

  This is `ad9361_setup()` (ad9361.c:5348) with the RF calibrations left out.
  That omission is deliberate and bounded: the calibrations affect *signal
  quality*, not whether the data port runs, and the BIST injects at the digital
  receive control point — downstream of the mixer, the analogue filters and the
  ADC. So a BIST pattern arriving intact over LVDS proves the digital interface
  regardless of how badly the RF is trimmed. The calibrations are still needed
  before any real signal is received; they are just not on the critical path to
  answering the question the fabric is stuck on.

  What is skipped, and should come back in order of dependency: `auxdac_setup`,
  `gpo_setup`, `set_dcxo_tune`, `auxadc_setup`, `ctrl_outs_setup`,
  `set_ref_clk_cycles`, `setup_ext_lna`, the two synth CP calibrations, both RF
  PLLs, the mixer GM subtable, `gc_setup`, the four filter calibrations,
  `rx_adc_setup`, the three DC-offset and quadrature calibrations,
  `tracking_control`, `set_tx_atten`, `rssi_setup`, `clkout_control` and
  `txmon_setup`.
  """

  alias Nervezynq.AD9363
  alias Nervezynq.AD9363.{Clocks, ENSM, Gain, RFPLL, RxAnalog}
  alias Nervezynq.LVDSProbe

  @doc """
  Bring the receive path up at `sample_rate_hz` and report what the hardware
  says about it.

  The return value pairs the DATA_CLK the clock-chain arithmetic *predicts*
  with the DATA_CLK the fabric independently *measures* through `STATUS2`.
  Those two numbers come from completely separate paths — one from ADI's
  divider table, one from an edge counter in the PL — so their agreement is a
  real check rather than a readback of our own writes.
  """
  def receive_path(sample_rate_hz \\ 4_000_000, opts \\ []) do
    with {:ok, bb} <- AD9363.bring_up(),
         {:ok, pp} <- AD9363.data_port_setup(),
         {:ok, clk} <- Clocks.set_sample_rate(sample_rate_hz, opts),
         :ok <- ENSM.enable_rx(Keyword.get(opts, :rx_channels, 3)),
         :ok <- ENSM.enable_tx(Keyword.get(opts, :tx_channels, 3)),
         :ok <- ENSM.rf_port_setup(Keyword.get(opts, :rx_input, 0)),
         # Powers both synthesisers up. Must precede set_mode/2, which restores
         # TDD after the calibration leaves the chip in FDD.
         {:ok, _} <- RFPLL.synth_cp_calib(:rx),
         {:ok, _} <- RFPLL.synth_cp_calib(:tx),
         :ok <- ENSM.set_mode(false),
         :ok <- ENSM.mask_synth_ready(Keyword.get(opts, :mask_synth_ready, true)),
         {:ok, ensm} <- ENSM.set_state(:rx) do
      measured = LVDSProbe.data_clk_mhz(500)

      {:ok,
       %{
         bbpll: bb,
         data_port: pp,
         clocks: clk,
         ensm: ensm,
         predicted_data_clk_mhz: clk.predicted_data_clk_mhz,
         measured_data_clk_mhz: measured,
         data_clk_agrees: abs(measured - clk.predicted_data_clk_mhz) < 0.1
       }}
    end
  end

  @doc """
  Bring the receive path up on a real RF carrier.

  `receive_path/2` gets the digital interface running with the synthesisers
  powered but **parked at whatever frequency their dividers happen to hold**, and
  the BIST injecting a pattern downstream of the mixer. Everything this project
  has measured so far — the eye, the sample format, `mag_cv = 3.4e-4` — came
  through that path and says nothing at all about the RF front end.

  This adds the minimum needed to put actual antenna energy on the LVDS bus:

    1. `RFPLL.set_ref_clk/2` — program the reference divider. Previously never
       done, so the synthesiser reference was whatever reset left behind while
       `synth_cp_calib/2` assumed 80 MHz.
    2. `RFPLL.set_lo/2` — the LO itself, with the `SynthLUT` analogue tuning.
    3. Disable the BIST, so the digital receive control point carries ADC data
       instead of a generated pattern.

  ## What this deliberately still omits

  ADI's `ad9361_setup()` does considerably more between the LO and valid samples.
  Left out here, with the reason:

    * `load_mixer_gm_subtable`, `gc_setup` + a manual gain index, and
      `rx_adc_setup` are **required** for a correct receiver and are *not yet
      transcribed*. Without them the mixer Gm table is unprogrammed, gain is at
      whatever reset gives, and the sigma-delta ADC is configured for the wrong
      clock. Expect a poor receiver, not no receiver.
    * `rx_bb_analog_filter_calib` and `rx_tia_calib` leave the baseband filter
      corner arbitrary — possibly below the signal.
    * BB/RF DC offset calibration and quadrature tracking are quality items. An
      uncalibrated receiver shows a large DC term and image energy, and still
      shows a signal.

  So this is an instrument for answering exactly one question — *does RF energy
  reach the digital interface at all* — and it is not a receiver. Do not read a
  clean spectrum out of it, and do not conclude the front end is broken from a
  dirty one until the required items above are transcribed.
  """
  def rf_receive_path(lo_hz, sample_rate_hz \\ 4_000_000, opts \\ []) do
    gain_db = Keyword.get(opts, :gain_db, 10)

    with {:ok, base} <- receive_path(sample_rate_hz, opts),
         {:ok, ref} <- RFPLL.set_ref_clk(Keyword.get(opts, :refin_hz, 40_000_000)),
         {:ok, lo} <- RFPLL.set_lo(lo_hz, ref_clk_hz: ref.ref_clk_hz),
         # Order follows ad9361_setup: the mixer Gm sub-table and the band's gain
         # table before any gain index means something.
         {:ok, gm} <- Gain.load_mixer_gm_subtable(),
         {:ok, gt} <- Gain.load(lo_hz),
         {:ok, _} <- Gain.set_mode(:mgc),
         {:ok, gain} <- Gain.set_gain_db(lo_hz, gain_db),
         # Filter calib -> TIA -> ADC, in that order: rx_adc_setup recovers the
         # baseband bandwidth from rxbbf_div, which the filter calib writes.
         {:ok, analog} <-
           RxAnalog.setup(
             Keyword.get(opts, :rx_bb_bw_hz, div(sample_rate_hz, 2)),
             base.clocks.rx.bbpll,
             base.clocks.rx.adc
           ),
         {:ok, _} <- AD9363.bist_prbs(:disable) do
      {:ok,
       Map.merge(base, %{
         reference: ref,
         lo: lo,
         gm: gm,
         gain_table: gt,
         gain: gain,
         analog: analog
       })}
    end
  end

  @doc """
  Retune while leaving everything else alone, reloading the gain table if the new
  frequency crosses a band boundary.

  Retuning without this is what makes a frequency sweep meaningless: the gain
  table is band-dependent, so a sweep that crosses 1300 MHz or 4000 MHz with a
  stale table is comparing two different receivers.
  """
  def retune(lo_hz, opts \\ []) do
    ref = Keyword.get(opts, :ref_clk_hz, 80_000_000)

    with {:ok, lo} <- RFPLL.set_lo(lo_hz, ref_clk_hz: ref),
         {:ok, gt} <- Gain.load(lo_hz),
         {:ok, gain} <- Gain.set_gain_db(lo_hz, Keyword.get(opts, :gain_db, 10)) do
      {:ok, %{lo: lo, gain_table: gt, gain: gain}}
    end
  end

  @doc "Everything the chip reports about its current configuration."
  def state() do
    {:ok, pp} = AD9363.data_port_state()
    {:ok, ck} = Clocks.state()
    {:ok, en} = ENSM.state()
    {:ok, bist} = AD9363.bist_state()
    %{data_port: pp, clocks: ck, ensm: en, bist: bist, data_clk_mhz: LVDSProbe.data_clk_mhz(300)}
  end
end
