defmodule Nervezynq.AD9363.SynthLUT do
  @moduledoc """
  ADI's RF synthesiser lookup tables, transcribed from `ad9361.c`.

  `ad9361_rfpll_vco_init()` picks one row of one of these tables and writes eleven
  registers from it: VCO output level, varactor, bias, cal offset, charge-pump
  current and the four loop-filter components. They are the analogue tuning of
  the RF PLL, and there is no computing them — they are measured coefficients.

  ## These were generated, not typed

  Six blocks of 53 rows of 13 integers is 4134 numbers. Hand-copying them is a
  guaranteed transcription error somewhere, and a single wrong loop-filter value
  gives a PLL that locks and is quietly noisy — indistinguishable from a working
  one until it corrupts a demodulation. So they were parsed out of
  `drivers/rf-transceiver/ad9361/ad9361.c` by script, with three invariants
  asserted at generation time: 53 rows per block, 13 fields per row, and the
  `vco_mhz` column identical across all six blocks and strictly descending.

  Source lines in `ad9361.c`: `SynthLUT_FDD` at 57 (40 MHz at 59, 60 MHz at 113,
  80 MHz at 167), `SynthLUT_TDD` at 223 (40 MHz at 225, 60 MHz at 279, 80 MHz at
  333).

  ## Picking a block

  Two independent choices, and both have bitten this project's neighbours:

    * **FDD vs TDD** — `ad9361_rfpll_vco_init` uses the FDD table only when the
      part is in FDD mode *and* the TX and RX LOs differ. On first bring-up both
      are still 0, so even an FDD configuration takes the TDD table for the
      first RX programming.
    * **Reference range** — `ad9361_rfvco_tableindex/1` keys off the **RFPLL
      reference clock**, not the crystal: `< 50 MHz` picks 40, `<= 70 MHz` picks
      60, otherwise 80. With a 40 MHz XO and the reference doubler enabled the
      reference is 80 MHz, so the **80** block applies — not the 40 block that
      the crystal frequency suggests.

  The difference is not cosmetic. At 2412 MHz (VCO 9648 MHz, row 11) the two
  candidate TDD blocks disagree:

      40 MHz block : charge_pump_current 42, lf_r1 12, lf_r3 13
      80 MHz block : charge_pump_current 33, lf_r1 10, lf_r3 12

  Choosing by crystal frequency instead of reference frequency mis-sets the
  charge pump by 27% and two loop-filter components.
  """

  @type row :: %{
          vco_mhz: pos_integer(),
          vco_output_level: 0..15,
          vco_varactor: 0..15,
          vco_bias_ref: 0..7,
          vco_bias_tcf: 0..3,
          vco_cal_offset: 0..15,
          vco_varactor_reference: 0..15,
          charge_pump_current: 0..63,
          lf_c2: 0..15,
          lf_c1: 0..15,
          lf_r1: 0..15,
          lf_c3: 0..15,
          lf_r3: 0..15
        }

  @doc """
  The reference-range key for an RFPLL reference frequency, per
  `ad9361_rfvco_tableindex()`.

  The argument is the **RFPLL reference**, i.e. after the divider/doubler — not
  the crystal.
  """
  @spec range(pos_integer()) :: 40 | 60 | 80
  def range(ref_clk_hz) when ref_clk_hz < 50_000_000, do: 40
  def range(ref_clk_hz) when ref_clk_hz <= 70_000_000, do: 60
  def range(_ref_clk_hz), do: 80

  @doc """
  The row for a VCO frequency: the first entry whose `vco_mhz` is not greater
  than the target, scanning descending.

  ADI's loop can run off the end of the table for a VCO below 5997 MHz and index
  out of bounds; `ad9361_calc_rfpll_int_divder` prevents that by construction
  since the VCO is always above 6 GHz. Here it returns `:error` instead of
  reading past the end, because a silent out-of-range read is worse than a
  failure.
  """
  @spec row(:fdd | :tdd, 40 | 60 | 80, pos_integer()) :: {:ok, row()} | {:error, term()}
  def row(mode, range, vco_hz) do
    vco_mhz = div(vco_hz, 1_000_000)

    case Enum.find(table(mode, range), &(&1.vco_mhz <= vco_mhz)) do
      nil -> {:error, {:vco_below_table, vco_mhz}}
      r -> {:ok, r}
    end
  end

  @doc "All 53 rows of one block, descending by `vco_mhz`."
  @spec table(:fdd | :tdd, 40 | 60 | 80) :: [row()]
  def table(:fdd, 40) do
    [
      %{vco_mhz: 12605, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 4, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 7, lf_c2: 14, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 12245, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 4, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 7, lf_c2: 14, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 11906, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 4, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 7, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 11588, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 4, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 8, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 11288, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 4, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 8, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 11007, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 4, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 9, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 10742, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 4, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 9, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 10492, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 10, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 10258, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 10, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 10036, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 11, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 9827, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 14, vco_varactor_reference: 12, charge_pump_current: 11, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 9631, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 13, vco_varactor_reference: 12, charge_pump_current: 12, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 9445, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 12, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 9269, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 13, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 9103, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 13, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 8946, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 14, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 8797, vco_output_level: 12, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 13, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 8655, vco_output_level: 12, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 14, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 8520, vco_output_level: 12, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 14, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 8392, vco_output_level: 12, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 15, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 8269, vco_output_level: 12, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 15, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 8153, vco_output_level: 12, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 16, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 8041, vco_output_level: 12, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 13, vco_varactor_reference: 12, charge_pump_current: 16, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 7934, vco_output_level: 11, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 16, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 7831, vco_output_level: 11, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 16, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 7733, vco_output_level: 10, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 13, vco_varactor_reference: 12, charge_pump_current: 16, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 7638, vco_output_level: 10, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 16, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 7547, vco_output_level: 10, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 17, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 7459, vco_output_level: 10, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 17, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 7374, vco_output_level: 10, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 14, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 7291, vco_output_level: 10, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 14, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 7212, vco_output_level: 10, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 14, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 7135, vco_output_level: 10, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 15, lf_c2: 15, lf_c1: 7, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 7061, vco_output_level: 10, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 15, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 6988, vco_output_level: 10, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 12, vco_varactor_reference: 14, charge_pump_current: 20, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 6918, vco_output_level: 9, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 15, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 6850, vco_output_level: 9, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 15, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 6784, vco_output_level: 9, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 13, vco_varactor_reference: 13, charge_pump_current: 15, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 6720, vco_output_level: 9, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 13, vco_varactor_reference: 13, charge_pump_current: 16, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 6658, vco_output_level: 8, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 15, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 6597, vco_output_level: 8, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 13, vco_varactor_reference: 13, charge_pump_current: 15, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 6539, vco_output_level: 8, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 13, vco_varactor_reference: 13, charge_pump_current: 15, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 6482, vco_output_level: 8, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 13, vco_varactor_reference: 13, charge_pump_current: 16, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 6427, vco_output_level: 7, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 15, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 6373, vco_output_level: 7, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 15, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 6321, vco_output_level: 7, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 15, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 6270, vco_output_level: 7, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 16, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 6222, vco_output_level: 7, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 16, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 6174, vco_output_level: 6, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 15, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 6128, vco_output_level: 6, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 15, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 6083, vco_output_level: 6, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 16, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 6040, vco_output_level: 6, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 16, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15},
      %{vco_mhz: 5997, vco_output_level: 6, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 16, lf_c2: 15, lf_c1: 6, lf_r1: 14, lf_c3: 5, lf_r3: 15}
    ]
  end

  def table(:fdd, 60) do
    [
      %{vco_mhz: 12605, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 4, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 13, lf_c2: 15, lf_c1: 12, lf_r1: 12, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 12245, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 4, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 13, lf_c2: 15, lf_c1: 12, lf_r1: 12, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 11906, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 4, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 13, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 11588, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 4, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 14, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 11288, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 5, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 15, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 11007, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 5, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 16, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 10742, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 5, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 16, lf_c2: 15, lf_c1: 12, lf_r1: 12, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 10492, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 17, lf_c2: 15, lf_c1: 12, lf_r1: 12, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 10258, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 18, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 10036, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 19, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 9827, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 14, vco_varactor_reference: 12, charge_pump_current: 20, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 9631, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 13, vco_varactor_reference: 12, charge_pump_current: 21, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 9445, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 22, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 9269, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 22, lf_c2: 15, lf_c1: 12, lf_r1: 12, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 9103, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 23, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 8946, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 24, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 8797, vco_output_level: 12, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 24, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 8655, vco_output_level: 12, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 25, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 8520, vco_output_level: 12, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 25, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 8392, vco_output_level: 12, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 26, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 8269, vco_output_level: 12, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 27, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 8153, vco_output_level: 12, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 28, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 8041, vco_output_level: 12, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 13, vco_varactor_reference: 12, charge_pump_current: 29, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 7934, vco_output_level: 11, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 28, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 7831, vco_output_level: 11, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 29, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 7733, vco_output_level: 10, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 13, vco_varactor_reference: 12, charge_pump_current: 28, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 7638, vco_output_level: 10, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 29, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 7547, vco_output_level: 10, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 29, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 7459, vco_output_level: 10, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 30, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 7374, vco_output_level: 10, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 24, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 7291, vco_output_level: 10, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 25, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 7212, vco_output_level: 10, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 25, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 7135, vco_output_level: 10, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 26, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 7061, vco_output_level: 10, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 26, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 6988, vco_output_level: 10, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 12, vco_varactor_reference: 14, charge_pump_current: 35, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 6918, vco_output_level: 9, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 12, vco_varactor_reference: 14, charge_pump_current: 33, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 6850, vco_output_level: 9, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 12, vco_varactor_reference: 14, charge_pump_current: 34, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 6784, vco_output_level: 9, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 11, vco_varactor_reference: 14, charge_pump_current: 35, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 6720, vco_output_level: 9, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 11, vco_varactor_reference: 14, charge_pump_current: 35, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 6658, vco_output_level: 8, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 26, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 6597, vco_output_level: 8, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 27, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 6539, vco_output_level: 8, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 27, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 6482, vco_output_level: 8, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 28, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 6427, vco_output_level: 7, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 27, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 6373, vco_output_level: 7, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 27, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 6321, vco_output_level: 7, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 27, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 6270, vco_output_level: 7, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 28, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 6222, vco_output_level: 7, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 28, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 6174, vco_output_level: 6, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 27, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 6128, vco_output_level: 6, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 27, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 6083, vco_output_level: 6, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 28, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 6040, vco_output_level: 6, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 28, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13},
      %{vco_mhz: 5997, vco_output_level: 6, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 29, lf_c2: 15, lf_c1: 13, lf_r1: 12, lf_c3: 5, lf_r3: 13}
    ]
  end

  def table(:fdd, 80) do
    [
      %{vco_mhz: 12605, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 4, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 7, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 12245, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 4, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 7, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 11906, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 4, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 7, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 11588, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 4, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 7, lf_c2: 14, lf_c1: 6, lf_r1: 14, lf_c3: 4, lf_r3: 14},
      %{vco_mhz: 11288, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 4, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 8, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 11007, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 4, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 8, lf_c2: 14, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 10742, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 4, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 9, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 10492, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 9, lf_c2: 14, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 10258, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 10, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 10036, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 10, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 9827, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 14, vco_varactor_reference: 12, charge_pump_current: 11, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 9631, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 13, vco_varactor_reference: 12, charge_pump_current: 11, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 9445, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 12, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 9269, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 12, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 9103, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 13, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 8946, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 13, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 8797, vco_output_level: 12, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 13, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 8655, vco_output_level: 12, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 14, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 8520, vco_output_level: 12, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 14, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 8392, vco_output_level: 12, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 15, lf_c2: 15, lf_c1: 7, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 8269, vco_output_level: 12, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 15, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 8153, vco_output_level: 12, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 15, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 8041, vco_output_level: 12, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 13, vco_varactor_reference: 12, charge_pump_current: 16, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 7934, vco_output_level: 11, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 15, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 7831, vco_output_level: 11, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 16, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 7733, vco_output_level: 10, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 13, vco_varactor_reference: 12, charge_pump_current: 15, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 7638, vco_output_level: 10, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 16, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 7547, vco_output_level: 10, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 16, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 7459, vco_output_level: 10, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 17, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 7374, vco_output_level: 10, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 13, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 7291, vco_output_level: 10, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 14, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 7212, vco_output_level: 10, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 14, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 7135, vco_output_level: 10, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 14, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 7061, vco_output_level: 10, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 15, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 6988, vco_output_level: 10, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 12, vco_varactor_reference: 14, charge_pump_current: 19, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 6918, vco_output_level: 9, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 14, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 6850, vco_output_level: 9, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 15, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 6784, vco_output_level: 9, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 13, vco_varactor_reference: 13, charge_pump_current: 15, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 6720, vco_output_level: 9, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 13, vco_varactor_reference: 13, charge_pump_current: 15, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 6658, vco_output_level: 8, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 15, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 6597, vco_output_level: 8, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 13, vco_varactor_reference: 13, charge_pump_current: 15, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 6539, vco_output_level: 8, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 13, vco_varactor_reference: 13, charge_pump_current: 15, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 6482, vco_output_level: 8, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 13, vco_varactor_reference: 13, charge_pump_current: 15, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 6427, vco_output_level: 7, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 15, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 6373, vco_output_level: 7, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 15, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 6321, vco_output_level: 7, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 15, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 6270, vco_output_level: 7, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 15, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 6222, vco_output_level: 7, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 16, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 6174, vco_output_level: 6, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 15, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 6128, vco_output_level: 6, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 15, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 6083, vco_output_level: 6, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 15, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 6040, vco_output_level: 6, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 16, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14},
      %{vco_mhz: 5997, vco_output_level: 6, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 16, lf_c2: 15, lf_c1: 6, lf_r1: 13, lf_c3: 5, lf_r3: 14}
    ]
  end

  def table(:tdd, 40) do
    [
      %{vco_mhz: 12605, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 4, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 27, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 12245, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 4, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 27, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 11906, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 4, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 26, lf_c2: 11, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 11588, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 4, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 28, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 11288, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 4, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 30, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 11007, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 4, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 32, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 10742, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 4, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 33, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 10492, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 35, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 10258, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 37, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 10036, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 38, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 9827, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 14, vco_varactor_reference: 12, charge_pump_current: 40, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 9631, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 13, vco_varactor_reference: 12, charge_pump_current: 42, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 9445, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 44, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 9269, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 45, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 9103, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 47, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 8946, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 49, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 8797, vco_output_level: 12, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 48, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 8655, vco_output_level: 12, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 50, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 8520, vco_output_level: 12, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 51, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 8392, vco_output_level: 12, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 53, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 8269, vco_output_level: 12, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 55, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 8153, vco_output_level: 12, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 56, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 8041, vco_output_level: 12, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 13, vco_varactor_reference: 12, charge_pump_current: 58, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 7934, vco_output_level: 11, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 57, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 7831, vco_output_level: 11, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 58, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 7733, vco_output_level: 10, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 13, vco_varactor_reference: 12, charge_pump_current: 56, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 7638, vco_output_level: 10, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 58, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 7547, vco_output_level: 10, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 59, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 7459, vco_output_level: 10, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 61, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 7374, vco_output_level: 10, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 49, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 7291, vco_output_level: 10, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 50, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 7212, vco_output_level: 10, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 51, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 7135, vco_output_level: 10, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 52, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 7061, vco_output_level: 10, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 53, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 6988, vco_output_level: 10, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 12, vco_varactor_reference: 14, charge_pump_current: 63, lf_c2: 11, lf_c1: 14, lf_r1: 12, lf_c3: 3, lf_r3: 13},
      %{vco_mhz: 6918, vco_output_level: 9, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 52, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 6850, vco_output_level: 9, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 53, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 6784, vco_output_level: 9, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 13, vco_varactor_reference: 13, charge_pump_current: 54, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 6720, vco_output_level: 9, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 13, vco_varactor_reference: 13, charge_pump_current: 56, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 6658, vco_output_level: 8, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 53, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 6597, vco_output_level: 8, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 13, vco_varactor_reference: 13, charge_pump_current: 54, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 6539, vco_output_level: 8, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 13, vco_varactor_reference: 13, charge_pump_current: 55, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 6482, vco_output_level: 8, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 13, vco_varactor_reference: 13, charge_pump_current: 56, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 6427, vco_output_level: 7, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 54, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 6373, vco_output_level: 7, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 54, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 6321, vco_output_level: 7, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 55, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 6270, vco_output_level: 7, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 56, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 6222, vco_output_level: 7, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 57, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 6174, vco_output_level: 6, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 54, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 6128, vco_output_level: 6, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 55, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 6083, vco_output_level: 6, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 56, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 6040, vco_output_level: 6, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 57, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 5997, vco_output_level: 6, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 58, lf_c2: 12, lf_c1: 15, lf_r1: 12, lf_c3: 4, lf_r3: 13}
    ]
  end

  def table(:tdd, 60) do
    [
      %{vco_mhz: 12605, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 4, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 26, lf_c2: 11, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 12245, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 4, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 26, lf_c2: 11, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 11906, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 4, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 26, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 11588, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 4, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 30, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 11288, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 4, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 32, lf_c2: 12, lf_c1: 15, lf_r1: 10, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 11007, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 4, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 31, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 10742, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 4, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 33, lf_c2: 12, lf_c1: 15, lf_r1: 10, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 10492, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 37, lf_c2: 12, lf_c1: 15, lf_r1: 10, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 10258, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 38, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 10036, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 38, lf_c2: 12, lf_c1: 15, lf_r1: 10, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 9827, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 14, vco_varactor_reference: 12, charge_pump_current: 42, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 9631, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 13, vco_varactor_reference: 12, charge_pump_current: 41, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 9445, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 45, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 9269, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 47, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 9103, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 46, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 8946, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 48, lf_c2: 12, lf_c1: 15, lf_r1: 10, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 8797, vco_output_level: 12, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 49, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 8655, vco_output_level: 12, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 51, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 8520, vco_output_level: 12, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 50, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 8392, vco_output_level: 12, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 52, lf_c2: 12, lf_c1: 15, lf_r1: 10, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 8269, vco_output_level: 12, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 56, lf_c2: 12, lf_c1: 15, lf_r1: 10, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 8153, vco_output_level: 12, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 55, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 8041, vco_output_level: 12, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 13, vco_varactor_reference: 12, charge_pump_current: 57, lf_c2: 12, lf_c1: 15, lf_r1: 10, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 7934, vco_output_level: 11, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 55, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 7831, vco_output_level: 11, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 57, lf_c2: 12, lf_c1: 15, lf_r1: 10, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 7733, vco_output_level: 10, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 13, vco_varactor_reference: 12, charge_pump_current: 55, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 7638, vco_output_level: 10, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 59, lf_c2: 12, lf_c1: 15, lf_r1: 10, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 7547, vco_output_level: 10, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 60, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 7459, vco_output_level: 10, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 48, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 7374, vco_output_level: 10, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 47, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 7291, vco_output_level: 10, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 49, lf_c2: 12, lf_c1: 15, lf_r1: 10, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 7212, vco_output_level: 10, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 50, lf_c2: 12, lf_c1: 15, lf_r1: 10, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 7135, vco_output_level: 10, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 52, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 7061, vco_output_level: 10, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 52, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 6988, vco_output_level: 10, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 12, vco_varactor_reference: 14, charge_pump_current: 63, lf_c2: 11, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 6918, vco_output_level: 9, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 12, vco_varactor_reference: 14, charge_pump_current: 63, lf_c2: 11, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 6850, vco_output_level: 9, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 12, vco_varactor_reference: 14, charge_pump_current: 63, lf_c2: 11, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 6784, vco_output_level: 9, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 11, vco_varactor_reference: 14, charge_pump_current: 63, lf_c2: 11, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 6720, vco_output_level: 9, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 11, vco_varactor_reference: 14, charge_pump_current: 63, lf_c2: 11, lf_c1: 14, lf_r1: 11, lf_c3: 3, lf_r3: 13},
      %{vco_mhz: 6658, vco_output_level: 8, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 12, vco_varactor_reference: 14, charge_pump_current: 63, lf_c2: 11, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 6597, vco_output_level: 8, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 11, vco_varactor_reference: 14, charge_pump_current: 63, lf_c2: 11, lf_c1: 14, lf_r1: 11, lf_c3: 3, lf_r3: 13},
      %{vco_mhz: 6539, vco_output_level: 8, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 11, vco_varactor_reference: 14, charge_pump_current: 63, lf_c2: 10, lf_c1: 14, lf_r1: 11, lf_c3: 3, lf_r3: 13},
      %{vco_mhz: 6482, vco_output_level: 8, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 11, vco_varactor_reference: 14, charge_pump_current: 63, lf_c2: 10, lf_c1: 14, lf_r1: 11, lf_c3: 3, lf_r3: 13},
      %{vco_mhz: 6427, vco_output_level: 7, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 54, lf_c2: 12, lf_c1: 15, lf_r1: 10, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 6373, vco_output_level: 7, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 53, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 6321, vco_output_level: 7, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 54, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 6270, vco_output_level: 7, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 55, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 6222, vco_output_level: 7, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 56, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 6174, vco_output_level: 6, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 53, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 6128, vco_output_level: 6, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 55, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 6083, vco_output_level: 6, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 55, lf_c2: 12, lf_c1: 15, lf_r1: 10, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 6040, vco_output_level: 6, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 56, lf_c2: 12, lf_c1: 15, lf_r1: 10, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 5997, vco_output_level: 6, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 57, lf_c2: 12, lf_c1: 15, lf_r1: 10, lf_c3: 4, lf_r3: 12}
    ]
  end

  def table(:tdd, 80) do
    [
      %{vco_mhz: 12605, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 4, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 21, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 12245, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 4, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 21, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 11906, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 4, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 20, lf_c2: 11, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 11588, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 4, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 22, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 11288, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 5, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 23, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 11007, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 5, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 25, lf_c2: 12, lf_c1: 15, lf_r1: 10, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 10742, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 5, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 26, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 10492, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 27, lf_c2: 11, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 10258, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 29, lf_c2: 12, lf_c1: 15, lf_r1: 10, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 10036, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 15, vco_varactor_reference: 12, charge_pump_current: 30, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 9827, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 14, vco_varactor_reference: 12, charge_pump_current: 31, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 9631, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 13, vco_varactor_reference: 12, charge_pump_current: 33, lf_c2: 12, lf_c1: 15, lf_r1: 10, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 9445, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 34, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 9269, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 35, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 9103, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 37, lf_c2: 12, lf_c1: 15, lf_r1: 10, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 8946, vco_output_level: 13, vco_varactor: 1, vco_bias_ref: 6, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 38, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 8797, vco_output_level: 12, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 37, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 8655, vco_output_level: 12, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 39, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 8520, vco_output_level: 12, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 40, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 8392, vco_output_level: 12, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 41, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 8269, vco_output_level: 12, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 43, lf_c2: 12, lf_c1: 15, lf_r1: 10, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 8153, vco_output_level: 12, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 44, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 8041, vco_output_level: 12, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 13, vco_varactor_reference: 12, charge_pump_current: 45, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 7934, vco_output_level: 11, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 44, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 7831, vco_output_level: 11, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 45, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 7733, vco_output_level: 10, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 13, vco_varactor_reference: 12, charge_pump_current: 44, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 7638, vco_output_level: 10, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 45, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 7547, vco_output_level: 10, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 46, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 7459, vco_output_level: 10, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 12, vco_varactor_reference: 12, charge_pump_current: 47, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 7374, vco_output_level: 10, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 38, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 7291, vco_output_level: 10, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 39, lf_c2: 12, lf_c1: 15, lf_r1: 10, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 7212, vco_output_level: 10, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 40, lf_c2: 12, lf_c1: 15, lf_r1: 10, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 7135, vco_output_level: 10, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 41, lf_c2: 12, lf_c1: 15, lf_r1: 10, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 7061, vco_output_level: 10, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 41, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 6988, vco_output_level: 10, vco_varactor: 1, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 12, vco_varactor_reference: 14, charge_pump_current: 54, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 6918, vco_output_level: 9, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 41, lf_c2: 12, lf_c1: 15, lf_r1: 10, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 6850, vco_output_level: 9, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 42, lf_c2: 12, lf_c1: 15, lf_r1: 10, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 6784, vco_output_level: 9, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 13, vco_varactor_reference: 13, charge_pump_current: 42, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 6720, vco_output_level: 9, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 13, vco_varactor_reference: 13, charge_pump_current: 43, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 6658, vco_output_level: 8, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 41, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 6597, vco_output_level: 8, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 13, vco_varactor_reference: 13, charge_pump_current: 42, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 6539, vco_output_level: 8, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 13, vco_varactor_reference: 13, charge_pump_current: 43, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 6482, vco_output_level: 8, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 2, vco_cal_offset: 13, vco_varactor_reference: 13, charge_pump_current: 44, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 6427, vco_output_level: 7, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 14, vco_varactor_reference: 13, charge_pump_current: 42, lf_c2: 12, lf_c1: 15, lf_r1: 10, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 6373, vco_output_level: 7, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 42, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 6321, vco_output_level: 7, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 43, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 6270, vco_output_level: 7, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 44, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 6222, vco_output_level: 7, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 45, lf_c2: 12, lf_c1: 15, lf_r1: 10, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 6174, vco_output_level: 6, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 42, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 6128, vco_output_level: 6, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 43, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 6083, vco_output_level: 6, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 44, lf_c2: 12, lf_c1: 15, lf_r1: 10, lf_c3: 4, lf_r3: 12},
      %{vco_mhz: 6040, vco_output_level: 6, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 44, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 13},
      %{vco_mhz: 5997, vco_output_level: 6, vco_varactor: 2, vco_bias_ref: 7, vco_bias_tcf: 3, vco_cal_offset: 15, vco_varactor_reference: 13, charge_pump_current: 45, lf_c2: 12, lf_c1: 15, lf_r1: 11, lf_c3: 4, lf_r3: 12}
    ]
  end
end
