defmodule Nervezynq.AD9363.Clocks do
  @moduledoc """
  The digital clock chain: BBPLL down to the sample clocks, and the dividers
  that get you there.

  Transcribed from `ad9361_calculate_rf_clock_chain()` (ad9361.c:4752),
  `ad9361_validate_trx_clock_chain()` (4561), `ad9361_set_trx_clock_chain()`
  (4626) and the per-clock register writes in `ad9361_set_clk_scaler()` (6337).

  ## Why this is much smaller than ADI's version

  `no-OS` runs this through a generic clock framework — sixteen `refclk_scale`
  entries, `clk_set_rate`/`round_rate`/`recalc_rate` for each, parent pointers,
  prepare/enable refcounts. Almost all of that exists to satisfy the Linux clock
  API, which we are not implementing.

  What the hardware actually has is two fixed divider chains:

      BBPLL -> ADC -> R2 -> R1 -> CLKRF -> RX_SAMPL     (receive)
      ADC   -> DAC -> T2 -> T1 -> CLKTF -> TX_SAMPL     (transmit)

  Each stage is one small integer divider in one register field. Given the two
  rate arrays, every divider is just `parent / child`, and the whole thing is a
  dozen register writes. So this module computes the rates exactly as ADI does —
  that arithmetic is load-bearing and is transcribed rather than reinvented —
  and then writes the dividers directly.

  ## DATA_CLK falls out of this

      data_clk = (rx2tx2 ? 4 : 2) / (lvds ? 1 : 2) * rx_sampl_freq

  from `ad9361_validate_trx_clock_chain()`. For 2R2T LVDS that is `4 x Fs`, so
  the 4 MSPS default here predicts a 16 MHz DATA_CLK. That prediction is the
  point: the fabric measures DATA_CLK independently through `STATUS2`, so
  configuring the chain and then reading back 16 MHz is a real end-to-end
  check on the arithmetic, not a readback of our own register writes.

  The 7.694 MHz observed before any of this ran was a reset default and
  corresponded to nothing.
  """

  import Bitwise
  alias Nervezynq.AD9363

  @reg_tx_enable_filter_ctrl 0x002
  @reg_rx_enable_filter_ctrl 0x003
  @reg_bbpll 0x00A

  @max_bbpll_freq 1_430_143_000
  @max_bbpll_div 64
  @min_bbpll_div 2
  @min_adc_clk 25_000_000
  @max_adc_clk 640_000_000
  @max_dac_clk 320_000_000
  @max_baseband_rate 61_440_000

  @max_rx_rates [@max_bbpll_freq, @max_adc_clk, 640_000_000, 320_000_000, 245_760_000, @max_baseband_rate]
  @max_tx_rates [@max_bbpll_freq, @max_dac_clk, 320_000_000, 320_000_000, 160_000_000, @max_baseband_rate]

  # ad9361.c:4762. Column 0 is the ADC-to-CLKRF ratio; columns 1..3 are the
  # R2, R1 and CLKRF dividers that realise it.
  @clk_dividers [
    {12, 3, 2, 2},
    {8, 2, 2, 2},
    {6, 3, 1, 2},
    {4, 2, 2, 1},
    {3, 3, 1, 1},
    {2, 2, 1, 1},
    {1, 1, 1, 1}
  ]

  @doc """
  Compute the RX and TX rate chains for a desired sample rate.

  Returns `{:ok, %{rx: [bbpll, adc, r2, r1, clkrf, rx_sampl], tx: [...]}}`.

  `:rx_fir_dec` and `:tx_fir_int` default to 1 with the FIRs bypassed, which is
  deliberate for now: a non-unity FIR needs a coefficient set loaded through
  `ad9361_load_fir_filter_coef()`, and there is no reason to take on that
  dependency before the data port has been shown to work at all.
  """
  def calculate(sample_rate_hz, opts \\ []) do
    rx_dec = if Keyword.get(opts, :bypass_rx_fir, true), do: 1, else: Keyword.get(opts, :rx_fir_dec, 1)
    tx_int = if Keyword.get(opts, :bypass_tx_fir, true), do: 1, else: Keyword.get(opts, :tx_fir_int, 1)
    rx_eq_2tx = Keyword.get(opts, :rx_eq_2tx, false)

    cond do
      sample_rate_hz > @max_baseband_rate ->
        {:error, {:sample_rate_too_high, sample_rate_hz, @max_baseband_rate}}

      true ->
        # ADI recurses on rate_gov; the recursion only ever walks it upward, so
        # it is a search over the same table with a rising start index.
        rate_gov = if rx_dec * sample_rate_hz * 8 < @min_adc_clk, do: 0, else: 1
        search(sample_rate_hz, rate_gov, rx_dec, tx_int, rx_eq_2tx)
    end
  end

  defp search(sample_rate_hz, rate_gov, rx_dec, tx_int, rx_eq_2tx) when rate_gov < 7 do
    clktf = sample_rate_hz * tx_int
    clkrf = sample_rate_hz * rx_dec * if(rx_eq_2tx, do: 2, else: 1)

    found =
      Enum.reduce_while(rate_gov..6, nil, fn i, _ ->
        {ratio, _, _, _} = Enum.at(@clk_dividers, i)
        adc_rate = clkrf * ratio
        dac_rate = clktf * ratio

        if adc_rate <= @max_adc_clk and adc_rate >= @min_adc_clk do
          tmp = if dac_rate > adc_rate, do: -div(dac_rate, adc_rate), else: div(adc_rate, dac_rate)

          if adc_rate <= @max_dac_clk do
            {:halt, {i, i - if(tmp == 1, do: 0, else: tmp), adc_rate, adc_rate}}
          else
            index_tx =
              if i == 4 and tmp >= 0 do
                7
              else
                i + if(i == 5 and tmp >= 0, do: 1, else: 2) - if(tmp == 1, do: 0, else: tmp)
              end

            {:halt, {i, index_tx, adc_rate, div(adc_rate, 2)}}
          end
        else
          {:cont, nil}
        end
      end)

    case found do
      {irx, itx, adc_rate, dac_rate} when irx in 0..6 and itx in 0..6 ->
        build(irx, itx, adc_rate, dac_rate, rx_dec, tx_int)

      _ ->
        search(sample_rate_hz, rate_gov + 1, rx_dec, tx_int, rx_eq_2tx)
    end
  end

  defp search(sample_rate_hz, _rate_gov, _rx_dec, _tx_int, _rx_eq_2tx) do
    {:error, {:no_suitable_dividers, sample_rate_hz}}
  end

  defp build(irx, itx, adc_rate, dac_rate, rx_dec, tx_int) do
    bbpll = bbpll_rate(adc_rate, @max_bbpll_div)

    {_, r2d, r1d, clkrfd} = Enum.at(@clk_dividers, irx)
    {_, t2d, t1d, clktfd} = Enum.at(@clk_dividers, itx)

    r2 = div(adc_rate, r2d)
    r1 = div(r2, r1d)
    clkrf = div(r1, clkrfd)

    t2 = div(dac_rate, t2d)
    t1 = div(t2, t1d)
    clktf = div(t1, clktfd)

    {:ok,
     %{
       rx: [bbpll, adc_rate, r2, r1, clkrf, div(clkrf, rx_dec)],
       tx: [bbpll, dac_rate, t2, t1, clktf, div(clktf, tx_int)]
     }}
  end

  # ADI's do/while: halve the divider until the BBPLL rate is in range.
  defp bbpll_rate(adc_rate, div) do
    rate = adc_rate * div

    if rate > @max_bbpll_freq and div(div, 2) >= @min_bbpll_div do
      bbpll_rate(adc_rate, div(div, 2))
    else
      rate
    end
  end

  @doc """
  Check a computed chain against the hardware's limits.

  Two separate checks, and the second is the interesting one. The first is a
  per-stage maximum. The second requires that DATA_CLK actually appear
  *somewhere* in the divider chain — ADI searches `ADC/1..3` and `R2 >> 1..4`
  for it — because the data port clock is tapped off the chain rather than
  generated independently. A rate set that passes the maximums but has no tap
  producing DATA_CLK is one where the port cannot be clocked at all.
  """
  def validate(rx, tx, opts \\ []) do
    rx2tx2 = Keyword.get(opts, :rx2tx2, true)
    lvds = Keyword.get(opts, :lvds, true)

    [_bbpll, adc, r2, _r1, _clkrf, rx_sampl] = rx

    data_clk = div(if(rx2tx2, do: 4, else: 2), if(lvds, do: 1, else: 2)) * rx_sampl

    over =
      Enum.zip([rx, @max_rx_rates]) |> Enum.filter(fn {v, m} -> v > m end) |> Enum.map(&{:rx, &1})

    over =
      over ++
        (Enum.zip([tx, @max_tx_rates]) |> Enum.filter(fn {v, m} -> v > m end) |> Enum.map(&{:tx, &1}))

    tapped =
      Enum.any?(1..3, fn i -> abs(div(adc, i) - data_clk) < 4 end) or
        Enum.any?(1..4, fn i -> abs((r2 >>> i) - data_clk) < 4 end)

    cond do
      not lvds and data_clk > @max_baseband_rate -> {:error, {:cmos_data_clk_too_high, data_clk}}
      over != [] -> {:error, {:rate_limits_exceeded, over}}
      not tapped -> {:error, {:no_data_clk_tap, data_clk}}
      true -> {:ok, %{data_clk_hz: data_clk}}
    end
  end

  @doc """
  Write the dividers for a computed chain.

  Every divider is `parent / child` over the rate array, which is what ADI's
  clock framework works out the long way round. The register fields are from
  `ad9361_set_clk_scaler()`; note the half-band "enable" bits are written as
  `div - 1`, so enabling a halfband *is* dividing by two.
  """
  def apply_chain(rx, tx, opts \\ []) do
    bypass_rx_fir = Keyword.get(opts, :bypass_rx_fir, true)
    bypass_tx_fir = Keyword.get(opts, :bypass_tx_fir, true)

    [bbpll, adc, r2, r1, clkrf, rx_sampl] = rx
    [_, dac, t2, t1, clktf, tx_sampl] = tx

    with {:ok, _} <- AD9363.bbpll_set_rate(bbpll),
         # ADC_CLK is a power-of-two divide of the BBPLL, field is log2.
         :ok <- writef_checked(@reg_bbpll, 0x07, ilog2(ratio(bbpll, adc)), 1..6),
         # DAC_CLK hangs off ADC_CLK, not off the BBPLL.
         :ok <- writef_checked(@reg_bbpll, 0x08, ratio(adc, dac) - 1, 1..2, :raw),
         :ok <- writef_checked(@reg_rx_enable_filter_ctrl, 0x30, ratio(adc, r2) - 1, 1..3, :raw),
         :ok <- writef_checked(@reg_rx_enable_filter_ctrl, 0x08, ratio(r2, r1) - 1, 1..2, :raw),
         :ok <- writef_checked(@reg_rx_enable_filter_ctrl, 0x04, ratio(r1, clkrf) - 1, 1..2, :raw),
         :ok <- fir_field(@reg_rx_enable_filter_ctrl, 0x03, ratio(clkrf, rx_sampl), bypass_rx_fir),
         :ok <- writef_checked(@reg_tx_enable_filter_ctrl, 0x30, ratio(dac, t2) - 1, 1..3, :raw),
         :ok <- writef_checked(@reg_tx_enable_filter_ctrl, 0x08, ratio(t2, t1) - 1, 1..2, :raw),
         :ok <- writef_checked(@reg_tx_enable_filter_ctrl, 0x04, ratio(t1, clktf) - 1, 1..2, :raw),
         :ok <- fir_field(@reg_tx_enable_filter_ctrl, 0x03, ratio(clktf, tx_sampl), bypass_tx_fir) do
      {:ok, %{rx: rx, tx: tx}}
    end
  end

  @doc """
  Compute, validate and apply a chain for `sample_rate_hz` in one step.

  Returns the predicted DATA_CLK alongside the rates, so it can be compared
  against what the fabric measures.
  """
  def set_sample_rate(sample_rate_hz, opts \\ []) do
    with {:ok, %{rx: rx, tx: tx}} <- calculate(sample_rate_hz, opts),
         {:ok, %{data_clk_hz: data_clk}} <- validate(rx, tx, opts),
         {:ok, _} <- apply_chain(rx, tx, opts) do
      {:ok,
       %{
         sample_rate_hz: sample_rate_hz,
         predicted_data_clk_hz: data_clk,
         predicted_data_clk_mhz: Float.round(data_clk / 1.0e6, 3),
         rx: label(rx, [:bbpll, :adc, :r2, :r1, :clkrf, :rx_sampl]),
         tx: label(tx, [:bbpll, :dac, :t2, :t1, :clktf, :tx_sampl])
       }}
    end
  end

  @doc "Read back the two filter-control registers, decoded."
  def state() do
    with {:ok, rxf} <- AD9363.read(@reg_rx_enable_filter_ctrl),
         {:ok, txf} <- AD9363.read(@reg_tx_enable_filter_ctrl),
         {:ok, bb} <- AD9363.read(@reg_bbpll) do
      {:ok,
       %{
         rx_filter_ctrl: rxf,
         rx_channel_enable: rxf >>> 6 &&& 0x3,
         dec3_div: (rxf >>> 4 &&& 0x3) + 1,
         rhb2_div: (rxf >>> 3 &&& 0x1) + 1,
         rhb1_div: (rxf >>> 2 &&& 0x1) + 1,
         rx_fir_field: rxf &&& 0x3,
         tx_filter_ctrl: txf,
         tx_channel_enable: txf >>> 6 &&& 0x3,
         bbpll_reg: bb,
         adc_div: 1 <<< (bb &&& 0x7),
         dac_div: (bb >>> 3 &&& 1) + 1
       }}
    end
  end

  # --- helpers -----------------------------------------------------------------

  defp label(rates, names), do: names |> Enum.zip(rates) |> Map.new()

  defp ratio(parent, child) when child > 0, do: round(parent / child)

  defp ilog2(n) when n > 0, do: trunc(:math.log2(n))

  defp writef_checked(reg, mask, value, range, mode \\ :log) do
    check = if mode == :log, do: value, else: value + 1

    if check in range do
      AD9363.writef(reg, mask, value)
    else
      {:error, {:divider_out_of_range, reg, mask, check, range}}
    end
  end

  # RX_SAMPL / TX_SAMPL share a field with the FIR enable: 0 means the FIR is
  # bypassed, otherwise the field is log2(div) + 1. Only 1, 2 and 4 are legal.
  defp fir_field(reg, mask, divider, bypass) do
    cond do
      bypass -> AD9363.writef(reg, mask, 0)
      divider in [1, 2, 4] -> AD9363.writef(reg, mask, ilog2(divider) + 1)
      true -> {:error, {:bad_fir_divider, divider}}
    end
  end
end
