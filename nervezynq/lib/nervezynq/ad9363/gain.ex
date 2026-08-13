defmodule Nervezynq.AD9363.Gain do
  @moduledoc """
  RX gain: load the band's gain table, put the receiver in manual gain control,
  and command an index.

  Transcribed from `ad9361_load_gt()` (ad9361.c:1432),
  `ad9361_load_mixer_gm_subtable()` (:1591) and the `REG_AGC_CONFIG_1` gain-control
  mode field.

  ## Why this exists

  The AD9363's receive gain is an index into a table **the host must load first**.
  Nothing about that is optional, and `ad9361_load_gt` sits inside ADI's own
  LO-setting path precisely because the table is band-dependent. This project
  programmed the LO without it and measured a noise floor that varied with the LO
  across 700–3500 MHz with no peak in the WiFi band — which is what an unloaded,
  band-wrong gain table looks like.

  ## The write protocol is a clocked indexed port, not a register block

  Each of the 77 entries is written by driving an address register, three data
  registers, then toggling `WRITE_GAIN_TABLE` while `START_GAIN_TABLE_CLOCK` is
  held. ADI then issues **two dummy writes to the read-data register** per entry,
  commented "Dummy Write to delay 3 ADCCLK/16 cycles" and "delay ~1u". Those are
  timing, not data: the gain table has its own clock domain and the writes must be
  paced. They are reproduced here rather than replaced with a sleep, because a
  sleep in the BEAM is not bounded below in the same way and the delay ADI chose is
  expressed in ADC clocks.

  The sequence brackets the whole load with clock-start and clock-stop writes to
  `REG_GAIN_TABLE_CONFIG`, and there is a deliberate clear-write step before the
  stop. Getting the bracketing wrong leaves the table clock running.

  ## Gm sub-table is written backwards

  `ad9361_load_mixer_gm_subtable` walks `i` upward while the address counts
  **down** from 16 (`--addr`), so `gm_st_gain[0]` lands at address 15. That looks
  like a bug and is not; it is reproduced exactly. There is also a bias word
  written as 0 for every entry, which is easy to miss between the gain and control
  words.

  ## What is still missing after this

  `rx_bb_analog_filter_calib` (baseband LPF corner), `rx_tia_calib` and
  `rx_adc_setup` are not transcribed. Gain being correct does not make the
  receiver correct — it makes it possible to tell signal from noise, which is the
  immediate question.
  """

  import Bitwise
  alias Nervezynq.AD9363
  alias Nervezynq.AD9363.GainTable

  @reg_agc_config_1 0x0FA
  @reg_agc_config_2 0x0FB
  @reg_max_lmt_full_gain 0x0FD
  @reg_rx1_manual_lmt_full_gain 0x109
  @reg_rx2_manual_lmt_full_gain 0x10C

  @reg_gain_table_address 0x130
  @reg_gain_table_write_data1 0x131
  @reg_gain_table_write_data2 0x132
  @reg_gain_table_write_data3 0x133
  @reg_gain_table_read_data1 0x134
  @reg_gain_table_config 0x137

  @reg_gm_sub_table_address 0x138
  @reg_gm_sub_table_gain_write 0x139
  @reg_gm_sub_table_bias_write 0x13A
  @reg_gm_sub_table_ctrl_write 0x13B
  @reg_gm_sub_table_gain_read 0x13C
  @reg_gm_sub_table_config 0x13F

  @agc_use_full_gain_table 0x08
  @write_gain_table 0x04
  @start_gain_table_clock 0x02
  @write_gm_sub_table 0x04
  @start_gm_sub_table_clock 0x02

  @rx_full_tbl_idx_mask 0x7F
  @rx_gain_ctl_mask 0x03

  # REG_AGC_CONFIG_1: RX1 in bits 1:0, RX2 in bits 3:2.
  @rx_gain_ctl_mgc 0x00
  @rx_gain_ctl_agc_fast 0x01
  @rx_gain_ctl_agc_slow 0x02
  @rx_gain_ctl_agc_slow_hybrid 0x03

  # RECEIVER_SELECT(x) = (x & 0x3) << 3. GT_RX1 = 1, GT_RX2 = 2, so both = 3.
  @gt_rx1 1
  @gt_rx2 2
  @gt_both 3

  @doc """
  Load the gain table for `freq_hz` into both receivers.

  ADI guards this with `phy->current_table == band` and skips the reload. There is
  no such cache here: the chip is the only state that matters and a reload is
  cheap next to being wrong about what is in it.
  """
  def load(freq_hz, dest \\ @gt_both) do
    with {:ok, band} <- GainTable.band(freq_hz) do
      rows = GainTable.rows(band)
      index_max = length(rows)

      # Full table, not split.
      :ok = AD9363.writef(@reg_agc_config_2, @agc_use_full_gain_table, 1)
      :ok = AD9363.write(@reg_max_lmt_full_gain, index_max - 1)

      :ok = AD9363.write(@reg_gain_table_config, @start_gain_table_clock ||| receiver(dest))

      rows
      |> Enum.with_index()
      |> Enum.each(fn {{w1, w2, w3, _db}, i} ->
        :ok = AD9363.write(@reg_gain_table_address, i)
        :ok = AD9363.write(@reg_gain_table_write_data1, w1)
        :ok = AD9363.write(@reg_gain_table_write_data2, w2)
        :ok = AD9363.write(@reg_gain_table_write_data3, w3)

        :ok =
          AD9363.write(
            @reg_gain_table_config,
            @start_gain_table_clock ||| @write_gain_table ||| receiver(dest)
          )

        # ADI's two paced dummy writes. Timing, not data.
        :ok = AD9363.write(@reg_gain_table_read_data1, 0)
        :ok = AD9363.write(@reg_gain_table_read_data1, 0)
      end)

      # Clear the write bit, pace, then stop the table clock.
      :ok = AD9363.write(@reg_gain_table_config, @start_gain_table_clock ||| receiver(dest))
      :ok = AD9363.write(@reg_gain_table_read_data1, 0)
      :ok = AD9363.write(@reg_gain_table_read_data1, 0)
      :ok = AD9363.write(@reg_gain_table_config, 0)

      {:ok, %{band: band, entries: index_max, gain_db_range: gain_range(rows)}}
    end
  end

  defp receiver(dest), do: (dest &&& 0x03) <<< 3

  defp gain_range(rows) do
    dbs = Enum.map(rows, fn {_, _, _, db} -> db end)
    {Enum.min(dbs), Enum.max(dbs)}
  end

  @doc """
  The mixer Gm sub-table. Sixteen entries, written with a **descending** address.
  """
  def load_mixer_gm_subtable() do
    gains = GainTable.gm_gain()
    ctrls = GainTable.gm_ctrl()

    :ok = AD9363.write(@reg_gm_sub_table_config, @start_gm_sub_table_clock)

    Enum.zip(gains, ctrls)
    |> Enum.with_index()
    |> Enum.each(fn {{gain, ctrl}, i} ->
      # addr counts down from 16 as i counts up, so entry 0 lands at address 15.
      :ok = AD9363.write(@reg_gm_sub_table_address, length(gains) - 1 - i)
      :ok = AD9363.write(@reg_gm_sub_table_bias_write, 0)
      :ok = AD9363.write(@reg_gm_sub_table_gain_write, gain)
      :ok = AD9363.write(@reg_gm_sub_table_ctrl_write, ctrl)

      :ok =
        AD9363.write(
          @reg_gm_sub_table_config,
          @write_gm_sub_table ||| @start_gm_sub_table_clock
        )

      :ok = AD9363.write(@reg_gm_sub_table_gain_read, 0)
      :ok = AD9363.write(@reg_gm_sub_table_gain_read, 0)
    end)

    :ok = AD9363.write(@reg_gm_sub_table_config, @start_gm_sub_table_clock)
    :ok = AD9363.write(@reg_gm_sub_table_gain_read, 0)
    :ok = AD9363.write(@reg_gm_sub_table_gain_read, 0)
    :ok = AD9363.write(@reg_gm_sub_table_config, 0)

    {:ok, %{entries: length(gains)}}
  end

  @doc """
  Set the gain-control mode for both receivers.

  `:mgc` is manual — the index written by `set_index/2` takes effect and stays.
  The AGC modes exist for completeness; nothing here has exercised them, and an
  AGC that is hunting makes a power measurement meaningless, so manual is the
  right mode for answering "is there a signal".
  """
  def set_mode(mode \\ :mgc) do
    code =
      case mode do
        :mgc -> @rx_gain_ctl_mgc
        :agc_fast -> @rx_gain_ctl_agc_fast
        :agc_slow -> @rx_gain_ctl_agc_slow
        :agc_slow_hybrid -> @rx_gain_ctl_agc_slow_hybrid
      end

    :ok = AD9363.writef(@reg_agc_config_1, @rx_gain_ctl_mask, code)
    :ok = AD9363.writef(@reg_agc_config_1, @rx_gain_ctl_mask <<< 2, code)
    {:ok, mode}
  end

  @doc "Command a raw table index on both receivers."
  def set_index(index) when index >= 0 and index < 128 do
    :ok = AD9363.writef(@reg_rx1_manual_lmt_full_gain, @rx_full_tbl_idx_mask, index)
    :ok = AD9363.writef(@reg_rx2_manual_lmt_full_gain, @rx_full_tbl_idx_mask, index)
    {:ok, index}
  end

  @doc """
  Command a gain in dB, resolved against the band's table.

  Returns the index used and the gain actually achieved, which will differ from
  the request — the table is quantised in roughly 1 dB steps and its ends clamp.
  """
  def set_gain_db(freq_hz, db) do
    with {:ok, band} <- GainTable.band(freq_hz),
         {:ok, {index, actual}} <- GainTable.index_for_gain(band, db),
         {:ok, _} <- set_index(index) do
      {:ok, %{index: index, requested_db: db, actual_db: actual, band: band}}
    end
  end

  @doc "What the chip currently reports about RX gain."
  def state() do
    with {:ok, agc1} <- AD9363.read(@reg_agc_config_1),
         {:ok, agc2} <- AD9363.read(@reg_agc_config_2),
         {:ok, max_idx} <- AD9363.read(@reg_max_lmt_full_gain),
         {:ok, rx1} <- AD9363.read(@reg_rx1_manual_lmt_full_gain),
         {:ok, rx2} <- AD9363.read(@reg_rx2_manual_lmt_full_gain) do
      {:ok,
       %{
         rx1_mode: decode_mode(agc1 &&& @rx_gain_ctl_mask),
         rx2_mode: decode_mode(agc1 >>> 2 &&& @rx_gain_ctl_mask),
         full_gain_table: (agc2 &&& @agc_use_full_gain_table) != 0,
         max_index: max_idx,
         rx1_index: rx1 &&& @rx_full_tbl_idx_mask,
         rx2_index: rx2 &&& @rx_full_tbl_idx_mask
       }}
    end
  end

  defp decode_mode(0x00), do: :mgc
  defp decode_mode(0x01), do: :agc_fast
  defp decode_mode(0x02), do: :agc_slow
  defp decode_mode(0x03), do: :agc_slow_hybrid
end
