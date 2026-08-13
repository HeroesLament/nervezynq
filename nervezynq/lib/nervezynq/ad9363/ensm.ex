defmodule Nervezynq.AD9363.ENSM do
  @moduledoc """
  The Enable State Machine, the RX/TX channel enables and the RF port select.

  Transcribed from `ad9361_set_ensm_mode()` (ad9361.c:4894),
  `ad9361_ensm_set_state()` (4420), `ad9361_en_dis_rx()` / `ad9361_en_dis_tx()`
  (1066, 1083) and `ad9361_rf_port_setup()` (3623).

  ## This is what actually starts the data port

  Everything before this — SPI, bias, BBPLL, the parallel port mode, the clock
  chain — configures a transceiver that is still sitting in its reset state and
  driving nothing but DATA_CLK. The ENSM is the part that turns the receive
  path on, and until it reaches `RX` (or `FDD`) the LVDS data lanes are idle.

  That is the whole explanation for the constant `0xFC0` the fabric was reading:
  six undriven, unterminated differential pairs picking up the one signal that
  *was* being driven.

  ## Transitions are not arbitrary

  In TDD the only legal way into `RX` or `TX` is from `ALERT`. ADI enforces this
  by returning `-EINVAL` and then, if the current state is not `ALERT`, forcing
  `ALERT` first and polling `REG_STATE` until it lands. That fallback is
  reproduced here as an explicit two-step, because a state machine that
  silently refuses a transition and leaves you in the old state is exactly the
  kind of failure that reads as "the hardware is broken" downstream.
  """

  import Bitwise
  alias Nervezynq.AD9363

  @reg_tx_enable_filter_ctrl 0x002
  @reg_rx_enable_filter_ctrl 0x003
  @reg_input_select 0x004
  @reg_ensm_mode 0x013
  @reg_ensm_config_1 0x014
  @reg_ensm_config_2 0x015
  @reg_state 0x017

  # REG_ENSM_CONFIG_1
  @enable_rx_data_port_for_cal 0x80
  @force_rx_on 0x40
  @force_tx_on 0x20
  @enable_ensm_pin_ctrl 0x10
  @level_mode 0x08
  @force_alert_state 0x04
  @to_alert 0x01

  # REG_ENSM_CONFIG_2
  @dual_synth_mode 0x04
  @synth_enable_pin_ctrl_mode 0x08
  @fdd_external_ctrl_enable 0x80
  @txnrx_spi_ctrl 0x10
  @rx_synth_ready_mask 0x02
  @tx_synth_ready_mask 0x01
  # POWER_DOWN_RX_SYNTH | POWER_DOWN_TX_SYNTH | RX_SYNTH_READY_MASK | TX_SYNTH_READY_MASK
  @ensm_config_2_preserve 0x63

  @states %{
    sleep_wait: 0x0,
    alert: 0x5,
    tx: 0x6,
    tx_flush: 0x7,
    rx: 0x8,
    rx_flush: 0x9,
    fdd: 0xA,
    fdd_flush: 0xB
  }

  @doc "The ENSM state the chip reports, as an atom plus the raw nibble."
  def state() do
    with {:ok, v} <- AD9363.read(@reg_state) do
      raw = v &&& 0x0F
      name = Enum.find_value(@states, :unknown, fn {k, n} -> if n == raw, do: k end)
      {:ok, %{state: name, raw: raw, reg: v}}
    end
  end

  @doc """
  Select FDD or TDD.

  `REG_ENSM_CONFIG_2` is read-modify-written rather than overwritten: the synth
  power-down and ready-mask bits live in the same register and are owned by the
  synthesiser setup, not by us.
  """
  def set_mode(fdd?, opts \\ []) do
    pinctrl = Keyword.get(opts, :pinctrl, false)
    tdd_dual_synth = Keyword.get(opts, :tdd_use_dual_synth, false)
    fdd_independent = Keyword.get(opts, :fdd_independent_mode, false)

    :ok = AD9363.write(@reg_ensm_mode, if(fdd?, do: 0x01, else: 0x00))

    with {:ok, cur} <- AD9363.read(@reg_ensm_config_2) do
      keep = cur &&& @ensm_config_2_preserve

      val =
        if fdd? do
          keep ||| @dual_synth_mode ||| if(fdd_independent, do: @fdd_external_ctrl_enable, else: 0)
        else
          keep ||| if(tdd_dual_synth, do: @dual_synth_mode, else: 0) |||
            if(tdd_dual_synth, do: 0, else: if(pinctrl, do: @synth_enable_pin_ctrl_mode, else: 0))
        end

      # Plain write, as in ADI's `ad9361_set_ensm_mode()`. Not yet observed to
      # misbehave on readback, but it is on the same list of registers they
      # deliberately do not verify, and this is not the place to find out.
      AD9363.write(@reg_ensm_config_2, val)
    end
  end

  @doc """
  Move the ENSM to `target`, going via `ALERT` when the transition requires it.

  `:rx` and `:tx` are only reachable from `ALERT` in TDD, so this forces
  `ALERT`, waits for `REG_STATE` to confirm it, and only then commands the
  target. Each step is verified by reading `REG_STATE` back — the ENSM's own
  report of where it is, which is the only trustworthy answer.
  """
  def set_state(target, opts \\ []) when target in [:alert, :rx, :tx, :fdd] do
    pinctrl = Keyword.get(opts, :pinctrl, false)
    pulse_mode = Keyword.get(opts, :ensm_pin_pulse_mode, false)
    rx_data_port_for_cal = Keyword.get(opts, :enable_rx_data_port_for_cal, false)

    base =
      if(pulse_mode, do: 0, else: @level_mode) |||
        if(pinctrl, do: @enable_ensm_pin_ctrl, else: 0) |||
        if(rx_data_port_for_cal, do: @enable_rx_data_port_for_cal, else: 0) |||
        @to_alert

    case target do
      :alert ->
        command(base ||| @force_alert_state, :alert)

      :fdd ->
        command(base ||| @force_tx_on, :fdd)

      t when t in [:rx, :tx] ->
        with {:ok, _} <- command(base ||| @force_alert_state, :alert),
             :ok <- select_direction(t) do
          bit = if t == :rx, do: @force_rx_on, else: @force_tx_on
          command(base ||| bit, t)
        end
    end
  end

  # ad9361.c:4525. Under SPI control (no pin control, single synth) the ENSM
  # has to be told which direction it is being asked to enter; FORCE_RX_ON
  # alone is not enough. Omitting this is a silent no-op: the chip stays in
  # ALERT and reports no error, which reads exactly like a refused transition
  # for some deeper reason.
  defp select_direction(target) do
    AD9363.writef(@reg_ensm_config_2, @txnrx_spi_ctrl, if(target == :tx, do: 1, else: 0))
  end

  @doc """
  Mask the synthesiser-ready gate.

  The ENSM will not leave ALERT for RX or TX until the relevant RF PLL reports
  locked. While the RF PLLs are deliberately unprogrammed — the BIST injects
  downstream of them, so the digital interface can be validated without RF —
  that gate can never be satisfied and the transition can never complete.

  These two bits are ADI's own supported way to bypass it, not a workaround.
  But be clear about what masking costs: with the gate bypassed the receive
  path will clock data out of the port while the RF front end is not usable.
  That is exactly what is wanted for a BIST measurement and exactly wrong for
  receiving an actual signal, so this must be turned back off once the RF PLLs
  are transcribed.
  """
  def mask_synth_ready(mask? \\ true) do
    bits = @rx_synth_ready_mask ||| @tx_synth_ready_mask

    with {:ok, cur} <- AD9363.read(@reg_ensm_config_2) do
      val = if mask?, do: cur ||| bits, else: cur &&& bnot(bits) &&& 0xFF
      # Plain write, as in ADI's `ad9361_set_ensm_mode()`. Not yet observed to
      # misbehave on readback, but it is on the same list of registers they
      # deliberately do not verify, and this is not the place to find out.
      AD9363.write(@reg_ensm_config_2, val)
    end
  end

  defp command(val, expect) do
    :ok = AD9363.write(@reg_ensm_config_1, val)
    await_state(expect, 200)
  end

  defp await_state(expect, 0) do
    {:ok, %{state: got}} = state()
    {:error, {:ensm_timeout, expected: expect, got: got}}
  end

  defp await_state(expect, n) do
    case state() do
      {:ok, %{state: ^expect} = s} ->
        {:ok, s}

      _ ->
        Process.sleep(1)
        await_state(expect, n - 1)
    end
  end

  @doc """
  Enable receive channels. `channels` is a bitmask: 1 = RX1, 2 = RX2, 3 = both.

  ADI's `writef` idiom here is unusual and worth spelling out: the *mask* is
  derived from which channels you are addressing and the *value* is the enable
  state, so enabling both channels is `writef(reg, 0b11 << 6, 0b11)`.
  """
  def enable_rx(channels \\ 3) do
    AD9363.writef(@reg_rx_enable_filter_ctrl, (channels &&& 0x3) <<< 6, channels)
  end

  @doc "Enable transmit channels. Same bitmask convention as `enable_rx/1`."
  def enable_tx(channels \\ 3) do
    AD9363.writef(@reg_tx_enable_filter_ctrl, (channels &&& 0x3) <<< 6, channels)
  end

  @doc """
  Select the RF input port and the TX output.

  ADI's encoding: inputs 0..2 select a balanced pair as `3 << (n * 2)`, inputs
  3..8 select a single-ended input as `1 << (n - 3)`. `txb` picks the B outputs.
  """
  def rf_port_setup(rx_input \\ 0, txb \\ false) when rx_input <= 8 do
    val = if rx_input < 3, do: 3 <<< (rx_input * 2), else: 1 <<< (rx_input - 3)
    val = if txb, do: val ||| 0x40, else: val

    # Plain write, NOT write_verify. `REG_INPUT_SELECT` bit 0 does not read back:
    # writing 0x03 reads 0x02, writing 0x43 reads 0x42. ADI's
    # `ad9361_rf_port_setup()` ends with a plain `ad9361_spi_write` for exactly
    # this reason, and so does `ad9361_setup()`'s write to `REG_CTRL`, whose bit 0
    # behaves the same way.
    #
    # The general lesson, learned twice in one session at some cost: **where ADI
    # uses a plain write, assume there is a reason.** Their driver reaches for
    # `ad9361_spi_writef` or an explicit readback wherever verification is
    # actually safe, so a bare `spi_write` is a signal, not an oversight. Blanket
    # "verify every write" looked like rigour and instead produced a failure that
    # was indistinguishable from a broken SPI path — it cost a long detour
    # through bitstream seeds, place-and-route and cache coherency before the
    # readback values (expected 3, got 2) made the pattern obvious.
    AD9363.write(@reg_input_select, val)
  end
end
