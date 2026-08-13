defmodule Nervezynq.AD9363.RFPLL do
  @moduledoc """
  RF synthesiser charge-pump calibration — the step that powers the synths up.

  Transcribed from `ad9361_txrx_synth_cp_calib()` (ad9361.c:2859).

  ## Why this is the next thing needed, and why it is only 60 lines

  The ENSM refuses to leave ALERT for RX while `POWER_DOWN_RX_SYNTH`
  (`ENSM_CONFIG_2` bit 6) is set, and the hardware re-asserts that bit as fast as
  it can be cleared while the receive synthesiser is unprogrammed. Measured:

      writef(0x015, 0x60, 0)  ->  cfg2 = 0x08   (cleared)
      set_state(:rx)          ->  cfg2 = 0x48   (hardware set it again)

  `ENSM.mask_synth_ready/1` cannot help: it masks synth *ready*, a different bit
  answering a different question. A masked ready signal on a powered-down
  synthesiser is still a powered-down synthesiser.

  Following the dependency chain in `ad9361_setup()` suggested a large job — the
  full RF PLL path is ~740 lines of C once `rfpll_int_set_rate`,
  `calc_rfpll_int_divder`, `rfpll_vco_init`, `fastlock_prepare` and a multi-byte
  SPI write are counted. But the thing that actually powers the synths up is one
  line inside the CP calibration:

      ad9361_spi_write(phy->spi, REG_ENSM_CONFIG_2, DUAL_SYNTH_MODE);

  writing `ENSM_CONFIG_2` to `0x04`, which clears both power-down bits. And the
  CP calibration itself is a straight run of register writes plus one status
  poll. So this module transcribes only that.

  ## What this deliberately does not do

  It does not set the LO frequency. There is no `rfpll_set_rate` here, no VCO
  divider, no fractional word — so the synthesiser is powered and calibrated but
  parked at whatever frequency its dividers happen to give.

  That is fine *for the current purpose and no other*: the BIST injects at the
  digital receive control point, downstream of the mixer, so a pattern crossing
  the LVDS interface does not care where the LO is. It is completely inadequate
  for receiving an actual signal, and `Bringup`'s moduledoc lists the rest of
  `ad9361_setup()` that real reception still needs.

  ## An assumption worth flagging

  `ref_clk_hz` only selects the VCO calibration count (ADI: >40 MHz picks a
  shorter count). It is passed as 80 MHz because that is what
  `ad9361_ref_div_sel(40 MHz, MAX_SYNTH_FREF)` returns — the reference doubler
  path. But the `RX_REFCLK` divider has *not* been programmed here, so the
  synthesiser's actual reference may not be 80 MHz. If the calibration times out,
  that is the first thing to suspect, and the fix is to transcribe
  `ad9361_to_refclk_scaler()` and set the divider properly.
  """

  import Bitwise
  alias Nervezynq.AD9363
  alias Nervezynq.AD9363.SynthLUT

  # Receive-side registers. The transmit side is the same map offset by 0x40,
  # verified against ad9361.h rather than assumed: 0x23B->0x27B, 0x24B->0x28B,
  # 0x261->0x2A1. ADI relies on the same offset.
  @reg_cp_current 0x23B
  @reg_cp_config 0x23D
  @reg_cal_status 0x244
  @reg_vco_pd_overrides 0x246
  @reg_cp_overrange_vco_lock 0x247
  @reg_vco_ldo 0x248
  @reg_vco_cal 0x249
  @reg_cp_level_detect 0x24B
  @reg_dsm_setup_1 0x24D
  @reg_lo_gen_power_mode 0x261

  @reg_parallel_port_conf_3 0x012
  @reg_ensm_mode 0x013
  @reg_ensm_config_1 0x014
  @reg_ensm_config_2 0x015

  @cp_offset_off 0x10
  @cp_cal_enable 0x04
  @cp_cal_valid 0x80
  @vco_cal_en 0x80
  @vco_lock 0x02
  @half_duplex_mode 0x08
  @dual_synth_mode 0x04
  @fdd_mode 0x01
  @force_alert_state 0x04
  @to_alert 0x01

  @doc """
  Run the charge-pump calibration for the receive or transmit synthesiser.

  Note this leaves the chip in FDD mode with `FORCE_ALERT_STATE` — ADI does the
  same and restores TDD afterwards via `ad9361_set_ensm_mode()`. So this must run
  *before* `ENSM.set_mode/2`, not after, or the mode gets clobbered.
  """
  def synth_cp_calib(which, ref_clk_hz \\ 80_000_000, opts \\ []) when which in [:rx, :tx] do
    offs = if which == :tx, do: 0x40, else: 0x00
    fdd? = Keyword.get(opts, :fdd, false)

    # ADI: Table 70, "Example Calibration Times for RF VCO Cal".
    vco_cal_cnt =
      cond do
        fdd? -> @vco_cal_en ||| 3 <<< 2 ||| 2
        ref_clk_hz > 40_000_000 -> @vco_cal_en ||| 1 <<< 2 ||| 2
        true -> @vco_cal_en ||| 0 <<< 2 ||| 2
      end

    # Plain writes throughout, as ADI does. Several of these are analogue trim
    # and power-control registers with no reason to expect a clean readback, and
    # this session has already paid twice for assuming otherwise.
    :ok = AD9363.write(@reg_cp_level_detect + offs, 0x17)
    :ok = AD9363.write(@reg_dsm_setup_1 + offs, 0x00)
    :ok = AD9363.write(@reg_lo_gen_power_mode + offs, 0x00)
    :ok = AD9363.write(@reg_vco_ldo + offs, 0x0B)
    :ok = AD9363.write(@reg_vco_pd_overrides + offs, 0x02)
    :ok = AD9363.write(@reg_cp_current + offs, 0x80)
    :ok = AD9363.write(@reg_cp_config + offs, @cp_offset_off)
    :ok = AD9363.write(@reg_vco_cal + offs, vco_cal_cnt)

    # ADI enables full duplex for the duration of the calibration.
    unless fdd? do
      :ok = AD9363.writef(@reg_parallel_port_conf_3, @half_duplex_mode, 0)
    end

    # THIS is the write that powers both synthesisers up: ENSM_CONFIG_2 <- 0x04
    # clears POWER_DOWN_RX_SYNTH and POWER_DOWN_TX_SYNTH.
    :ok = AD9363.write(@reg_ensm_config_2, @dual_synth_mode)
    :ok = AD9363.write(@reg_ensm_config_1, @force_alert_state ||| @to_alert)
    :ok = AD9363.write(@reg_ensm_mode, @fdd_mode)

    :ok = AD9363.write(@reg_cp_config + offs, @cp_offset_off ||| @cp_cal_enable)

    await(@reg_cal_status + offs, @cp_cal_valid, 2000)
  end

  @doc "Whether the named synthesiser reports its VCO locked."
  def vco_locked?(which) when which in [:rx, :tx] do
    offs = if which == :tx, do: 0x40, else: 0x00

    case AD9363.read(@reg_cp_overrange_vco_lock + offs) do
      {:ok, v} -> {:ok, %{raw: v, locked: band(v, @vco_lock) != 0}}
      other -> other
    end
  end

  @doc "Both synthesisers' power-down bits, as the ENSM sees them."
  def synth_power_state() do
    case AD9363.read(@reg_ensm_config_2) do
      {:ok, v} ->
        {:ok,
         %{
           ensm_config_2: v,
           rx_synth_powered_down: band(v, 0x40) != 0,
           tx_synth_powered_down: band(v, 0x20) != 0
         }}

      other ->
        other
    end
  end

  defp await(reg, mask, 0) do
    {:ok, v} = AD9363.read(reg)
    {:error, {:cp_cal_timeout, reg: reg, mask: mask, got: v}}
  end

  defp await(reg, mask, n) do
    {:ok, v} = AD9363.read(reg)

    if band(v, mask) == mask do
      {:ok, v}
    else
      Process.sleep(1)
      await(reg, mask, n - 1)
    end
  end

  # --- LO frequency programming ----------------------------------------------
  #
  # Transcribed from ad9361_rfpll_int_set_rate (ad9361.c:6848),
  # ad9361_calc_rfpll_int_divder (:6727), ad9361_rfpll_vco_init (:1744),
  # ad9361_to_refclk_scaler (:6313) and ad9361_ref_div_sel (:5329).

  @reg_rfpll_dividers 0x005
  @rx_vco_divider 0x0F

  @reg_ref_divide_config_1 0x2AB
  @reg_ref_divide_config_2 0x2AC
  @rx_ref_divider_msb 0x01
  @rx_ref_divider_lsb 0x80
  @tx_ref_divider 0x0C

  @reg_rx_force_vco_tune_1 0x238
  @reg_rx_alc_varactor 0x239
  @reg_rx_vco_output 0x23A
  @reg_rx_loop_filter_1 0x23E
  @reg_rx_loop_filter_2 0x23F
  @reg_rx_loop_filter_3 0x240
  @reg_rx_vco_bias_1 0x242
  @reg_rx_vco_cal_ref 0x245
  @reg_rx_vco_varactor_ctrl_0 0x250
  @reg_rx_vco_varactor_ctrl_1 0x251
  @reg_rx_integer_byte_1 0x232
  @reg_rx_fract_byte_2 0x235

  @porb_vco_logic 0x40

  @rfpll_modulus 8_388_593
  @min_vco_freq_hz 6_000_000_000
  @max_synth_fref 80_008_000
  @min_synth_fref 9_999_000

  # ad9361_validate_rfpll, for dev_sel == ID_AD9363A.
  @ad9363a_min_carrier_hz 325_000_000
  @ad9363a_max_carrier_hz 3_800_000_000

  @doc """
  Choose the RFPLL reference frequency, per `ad9361_ref_div_sel()`.

  With a 40 MHz input and the default 80 MHz target this returns **80 MHz** — the
  reference doubler. That matters twice over: it sets `parent_rate` for the
  integer/fractional divider maths, and it selects which `SynthLUT` block applies
  (`Nervezynq.AD9363.SynthLUT.range/1` keys off this, not off the crystal).

  Returns 0 when no divider can reach the target, which is ADI's error signal.
  """
  def ref_div_sel(refin_hz, max_fref) do
    cond do
      refin_hz <= div(max_fref, 2) -> 2 * refin_hz
      refin_hz <= max_fref -> refin_hz
      refin_hz <= max_fref * 2 -> div(refin_hz, 2)
      refin_hz <= max_fref * 4 -> div(refin_hz, 4)
      true -> 0
    end
  end

  # ad9361_to_refclk_scaler: (mult << 4) | div -> a 2-bit code.
  defp refclk_scaler_code(1, 1), do: {:ok, 0}
  defp refclk_scaler_code(1, 2), do: {:ok, 1}
  defp refclk_scaler_code(1, 4), do: {:ok, 2}
  defp refclk_scaler_code(2, 1), do: {:ok, 3}
  defp refclk_scaler_code(m, d), do: {:error, {:bad_refclk_scaler, m, d}}

  @doc """
  Program the RX (and TX) synthesiser reference divider, returning the resulting
  reference frequency.

  **This was the missing piece.** `synth_cp_calib/2` was passing 80 MHz as its
  reference on the assumption that the doubler was on, while the divider itself
  had never been programmed — so the calibration count was chosen for a reference
  the hardware may not have had. This module's own moduledoc flagged it as the
  first thing to suspect.
  """
  def set_ref_clk(refin_hz \\ 40_000_000, max_fref \\ 80_000_000) do
    max_fref = max_fref |> max(@min_synth_fref) |> min(@max_synth_fref)
    ref = ref_div_sel(refin_hz, max_fref)

    scaler =
      cond do
        ref == 0 -> {:error, {:no_reference_divider, refin_hz, max_fref}}
        ref == 2 * refin_hz -> refclk_scaler_code(2, 1)
        ref == refin_hz -> refclk_scaler_code(1, 1)
        ref * 2 == refin_hz -> refclk_scaler_code(1, 2)
        ref * 4 == refin_hz -> refclk_scaler_code(1, 4)
        true -> {:error, {:unrepresentable_reference, refin_hz, ref}}
      end

    with {:ok, code} <- scaler do
      # RX's two bits are split across two registers, high bit in 0x2AB.
      :ok = AD9363.writef(@reg_ref_divide_config_1, @rx_ref_divider_msb, code >>> 1)
      :ok = AD9363.writef(@reg_ref_divide_config_2, @rx_ref_divider_lsb, code &&& 1)
      :ok = AD9363.writef(@reg_ref_divide_config_2, @tx_ref_divider, code)
      {:ok, %{ref_clk_hz: ref, scaler_code: code, lut_range: SynthLUT.range(ref)}}
    end
  end

  @doc """
  The integer/fractional divider and VCO divider for a target LO.

  The VCO always runs above 6 GHz and the LO is `vco / 2^(vco_div + 1)`, so the
  divider is found by doubling the target until it clears `MIN_VCO_FREQ_HZ`.
  Note ADI's comparison is `<=`, so a target whose VCO lands exactly on 6 GHz
  doubles once more; that is reproduced rather than corrected.
  """
  def calc_divider(freq_hz, parent_rate) do
    {vco_hz, vco_div} = scale_to_vco(freq_hz, -1)

    integer = div(vco_hz, parent_rate)
    remainder = rem(vco_hz, parent_rate)
    fract = div(remainder * @rfpll_modulus + div(parent_rate, 2), parent_rate)

    %{integer: integer, fract: fract, vco_div: vco_div, vco_hz: vco_hz}
  end

  defp scale_to_vco(freq, div) when freq <= @min_vco_freq_hz, do: scale_to_vco(freq * 2, div + 1)
  defp scale_to_vco(freq, div), do: {freq, div}

  @doc "The LO a given divider set actually produces — ADI's `ad9361_calc_rfpll_int_freq`."
  def recalc(%{integer: integer, fract: fract, vco_div: vco_div}, parent_rate) do
    (div(parent_rate * fract, @rfpll_modulus) + parent_rate * integer) >>> (vco_div + 1)
  end

  @doc """
  Program the RX LO.

  Order matters and is ADI's: the analogue tuning from the `SynthLUT` first, then
  the frequency word as one descending 5-byte transaction, then the VCO divider,
  then poll for lock. The synthesiser recalibrates its VCO automatically on the
  frequency write, provided `VCO_CAL_EN` was set — which `synth_cp_calib/2` does.

  `:ref_clk_hz` must be the *actual* RFPLL reference, i.e. what `set_ref_clk/2`
  returned, not the crystal.
  """
  def set_lo(freq_hz, opts \\ []) do
    ref = Keyword.get(opts, :ref_clk_hz, 80_000_000)
    mode = Keyword.get(opts, :mode, :tdd)

    with :ok <- validate_carrier(freq_hz) do
      d = calc_divider(freq_hz, ref)

      with {:ok, row} <- SynthLUT.row(mode, SynthLUT.range(ref), d.vco_hz),
           :ok <- vco_init(row),
           :ok <- write_freq_word(d),
           :ok <- AD9363.writef(@reg_rfpll_dividers, @rx_vco_divider, d.vco_div),
           {:ok, lock} <- await_vco_lock(200) do
        {:ok,
         Map.merge(d, %{
           requested_hz: freq_hz,
           actual_hz: recalc(d, ref),
           ref_clk_hz: ref,
           lut_range: SynthLUT.range(ref),
           lut_vco_mhz: row.vco_mhz,
           vco_locked: lock
         })}
      end
    end
  end

  # AD9363 is narrower than the AD9361: ad9361_validate_rfpll's ID_AD9363A arm.
  # Note ADI's round_rate uses the *generic* 70 MHz..6 GHz limits, so a request
  # can pass rounding and then fail here. We check once, up front, on purpose.
  defp validate_carrier(hz) when hz >= @ad9363a_min_carrier_hz and hz <= @ad9363a_max_carrier_hz,
    do: :ok

  defp validate_carrier(hz),
    do: {:error, {:carrier_out_of_range, hz, @ad9363a_min_carrier_hz, @ad9363a_max_carrier_hz}}

  # ad9361_rfpll_vco_init. Two of these are literals in ADI's code rather than
  # table lookups -- VCO_CAL_REF gets 0 and VARACTOR_CTRL_0 gets
  # VCO_VARACTOR_REFERENCE_TCF(7) -- which is easy to mistake for an omission.
  defp vco_init(row) do
    :ok = AD9363.write(@reg_rx_vco_output, row.vco_output_level &&& 0x0F ||| @porb_vco_logic)
    :ok = AD9363.writef(@reg_rx_alc_varactor, 0x0F, row.vco_varactor)
    :ok = AD9363.write(@reg_rx_vco_bias_1, (row.vco_bias_tcf &&& 0x03) <<< 3 ||| (row.vco_bias_ref &&& 0x07))
    :ok = AD9363.write(@reg_rx_force_vco_tune_1, (row.vco_cal_offset &&& 0x0F) <<< 3)
    :ok = AD9363.write(@reg_rx_vco_varactor_ctrl_1, row.vco_varactor_reference &&& 0x0F)
    :ok = AD9363.write(@reg_rx_vco_cal_ref, 0x00)
    :ok = AD9363.write(@reg_rx_vco_varactor_ctrl_0, 7 <<< 4)
    :ok = AD9363.writef(@reg_cp_current, 0x3F, row.charge_pump_current)
    :ok = AD9363.write(@reg_rx_loop_filter_1, (row.lf_c2 &&& 0x0F) <<< 4 ||| (row.lf_c1 &&& 0x0F))
    :ok = AD9363.write(@reg_rx_loop_filter_2, (row.lf_r1 &&& 0x0F) <<< 4 ||| (row.lf_c3 &&& 0x0F))
    :ok = AD9363.write(@reg_rx_loop_filter_3, row.lf_r3 &&& 0x0F)
    :ok
  end

  # Five bytes, descending from 0x235 to 0x231. Byte 3 is read-modify-write:
  # only bits 2:0 of 0x232 are the integer word's high bits and the rest belong
  # to something else, so ADI reads 0x235 - 3 and preserves the top five bits.
  defp write_freq_word(%{integer: integer, fract: fract}) do
    {:ok, cur} = AD9363.read(@reg_rx_integer_byte_1)

    AD9363.write_multi(@reg_rx_fract_byte_2, [
      fract >>> 16 &&& 0x7F,
      fract >>> 8 &&& 0xFF,
      fract &&& 0xFF,
      (integer >>> 8 &&& 0x07) ||| (cur &&& 0xF8),
      integer &&& 0xFF
    ])
  end

  defp await_vco_lock(0), do: {:error, :vco_lock_timeout}

  defp await_vco_lock(n) do
    if vco_locked?(:rx) do
      {:ok, true}
    else
      Process.sleep(1)
      await_vco_lock(n - 1)
    end
  end

  @doc "Read back the LO the dividers are currently programmed for."
  def lo_freq(ref_clk_hz \\ 80_000_000) do
    with {:ok, b2} <- AD9363.read(@reg_rx_fract_byte_2),
         {:ok, b1} <- AD9363.read(0x234),
         {:ok, b0} <- AD9363.read(0x233),
         {:ok, i1} <- AD9363.read(@reg_rx_integer_byte_1),
         {:ok, i0} <- AD9363.read(0x231),
         {:ok, dividers} <- AD9363.read(@reg_rfpll_dividers) do
      d = %{
        fract: (b2 &&& 0x7F) <<< 16 ||| b1 <<< 8 ||| b0,
        integer: (i1 &&& 0x07) <<< 8 ||| i0,
        vco_div: dividers &&& @rx_vco_divider
      }

      {:ok, Map.put(d, :lo_hz, recalc(d, ref_clk_hz))}
    end
  end

end
