defmodule Nervezynq.AD9363 do
  @moduledoc """
  AD9363 SPI control, composed in Elixir on top of the fabric's byte pipe.

      iex> Nervezynq.AD9363.release_reset()
      :ok
      iex> Nervezynq.AD9363.product_id()
      %{raw: 0x0A, family_ok: true, revision: 2}

  The fabric moves one byte per transfer with a chip-select hold bit and knows
  nothing about the AD936x command grammar. The 24-bit transaction is built
  here — which is the point: if the framing is wrong, fixing it costs a module
  reload, not a bitstream.

  Transaction format, taken from ADI's own driver rather than from memory
  (`no-OS/drivers/rf-transceiver/ad9361/ad9361.h`):

      #define AD_READ    (0 << 15)
      #define AD_WRITE   (1 << 15)
      #define AD_CNT(x)  ((((x) - 1) & 0x7) << 12)
      #define AD_ADDR(x) ((x) & 0x3FF)

  So the 16-bit instruction is:

      bit    15   R/W, 1 for a write
      bits 14:12  transfer length minus one
      bits 11:10  unused
      bits  9:0   register address

  followed by one data byte per transfer, MSB first, CS held across all three.

  Two things this corrected. The address is **10 bits, not 13** — the earlier
  implementation masked the high byte with 0x1F, which is harmless only while
  every address stays under 0x400 and silently walks into the count field
  above it. And the count occupies bits 14:12, which explains the earlier
  attempt to make a 32-clock read "spec-legal" by setting bit 13: that asked
  for a three-byte transfer, two bytes were sent, and the AD9363's SPI state
  machine was left mid-transaction until the next RESETB.
  """

  import Bitwise
  alias Nervezynq.Regs

  # Fabric register offsets and bit positions live in
  # `ehdl/designs/libresdr_radio/regmap.exs` and reach this module through
  # `Nervezynq.Regs`. AD9363 *chip* register numbers (`@reg_*`) are a different
  # namespace entirely -- those are the transceiver's, from the datasheet.

  @doc """
  Pulse RESETB low then high.

  CTRL1 resets to zero, so the transceiver is held in reset from power-up until
  this runs. Nothing on the SPI bus answers before it.
  """
  def release_reset() do
    # The shadow must start from what the fabric holds, or the first `spi_go`
    # flip may not produce an edge.
    Regs.sync_shadow()

    Regs.put(
      ctrl1: [ad9363_resetb: 0, ad9363_enable: 0, ad9363_txnrx: 0, ad9363_en_agc: 0]
    )
    Process.sleep(10)
    Regs.put(ctrl1: [ad9363_resetb: 1])
    Process.sleep(10)
    :ok
  end

  def enable_chip(), do: Regs.put(ctrl1: [ad9363_resetb: 1, ad9363_enable: 1])

  @doc """
  Shift one byte. `cs_hold` of 1 keeps CS asserted for the next byte.

  `go` and `done` are toggles rather than strobes: read the current state, flip
  the bit, poll until the far side's bit differs. An AXI register holds its
  value and has no write-pulse semantics, so a self-clearing `start` bit would
  need a second writer or a second round trip, and either can miss a transfer
  that completes faster than the poll.
  """
  def xfer(byte, cs_hold) do
    done0 = Regs.spi_done()

    # One bus write for the whole word: data, CS hold, and the `go` flip.
    Regs.put(ctrl0: [spi_tx_data: byte &&& 0xFF, spi_cs_hold: cs_hold], toggle: [:spi_go])

    await(done0, 500)
  end

  defp await(_done0, 0), do: {:error, :timeout}

  defp await(done0, n) do
    if Regs.spi_done() != done0 do
      {:ok, Regs.spi_rx_data()}
    else
      await(done0, n - 1)
    end
  end

  @doc """
  Read one register. Three bytes, 24 SPI clocks, exactly as the device expects.

  This used to clock a fourth byte and reassemble the answer with a one-bit
  shift, to work around `Hw.SPI.Master` sampling MISO one bit early. That
  workaround was worse than the bug: on an AD9363 a 32-clock transaction where
  24 are expected desynchronises the SPI state machine, and only a RESETB pulse
  recovers it. The reads afterwards come back as zeros, which looks exactly
  like a dead chip and cost some time to attribute correctly.

  The master now takes `MISO_SAMPLE_TRAILING`, and the radio design sets it,
  so the transaction is plain again.
  """
  def read(addr) do
    {:ok, _} = xfer(addr >>> 8 &&& 0x03, 1)
    {:ok, _} = xfer(addr &&& 0xFF, 1)
    xfer(0x00, 0)
  end

  def write(addr, val) do
    {:ok, _} = xfer(0x80 ||| (addr >>> 8 &&& 0x03), 1)
    {:ok, _} = xfer(addr &&& 0xFF, 1)
    {:ok, _} = xfer(val &&& 0xFF, 0)
    :ok
  end

  @doc """
  Write `bytes` starting at `addr`, as one transaction with a **descending**
  address.

  The AD936x auto-decrements: the first byte lands at `addr`, the next at
  `addr - 1`, and so on. That is not a convenience — the RF PLL frequency word
  must be written this way. ADI's `ad9361_spi_writem` does exactly this, and the
  synthesiser latches the new frequency on the write of the *last* (lowest)
  address, so splitting it into five single-byte writes would present four
  intermediate frequencies to a live PLL.

  `AD_CNT(x)` is `(((x) - 1) & 0x7) << 12` in the 16-bit instruction word, so the
  count occupies bits 6:4 of the high byte and the maximum is 8 bytes.

  Chip select is held across the whole transaction and released on the final
  byte, which is what `xfer/2`'s second argument controls.
  """
  def write_multi(addr, bytes) when is_list(bytes) and length(bytes) in 1..8 do
    n = length(bytes)
    {:ok, _} = xfer(0x80 ||| (n - 1 &&& 0x07) <<< 4 ||| (addr >>> 8 &&& 0x03), 1)
    {:ok, _} = xfer(addr &&& 0xFF, 1)

    {lead, [last]} = Enum.split(bytes, n - 1)
    Enum.each(lead, fn b -> {:ok, _} = xfer(b &&& 0xFF, 1) end)
    {:ok, _} = xfer(last &&& 0xFF, 0)
    :ok
  end

  @doc """
  Write a register and read it straight back.

  The write path has never been exercised — everything so far has been reads —
  and it is the prerequisite for every one of the several hundred writes an
  init sequence performs. Getting a silent no-op here would look like a chip
  that ignores configuration.
  """
  def write_verify(addr, val) do
    :ok = write(addr, val)

    case read(addr) do
      {:ok, ^val} -> {:ok, val}
      {:ok, other} -> {:error, {:readback_mismatch, expected: val, got: other}}
      other -> other
    end
  end

  # Addresses above 0xFF, so they exercise the instruction word's high byte in
  # a way a read of 0x037 never did.
  @reg_bandgap_config0 0x2A6
  @reg_bandgap_config1 0x2A8
  @reg_ctrl 0x3DF

  @doc """
  The first three register writes ADI's `ad9361_setup()` performs: enable the
  master bias and set the bandgap trim.

  Chosen as the write-path test precisely because they are what a real init
  does first, so proving the path and making forward progress are the same
  action. Nothing here starts a PLL or moves the state machine.
  """
  def enable_bias() do
    # REG_CTRL (0x3DF) bit 0 is NOT a readable storage bit, so it must not go
    # through write_verify. Measured on hardware:
    #
    #     wrote 0x01 -> read 0x00      wrote 0x11 -> read 0x10
    #     wrote 0x03 -> read 0x02      wrote 0x81 -> read 0x80
    #     wrote 0x0F -> read 0x0E      after RESETB, reads 0x01
    #
    # Every other bit in the register sticks; bit 0 alone never reads back as
    # set. It is a write-only enable whose reset default already reads 1. ADI's
    # `ad9361_setup()` uses a plain `ad9361_spi_write` here with no verification,
    # which is the tell — every register they genuinely verify goes through
    # `ad9361_spi_writef` or a readback.
    #
    # This was previously a `write_verify` and passed at cold boot by luck: the
    # reset default is 0x01, so an unlucky-but-plausible readback matched. Once
    # chip state differed it failed 50 times out of 50 and looked exactly like a
    # broken SPI write path, which cost a long detour into bitstream seeds and
    # place-and-route. The bandgap registers below do read back and keep their
    # verification.
    :ok = write(@reg_ctrl, 0x01)

    with {:ok, _} <- write_verify(@reg_bandgap_config0, 0x0E),
         {:ok, _} <- write_verify(@reg_bandgap_config1, 0x0E) do
      :ok
    end
  end

  @doc """
  Register 0x037, the product ID.

  The AD9363 shares a die with the AD9361 and reports the same family code, so
  the check is on the top five bits: `prod_id &&& 0xF8 == 0x08`. The low three
  bits are the silicon revision.
  """
  def product_id() do
    case read(0x037) do
      {:ok, v} ->
        %{
          raw: v,
          family_ok: (v &&& 0xF8) == 0x08,
          revision: v &&& 0x07
        }

      other ->
        other
    end
  end

  @doc """
  Read a block of registers and print them.

  The shape of the output is the diagnosis. All `00` or all `FF` means we are
  not talking to the chip at all — wrong pins, chip still in reset, or the
  framing is wrong. A varied pattern with plausible defaults means the control
  interface is alive even if individual values are surprising.
  """
  def dump(range \\ 0x000..0x03F) do
    range
    |> Enum.map(fn a ->
      {:ok, v} = read(a)
      {a, v}
    end)
    |> Enum.chunk_every(8)
    |> Enum.each(fn chunk ->
      {a0, _} = hd(chunk)
      addr = String.pad_leading(Integer.to_string(a0, 16), 3, "0")
      vals = Enum.map_join(chunk, " ", fn {_, v} -> String.pad_leading(Integer.to_string(v, 16), 2, "0") end)
      IO.puts("0x#{addr}: #{vals}")
    end)
  end

  # --- BBPLL ------------------------------------------------------------------
  #
  # Register addresses, bit positions and the whole sequence below are
  # transcribed from ad9361_bbpll_set_rate() in
  # no-OS/drivers/rf-transceiver/ad9361/ad9361.c, not reconstructed.

  @reg_sdm_ctrl_1 0x03F
  @reg_fract_bb_freq_word_1 0x041
  @reg_fract_bb_freq_word_2 0x042
  @reg_fract_bb_freq_word_3 0x043
  @reg_integer_bb_freq_word 0x044
  @reg_cp_current 0x046
  @reg_loop_filter_1 0x048
  @reg_loop_filter_2 0x049
  @reg_loop_filter_3 0x04A
  @reg_vco_ctrl 0x04B
  @reg_vco_program_1 0x04C
  @reg_vco_program_2 0x04D
  @reg_sdm_ctrl 0x04E
  @reg_ch_1_overflow 0x05E

  @init_bb_fo_cal 0x04
  @bbpll_reset_bar 0x01
  @bbpll_lock 0x80

  @bbpll_modulus 2_088_960
  @min_bbpll_freq 714_928_500
  @max_bbpll_freq 1_430_143_000

  # The board's VCTCXO. Trimmable via the DAC on VCTCXO_VFC, which is why the
  # reference is worth disciplining later — 802.11 wants tight frequency
  # accuracy and this is where it comes from.
  @refclk_hz 40_000_000

  @doc """
  Bring up the baseband PLL.

  Everything downstream hangs off this: DATA_CLK is derived from the BBPLL
  through the digital clock dividers, so until it locks the transceiver drives
  nothing at all and `Fabric.dump().status2` stays at zero.

  Default rate is 983.04 MHz — 24.576 x the 40 MHz reference, the standard
  choice that divides cleanly to the 61.44 MSPS family of sample rates and, ten
  octaves down, to the ones HaLow wants.

  Returns `{:ok, %{...}}` with the computed frequency word and the lock bit read
  back from `REG_CH_1_OVERFLOW`, or `{:error, :bbpll_not_locked}`. The lock bit
  is hardware's own opinion, which is the only reason to trust any of this.
  """
  def bbpll_set_rate(rate_hz \\ 983_040_000, parent_hz \\ @refclk_hz) do
    if rate_hz < @min_bbpll_freq or rate_hz > @max_bbpll_freq do
      {:error, {:bbpll_rate_out_of_range, rate_hz}}
    else
      do_bbpll_set_rate(rate_hz, parent_hz)
    end
  end

  defp do_bbpll_set_rate(rate_hz, parent_hz) do
    # Charge pump current: 25uA/LSB with a 25uA offset.
    tmp = div((rate_hz >>> 7) * 150, (parent_hz >>> 7) * 32)
    icp = min(max(round(tmp / 25) - 1, 1), 63)

    # Integer and fractional parts of rate / parent.
    integer = div(rate_hz, parent_hz)
    remainder = rem(rate_hz, parent_hz)
    fract = div(remainder * @bbpll_modulus + (parent_hz >>> 1), parent_hz)

    :ok = write(@reg_cp_current, icp)

    # Loop filter defaults, written high address to low as ADI's multi-byte
    # write does (the AD9361 auto-decrements); spelled out here as three
    # single-byte writes so the ordering is visible rather than implied.
    :ok = write(@reg_loop_filter_3, 0x35)
    :ok = write(@reg_loop_filter_2, 0x5B)
    :ok = write(@reg_loop_filter_1, 0xE8)

    # Enable calibration, count length 1024 for maximum accuracy.
    :ok = write(@reg_vco_ctrl, 0x80 ||| 3 <<< 5)
    # Calibration clock at REFCLK/4.
    :ok = write(@reg_sdm_ctrl, 0x10)

    :ok = write(@reg_integer_bb_freq_word, integer)
    :ok = write(@reg_fract_bb_freq_word_3, fract &&& 0xFF)
    :ok = write(@reg_fract_bb_freq_word_2, fract >>> 8 &&& 0xFF)
    :ok = write(@reg_fract_bb_freq_word_1, fract >>> 16 &&& 0xFF)

    # Start the frequency calibration, then clear the start bit.
    :ok = write(@reg_sdm_ctrl_1, @init_bb_fo_cal ||| @bbpll_reset_bar)
    :ok = write(@reg_sdm_ctrl_1, @bbpll_reset_bar)

    # Raise BBPLL KV and phase margin.
    :ok = write(@reg_vco_program_1, 0x86)
    :ok = write(@reg_vco_program_2, 0x01)
    :ok = write(@reg_vco_program_2, 0x05)

    Process.sleep(10)
    {:ok, overflow} = read(@reg_ch_1_overflow)
    locked = (overflow &&& @bbpll_lock) != 0

    result = %{
      rate_hz: rate_hz,
      integer: integer,
      fract: fract,
      icp: icp,
      overflow_reg: overflow,
      locked: locked
    }

    if locked, do: {:ok, result}, else: {:error, {:bbpll_not_locked, result}}
  end


  # --- reference clock path ---------------------------------------------------

  @reg_clock_enable 0x009
  @reg_ref_divide_config_1 0x2AB
  @reg_ref_divide_config_2 0x2AC

  @xo_bypass 0x10
  @digital_power_up 0x04
  @clock_enable_dflt 0x02
  @bbpll_enable 0x01

  @rx_ref_reset_bar 0x02
  @tx_ref_reset_bar 0x10

  @doc """
  Read-modify-write a bit field. ADI's `ad9361_spi_writef`.
  """
  def writef(addr, mask, val) do
    {:ok, cur} = read(addr)
    shift = trailing_zeros(mask)
    write(addr, (cur &&& bnot(mask) &&& 0xFF) ||| (val <<< shift &&& mask))
  end

  defp trailing_zeros(mask), do: trailing_zeros(mask, 0)
  defp trailing_zeros(mask, n) when (mask &&& 1) == 1, do: n
  defp trailing_zeros(mask, n), do: trailing_zeros(mask >>> 1, n + 1)

  @doc """
  Release the reference dividers from reset and enable the clock block.

  This is what was missing when the BBPLL refused to lock. Two separate
  omissions, and the second is the one that mattered:

    * `RX_REF_RESET_BAR` / `TX_REF_RESET_BAR` hold the reference divider block
      in reset out of power-on, so the 40 MHz reference never reaches the PLL.
    * `REG_CLOCK_ENABLE` carries `BBPLL_ENABLE` — the PLL itself is powered
      down until asked. Programming a frequency word into a disabled PLL
      succeeds at every write and locks nothing, which is exactly the
      `overflow_reg: 0` we saw.

  `xo_bypass` selects where the reference comes from. The LibreSDR feeds a
  40 MHz VCTCXO into the XTAL pins with a tuning DAC on `VCTCXO_VFC`, which
  suggests an external clock (bypass) rather than the AD9363 driving a bare
  crystal through its own DCXO. That is an inference from the schematic, not a
  measurement, so `bring_up/1` tries it and falls back.
  """
  def clock_path_setup(xo_bypass \\ true) do
    :ok = writef(@reg_ref_divide_config_1, @rx_ref_reset_bar, 1)
    :ok = writef(@reg_ref_divide_config_2, @tx_ref_reset_bar, 1)
    # Feedback delay, both doublers.
    :ok = writef(@reg_ref_divide_config_2, 0x03 <<< 0, 3)
    :ok = writef(@reg_ref_divide_config_2, 0x03 <<< 5, 3)

    bypass = if xo_bypass, do: @xo_bypass, else: 0
    write(@reg_clock_enable, @digital_power_up ||| @clock_enable_dflt ||| @bbpll_enable ||| bypass)
  end

  @doc """
  Reset, bias, clock path, BBPLL.

  Tries the external-clock (XO bypass) reference first and falls back to the
  internal oscillator path, reporting which one locked. Guessing wrong is not
  destructive — the PLL simply does not lock — so trying is cheaper than
  reasoning about it from the schematic.
  """
  def bring_up(xo_bypass \\ :auto)

  def bring_up(:auto) do
    case bring_up(true) do
      {:ok, r} -> {:ok, Map.put(r, :xo_bypass, true)}
      _ ->
        case bring_up(false) do
          {:ok, r} -> {:ok, Map.put(r, :xo_bypass, false)}
          err -> err
        end
    end
  end

  def bring_up(xo_bypass) when is_boolean(xo_bypass) do
    :ok = release_reset()
    :ok = enable_bias()
    :ok = clock_path_setup(xo_bypass)
    bbpll_set_rate()
  end

  # --- BIST / data port test ---------------------------------------------------
  #
  # Transcribed from `ad9361_bist_prbs()` (ad9361.c:1176) and
  # `ad9361_bist_tone()` (ad9361.c:1221), with the bit positions from ad9361.h
  # around line 2755. Not reconstructed from memory.
  #
  # The point of all of this is to put a *known* signal into the digital receive
  # path, downstream of the RF, so that anything the fabric captures can be
  # checked against a prediction. Without it the LVDS bus carries whatever the
  # receiver happens to hear, and "the front end works" is not a falsifiable
  # claim.

  @reg_bist_config 0x3F4
  @reg_observe_config 0x3F5
  @reg_bist_data_port_test 0x3F6

  @bist_enable 0x01

  # ad9361.h names bit 1 `TONE_PRBS`, which reads as though setting it selected
  # the PRBS. It does the opposite: `ad9361_bist_prbs()` leaves it clear and
  # `ad9361_bist_tone()` sets it. Named here for what the hardware does, because
  # the ADI name has exactly the wrong polarity for anyone reading it fresh.
  @bist_tone_select 0x02

  # BIST_CTRL_POINT<1:0>, bits 3:2. 0 injects at the transmit side, 2 at the
  # receive side. The receive injection point is the one that matters here: it
  # feeds the digital receive data path, so the pattern arrives over the same
  # LVDS bus, lanes and DDR edges that real samples will.
  defp bist_ctrl_point(:tx), do: 0 <<< 2
  defp bist_ctrl_point(:rx), do: 2 <<< 2

  @doc """
  Inject a PRBS at the transmit or receive control point, or disable BIST.

  Returns `{:ok, reg}` with the value read back from `REG_BIST_CONFIG`, not
  merely `:ok`. Every register access here goes through `write_verify/2` for the
  same reason the rest of this module does: a write that silently does nothing
  and a chip that ignores the mode both look like "BIST is off", and only the
  readback separates them.

  The polynomial is deliberately not asserted anywhere in this module. ADI's
  checker lives in their HDL rather than in `no-OS`, so rather than commit to
  PN9 or PN15 or PN23 from memory, `Nervezynq.LVDSProbe` fits the LFSR to the
  captured stream and reports what it found.
  """
  def bist_prbs(:disable), do: write_verify(@reg_bist_config, 0x00)

  def bist_prbs(where) when where in [:tx, :rx] do
    write_verify(@reg_bist_config, bist_ctrl_point(where) ||| @bist_enable)
  end

  @doc """
  Inject a BIST tone.

  * `tone` is the raw frequency index 0..3. ADI's driver computes it as
    `round(freq * 32 / Fs) - 1`, so index `n` is `Fs * (n + 1) / 32` and index 0
    is `Fs/32` — a period of exactly 32 samples.
  * `level_db` is attenuation below full scale: 0, 6, 12 or 18.
  * `mask` is four bits — channel 1 I, channel 1 Q, channel 2 I, channel 2 Q,
    from bit 0 up. ADI shifts it into bits 5:2 of `REG_BIST_AND_DATA_PORT_TEST_CONFIG`.

  A period-32 tone is far more useful than a PRBS as a *first* test, because it
  makes the sample word take a small, finite set of values. That turns the
  captured data into something with a testable shape even when it is being read
  through a path that cannot be trusted to deliver consecutive samples.
  """
  def bist_tone(where, tone \\ 0, level_db \\ 0, mask \\ 0)

  def bist_tone(:disable, _tone, _level_db, _mask) do
    {:ok, _} = write_verify(@reg_bist_data_port_test, 0x00)
    write_verify(@reg_bist_config, 0x00)
  end

  def bist_tone(where, tone, level_db, mask) when where in [:tx, :rx] do
    reg =
      bist_ctrl_point(where)
      |> bor(@bist_enable)
      |> bor(@bist_tone_select)
      |> bor((div(level_db, 6) &&& 0x3) <<< 4)
      |> bor((tone &&& 0x3) <<< 6)

    {:ok, _} = write_verify(@reg_bist_data_port_test, (mask <<< 2) &&& 0x3C)
    write_verify(@reg_bist_config, reg)
  end

  @doc """
  Read back the three BIST registers, decoded.

  Cheap, and worth calling after every mode change. `REG_BIST_CONFIG` reading
  back as zero when a tone was requested is the difference between "the tone is
  running and the fabric cannot see it" and "the tone was never enabled" — two
  conclusions that the captured data alone will not distinguish.
  """
  def bist_state() do
    with {:ok, cfg} <- read(@reg_bist_config),
         {:ok, obs} <- read(@reg_observe_config),
         {:ok, dpt} <- read(@reg_bist_data_port_test) do
      {:ok,
       %{
         bist_config: cfg,
         observe_config: obs,
         data_port_test: dpt,
         enabled: (cfg &&& @bist_enable) == 1,
         mode: if((cfg &&& @bist_tone_select) != 0, do: :tone, else: :prbs),
         ctrl_point: if((cfg >>> 2 &&& 0x3) == 2, do: :rx, else: :tx),
         tone_index: cfg >>> 6 &&& 0x3,
         tone_level_db: (cfg >>> 4 &&& 0x3) * 6,
         mask: dpt >>> 2 &&& 0x0F
       }}
    end
  end

  # --- parallel (digital data) port --------------------------------------------
  #
  # Transcribed from `ad9361_pp_port_setup()` (ad9361.c:3659) and the field
  # packing in `ad9361_api.c:400-433`.
  #
  # This was the missing piece. Out of reset `REG_PARALLEL_PORT_CONF_3` reads
  # 0x04 — `SINGLE_PORT_MODE`, with `LVDS_MODE` clear — so the AD9363 comes up
  # driving a single-port CMOS bus. The LibreSDR wires the port as seven LVDS
  # pairs. In CMOS mode the `_N` pins are not the complements of the `_P` pins,
  # they are separate bus bits, so every `IBUFDS` in the fabric is comparing two
  # unrelated CMOS signals against each other. The result captures perfectly
  # stably and means nothing, which is why `STATUS3` sat at a constant 0xFC0
  # through a BIST tone, a masked tone and a PRBS alike.

  @reg_rx_clock_data_delay 0x006
  @reg_tx_clock_data_delay 0x007
  @reg_parallel_port_conf_1 0x010
  @reg_parallel_port_conf_2 0x011
  @reg_parallel_port_conf_3 0x012
  @reg_lvds_bias_ctrl 0x03C
  @reg_lvds_invert_ctrl1 0x03D
  @reg_lvds_invert_ctrl2 0x03E

  @lvds_mode 0x10
  @half_duplex_mode 0x08
  @single_port_mode 0x04
  @single_data_rate 0x20
  @rx_on_chip_term 0x20

  @doc """
  Put the digital data port into LVDS mode.

  Defaults follow ADI's own: `pp_conf[0] = 0xC0` (I/Q swapped on both
  directions, which is also the reset value), `pp_conf[1] = 0x00`,
  `pp_conf[2] = LVDS_MODE`, LVDS bias 150 mV with the receive-side on-chip
  termination enabled.

  ADI's sanity check is reproduced rather than assumed: setting `LVDS_MODE`
  clears `HALF_DUPLEX_MODE`, `SINGLE_DATA_RATE` and `SINGLE_PORT_MODE`, because
  the LVDS port is always full duplex, dual data rate and dual port.

  ## The delays are a tuning parameter, not a setting

  `REG_RX_CLOCK_DATA_DELAY` is written as zero here. That is a starting point,
  not a considered value — it is the parameter ADI's `ad9361_dig_tune()` sweeps
  against the PRBS checker to find the centre of the eye, and we have no
  checker yet. Sweeping it is the first thing to do once the capture buffer
  exists, and until then no delay value has been shown to be better than any
  other.

  Note `RX_ON_CHIP_TERM` terminates the AD9363's *own* receive pins, which are
  the FPGA's transmit direction. It does nothing for the AD9363-to-FPGA path.
  That direction has to be terminated at the FPGA, and openXC7 ignores
  `DIFF_TERM` — so the receive path is still unterminated, and that remains the
  open question this whole exercise exists to answer.
  """
  def data_port_setup(opts \\ []) do
    pp1 = Keyword.get(opts, :pp_conf_1, 0xC0)
    pp2 = Keyword.get(opts, :pp_conf_2, 0x00)
    pp3 = Keyword.get(opts, :pp_conf_3, @lvds_mode)
    # DATA_CLK_DELAY=0, RX_DATA_DELAY=10. Measured, not guessed: an eye diagram
    # over all 256 combinations of the two fields (LVDSProbe.eye_sweep/1) gives a
    # broad diagonal plateau of 94/256 cells with zero slot errors, and this sits
    # inside it. At this setting a 1024-sample capture shows 256/256 slots correct
    # and all twelve captured bits within 0.012 of each other.
    #
    # The old default of 0x00 sat on the eye edge: 253/256 slots, and a per-lane
    # spread of 0.41 to 0.51 that looked like a termination problem and was
    # actually a timing one.
    rx_delay = Keyword.get(opts, :rx_clk_data_delay, 0x0A)
    # FB_CLK_DELAY=0, TX_DATA_DELAY=8. Measured 2026-09-26 on dr-a through
    # the chip's data-port loopback (scripts/tx_loop.exs, TxLoop.eye/2): a
    # diagonal plateau of 105/256 cells with every field of every frame
    # correct, bounded below by data_delay - fb_clk_delay >= 2; 0x08 sits six
    # steps inside that edge and passed 5 x 1000 frames. 0x00 (the old
    # default) is outside the eye: with ODDR launching data and FB_CLK on
    # the same edge, one edge polarity's words arrived corrupted.
    tx_delay = Keyword.get(opts, :tx_clk_data_delay, 0x08)
    # LVDS_BIAS(1) is 150 mV: ADI computes the field as (mV - 75) / 75.
    bias = Keyword.get(opts, :lvds_bias_ctrl, @rx_on_chip_term ||| 0x01)

    pp3 =
      if (pp3 &&& @lvds_mode) != 0 do
        pp3 &&& bnot(@half_duplex_mode ||| @single_data_rate ||| @single_port_mode) &&& 0xFF
      else
        pp3
      end

    with {:ok, _} <- write_verify(@reg_parallel_port_conf_1, pp1),
         {:ok, _} <- write_verify(@reg_parallel_port_conf_2, pp2),
         {:ok, _} <- write_verify(@reg_parallel_port_conf_3, pp3),
         {:ok, _} <- write_verify(@reg_rx_clock_data_delay, rx_delay),
         {:ok, _} <- write_verify(@reg_tx_clock_data_delay, tx_delay),
         {:ok, _} <- write_verify(@reg_lvds_bias_ctrl, bias),
         {:ok, _} <- write_verify(@reg_lvds_invert_ctrl1, 0x00),
         {:ok, _} <- write_verify(@reg_lvds_invert_ctrl2, 0x00) do
      {:ok,
       %{
         pp_conf_1: pp1,
         pp_conf_2: pp2,
         pp_conf_3: pp3,
         lvds_mode: (pp3 &&& @lvds_mode) != 0,
         rx_clk_data_delay: rx_delay,
         lvds_bias_ctrl: bias
       }}
    end
  end

  @doc "Read back the data port registers, decoded."
  def data_port_state() do
    with {:ok, pp1} <- read(@reg_parallel_port_conf_1),
         {:ok, pp2} <- read(@reg_parallel_port_conf_2),
         {:ok, pp3} <- read(@reg_parallel_port_conf_3),
         {:ok, rxd} <- read(@reg_rx_clock_data_delay),
         {:ok, bias} <- read(@reg_lvds_bias_ctrl) do
      {:ok,
       %{
         pp_conf_1: pp1,
         pp_conf_2: pp2,
         pp_conf_3: pp3,
         lvds_mode: (pp3 &&& @lvds_mode) != 0,
         single_port: (pp3 &&& @single_port_mode) != 0,
         single_data_rate: (pp3 &&& @single_data_rate) != 0,
         rx_data_clk_delay: rxd >>> 4 &&& 0xF,
         rx_data_delay: rxd &&& 0xF,
         lvds_bias_ctrl: bias
       }}
    end
  end
end
