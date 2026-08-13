defmodule Nervezynq.AD9363.RxAnalog do
  @moduledoc """
  The RX analogue chain: baseband filter calibration, TIA capacitance, and the
  sigma-delta ADC setup.

  Transcribed from `ad9361_rx_bb_analog_filter_calib()` (ad9361.c:2691),
  `ad9361_rx_tia_calib()` (:2633) and `ad9361_rx_adc_setup()` (:2476).

  ## Order is a dependency, not a style

  `rx_adc_setup` recovers the baseband bandwidth by *inverting* the filter
  calibration's own formula:

      BBBW = (BBPLL / rxbbf_div) * ln(2) / (1.4 * 2PI)

  and ADI's comment says it plainly — *"We assume
  ad9361_rx_bb_analog_filter_calib() is always run prior"*. `rxbbf_div` is
  computed and written by the filter calibration. Run the ADC setup first and it
  computes its forty coefficients from a stale or reset divider, producing an ADC
  configured for a bandwidth the filter does not have. So: filter calib, then TIA,
  then ADC.

  ## C integer semantics, reproduced deliberately

  This function is unusually hostile to transcription. It is integer arithmetic
  with mixed widths and signedness, and the results are written straight into
  forty ADC registers where a wrong value is not obviously wrong.

  Two specific hazards, both handled explicitly here rather than hoped over:

    * **Unsigned wraparound is load-bearing.** `data[13]` starts from
      `-3 * (invrc_tconst_1e6 >> 1) + ...`, which can go negative. In C that is
      `uint64_t` arithmetic, so it wraps to a huge positive number and the
      subsequent `min(255, tmp)` clamps to 255. Elixir integers are arbitrary
      precision, so the same expression stays negative and `min/2` would yield a
      *negative byte*. `u64/1` masks to 64 bits at each point C would have.
    * **`no_os_do_div` is truncating division on unsigned values**, not Elixir's
      `div/2` on signed ones. After masking they agree; before masking they do
      not.

  Every byte is checked against `0..255` before any of them is written. Forty
  registers of silently-wrong ADC configuration is precisely the failure this
  project keeps paying for, and the check costs nothing.

  ## Status

  **Written, not yet validated on hardware.** The prior suspects for "no band
  selectivity" — an unloaded gain table, a wrong-band gain table, an unconnected
  antenna — have all been eliminated by measurement. This is the next one.
  """

  import Bitwise
  alias Nervezynq.AD9363

  @reg_rx_bbf_tune_divide 0x1F8
  @reg_rx_bbf_tune_config 0x1F9
  @reg_rx_bbbw_mhz 0x1FB
  @reg_rx_bbbw_khz 0x1FC
  @reg_rx_mix_lo_cm 0x1D5
  @reg_rx_mix_gm_config 0x1D6
  @reg_rx1_tune_ctrl 0x1E2
  @reg_rx2_tune_ctrl 0x1E3
  @reg_calibration_ctrl 0x016

  @reg_rx_bbf_c3_msb 0x1EB
  @reg_rx_bbf_c3_lsb 0x1EC
  @reg_rx_bbf_r2346 0x1E6

  @reg_rx_tia_config 0x1DB
  @reg_tia1_c_lsb 0x1DC
  @reg_tia1_c_msb 0x1DD
  @reg_tia2_c_lsb 0x1DE
  @reg_tia2_c_msb 0x1DF

  @rx_bb_tune_cal 0x80
  @rx1_tune_resample 0x02
  @rx1_pd_tune 0x01
  @rx2_tune_resample 0x02
  @rx2_pd_tune 0x01

  @doc """
  The whole RX analogue chain, in ADI's required order.

  `rx_bb_bw_hz` is the baseband bandwidth — half the complex sample rate is the
  usual starting point.
  """
  def setup(rx_bb_bw_hz, bbpll_freq_hz, adc_freq_hz) do
    with {:ok, filt} <- bb_analog_filter_calib(rx_bb_bw_hz, bbpll_freq_hz),
         {:ok, tia} <- tia_calib(rx_bb_bw_hz),
         {:ok, adc} <- adc_setup(bbpll_freq_hz, adc_freq_hz, filt.rxbbf_div) do
      {:ok, %{filter: filt, tia: tia, adc: adc}}
    end
  end

  @doc "`ad9361_rx_bb_analog_filter_calib`. Sets and returns `rxbbf_div`."
  def bb_analog_filter_calib(rx_bb_bw_hz, bbpll_freq_hz) do
    bw = clamp(rx_bb_bw_hz, 200_000, 28_000_000)

    # 1.4 * BBBW * 2PI / ln(2), as ADI's magic constant.
    target = 126_906 * div(bw, 10_000)
    rxbbf_div = min(511, div_round_up(bbpll_freq_hz, target))

    :ok = AD9363.write(@reg_rx_bbf_tune_divide, rxbbf_div &&& 0xFF)
    :ok = AD9363.writef(@reg_rx_bbf_tune_config, 0x01, rxbbf_div >>> 8)

    :ok = AD9363.write(@reg_rx_bbbw_mhz, div(bw, 1_000_000))
    khz = min(127, div_round_closest(rem(bw, 1_000_000) * 128, 1_000_000))
    :ok = AD9363.write(@reg_rx_bbbw_khz, khz)

    :ok = AD9363.write(@reg_rx_mix_lo_cm, 0x3F)
    :ok = AD9363.write(@reg_rx_mix_gm_config, 0x03)

    # Enable the tune circuit, run the calibration, then disable it again. The
    # calibration is complete when 0x016[7] self-clears.
    :ok = AD9363.write(@reg_rx1_tune_ctrl, @rx1_tune_resample)
    :ok = AD9363.write(@reg_rx2_tune_ctrl, @rx2_tune_resample)

    result = run_calibration(@rx_bb_tune_cal, 500)

    :ok = AD9363.write(@reg_rx1_tune_ctrl, @rx1_tune_resample ||| @rx1_pd_tune)
    :ok = AD9363.write(@reg_rx2_tune_ctrl, @rx2_tune_resample ||| @rx2_pd_tune)

    case result do
      :ok -> {:ok, %{rxbbf_div: rxbbf_div, bb_bw_hz: bw, bbbw_mhz: div(bw, 1_000_000)}}
      err -> err
    end
  end

  @doc "`ad9361_rx_tia_calib`. Reads back the BBF capacitors and sizes the TIA."
  def tia_calib(bb_bw_hz) do
    bw = clamp(bb_bw_hz, 200_000, 20_000_000)

    with {:ok, reg_1eb} <- AD9363.read(@reg_rx_bbf_c3_msb),
         {:ok, reg_1ec} <- AD9363.read(@reg_rx_bbf_c3_lsb),
         {:ok, reg_1e6} <- AD9363.read(@reg_rx_bbf_r2346) do
      cbbf = reg_1eb * 160 + reg_1ec * 10 + 140
      r2346 = 18_300 * (reg_1e6 &&& 0x07)
      ctia_ff = div(cbbf * r2346 * 560, 3_500_000)

      reg_1db =
        cond do
          bw <= 3_000_000 -> 0xE0
          bw <= 10_000_000 -> 0x60
          true -> 0x20
        end

      {reg_1dc, reg_1dd, reg_1de, reg_1df} =
        if ctia_ff > 2920 do
          t = min(127, div_round_closest(ctia_ff - 400, 320))
          {0x40, t, 0x40, t}
        else
          t = div_round_closest(ctia_ff - 400, 40) + 0x40
          {t, 0, t, 0}
        end

      bytes = [reg_1db, reg_1dc, reg_1dd, reg_1de, reg_1df]

      with :ok <- validate_bytes(bytes, :tia) do
        :ok = AD9363.write(@reg_rx_tia_config, reg_1db)
        :ok = AD9363.write(@reg_tia1_c_lsb, reg_1dc)
        :ok = AD9363.write(@reg_tia1_c_msb, reg_1dd)
        :ok = AD9363.write(@reg_tia2_c_lsb, reg_1de)
        :ok = AD9363.write(@reg_tia2_c_msb, reg_1df)
        {:ok, %{cbbf_ff: cbbf, r2346: r2346, ctia_ff: ctia_ff, regs: bytes}}
      end
    end
  end

  @doc """
  `ad9361_rx_adc_setup`. Computes forty bytes and writes them to 0x200..0x227.

  `rxbbf_div` must be the value the filter calibration just wrote.
  """
  def adc_setup(bbpll_freq_hz, adc_freq_hz, rxbbf_div) do
    with {:ok, c3_msb} <- AD9363.read(@reg_rx_bbf_c3_msb),
         {:ok, c3_lsb} <- AD9363.read(@reg_rx_bbf_c3_lsb),
         {:ok, r2346} <- AD9363.read(@reg_rx_bbf_r2346) do
      bb_bw_hz =
        div(bbpll_freq_hz * 10_000, 126_906 * rxbbf_div)
        |> clamp(200_000, 28_000_000)

      scale_snr_1e3 = if adc_freq_hz < 80_000_000, do: 1000, else: 1585

      invrc_tconst_1e6 =
        if bb_bw_hz >= 18_000_000 do
          div(
            160_975 * r2346 * (160 * c3_msb + 10 * c3_lsb + 140) * bb_bw_hz *
              (1000 + div(10 * (bb_bw_hz - 18_000_000), 1_000_000)),
            1000
          )
        else
          160_975 * r2346 * (160 * c3_msb + 10 * c3_lsb + 140) * bb_bw_hz
        end
        |> div(1_000_000_000)

      sqrt_inv_rc = isqrt(invrc_tconst_1e6)
      maxsnr = div(640, 160)
      scaled_adc_clk_1e6 = div_round_closest(adc_freq_hz, 640)
      inv_scaled_adc_clk_1e3 = div_round_closest(640_000_000, div_round_closest(adc_freq_hz, 1000))

      tmp_1e3 =
        div_round_closest(
          980_000 + 20 * max(1000, div_round_closest(inv_scaled_adc_clk_1e3, maxsnr)),
          1000
        )

      sqrt_term_1e3 = isqrt(scaled_adc_clk_1e6)
      min_sqrt_term_1e3 = min(1000, isqrt(maxsnr * scaled_adc_clk_1e6))

      d7 = min(124, div(u64(-50_000_000 + 8 * scale_snr_1e3 * sqrt_inv_rc * min_sqrt_term_1e3), 100_000_000))

      d8 =
        min(
          255,
          div(u64(div(invrc_tconst_1e6, 2) + div(20 * inv_scaled_adc_clk_1e3 * d7, 80) * 1000), invrc_tconst_1e6)
        )

      d10 = min(127, div(u64(-500_000 + 77 * sqrt_inv_rc * min_sqrt_term_1e3), 1_000_000))
      d9 = min(127, div(800 * d10, 1000))

      d11 =
        min(
          255,
          div(u64(div(invrc_tconst_1e6, 2) + 20 * inv_scaled_adc_clk_1e3 * d10 * 1000), invrc_tconst_1e6 * 77)
        )

      d12 = min(127, div(u32(-500_000 + 80 * sqrt_inv_rc * min_sqrt_term_1e3), 1_000_000))

      # Starts negative and relies on uint64 wraparound to clamp at 255.
      d13 =
        min(
          255,
          div(u64(-3 * div(invrc_tconst_1e6, 2) + inv_scaled_adc_clk_1e3 * d12 * div(1000 * 20, 80)), invrc_tconst_1e6)
        )

      d14 = 21 * div(inv_scaled_adc_clk_1e3, 10_000)
      d15 = min(127, div(500 + 1025 * d7, 1000))
      d16 = min(127, div(d15 * tmp_1e3, 1000))
      d18 = min(127, div(500 + 975 * d10, 1000))
      d19 = min(127, div(d18 * tmp_1e3, 1000))
      d21 = min(127, div(500 + 975 * d12, 1000))
      d22 = min(127, div(d21 * tmp_1e3, 1000))

      d25 = 128 + div(min(63_000, div_round_closest(63 * scaled_adc_clk_1e6, 1000)), 1000)
      d26 = min(63, div(div(63 * scaled_adc_clk_1e6, 1_000_000) * (920 + div(80 * inv_scaled_adc_clk_1e3, 1000)), 1000))
      d27 = min(63, div(32 * sqrt_term_1e3, 1000))
      d33 = min(63, div(63 * sqrt_term_1e3, 1000))
      d34 = min(127, div(64 * sqrt_term_1e3, 1000))

      data = [
        0, 0, 0, 0x24, 0x24, 0, 0,
        d7, d8, d9, d10, d11, d12, d13, d14,
        d15, d16, d15, d18, d19, d18, d21, d22, d21,
        0x2E, d25, d26, d27, d25, d26, d27, d25, d26,
        d33, d34, 0x40, 0x40, 0x2C, 0x00, 0x00
      ]

      with :ok <- validate_bytes(data, :adc) do
        data
        |> Enum.with_index()
        |> Enum.each(fn {b, i} -> :ok = AD9363.write(0x200 + i, b) end)

        {:ok, %{bb_bw_hz: bb_bw_hz, rxbbf_div: rxbbf_div, bytes: data}}
      end
    end
  end

  # --- helpers ---------------------------------------------------------------

  # Every one of these forty values ends up in a register. A value outside a byte
  # means the arithmetic diverged from C's, and writing it would configure the ADC
  # wrongly and silently.
  defp validate_bytes(bytes, what) do
    case Enum.reject(Enum.with_index(bytes), fn {b, _i} -> is_integer(b) and b >= 0 and b <= 255 end) do
      [] -> :ok
      bad -> {:error, {:byte_out_of_range, what, bad}}
    end
  end

  defp u64(v), do: v &&& 0xFFFF_FFFF_FFFF_FFFF
  defp u32(v), do: v &&& 0xFFFF_FFFF

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)
  defp div_round_up(a, b), do: div(a + b - 1, b)
  defp div_round_closest(a, b), do: div(a + div(b, 2), b)

  defp isqrt(0), do: 0
  defp isqrt(n) when n > 0, do: isqrt_iter(n, div(n + 1, 2), n)
  defp isqrt_iter(_n, x, prev) when x >= prev, do: prev
  defp isqrt_iter(n, x, _prev), do: isqrt_iter(n, div(x + div(n, x), 2), x)

  defp run_calibration(_mask, 0), do: {:error, :calibration_timeout}

  defp run_calibration(mask, tries) do
    :ok = AD9363.write(@reg_calibration_ctrl, mask)
    await_cal(mask, tries)
  end

  defp await_cal(_mask, 0), do: {:error, :calibration_timeout}

  defp await_cal(mask, tries) do
    case AD9363.read(@reg_calibration_ctrl) do
      {:ok, v} when (v &&& mask) == 0 -> :ok
      {:ok, _} -> (Process.sleep(1); await_cal(mask, tries - 1))
      err -> err
    end
  end
end
