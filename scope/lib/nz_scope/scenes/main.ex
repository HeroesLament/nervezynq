defmodule NzScope.Scenes.Main do
  @moduledoc """
  The scope window: connection + tuning controls, live spectrum, waterfall.

  All hot data bypasses this scene (Link feeds the canvases directly);
  the model here only carries human-rate state, so view/1 churn stays
  cheap. Text inputs are write-once from the model (`:ensure_widget`
  value only, never `:set`) to avoid the set → text_updated → set loop.

  The waterfall is a wx_mvu `:layers` visual rather than a hand-written
  GL canvas: a colormapped scrolling image with two line overlays for the
  frequency ticks. Its dB range and its ticks are part of the declaration,
  so they arrive through the differ and only the FFT rows are sent as
  data.
  """

  use WxMVU.Scene
  require Logger

  alias NzScope.Link

  # usb0 — static and reliable (AGENTS.md); eth0 comes and goes.
  @default_host "172.31.248.125"
  @freq_step_hz 1_000_000

  # ------------------------------------------------------------------
  # Init
  # ------------------------------------------------------------------

  def init(_opts) do
    Link.attach(self())
    # Auto-connect on launch; the Link retries every 2 s until the tap
    # (or Sim) answers, and the Connect button still works as an override.
    Link.connect(@default_host)

    %{
      host_text: @default_host,
      connected: false,
      freq_text: "2412.0",
      gain_db: 40,
      db_min: -100,
      db_max: 0,
      paused: false,
      meta: nil,
      fps: 0.0,
      status_text: "Connecting to #{@default_host}… (edit host + Connect to override)",
      last_error: nil
    }
  end

  # ------------------------------------------------------------------
  # UI events
  # ------------------------------------------------------------------

  def handle_event({:ui_event, :host_input, :change, text}, model),
    do: %{model | host_text: text}

  def handle_event({:ui_event, :host_input, :enter, text}, model),
    do: do_connect(%{model | host_text: text})

  def handle_event({:ui_event, :connect_btn, :click}, model) do
    if model.connected do
      Link.disconnect()
      model
    else
      do_connect(model)
    end
  end

  def handle_event({:ui_event, :freq_input, :change, text}, model),
    do: %{model | freq_text: text}

  def handle_event({:ui_event, :freq_input, :enter, text}, model),
    do: do_tune(%{model | freq_text: text})

  def handle_event({:ui_event, :tune_btn, :click}, model), do: do_tune(model)

  def handle_event({:ui_event, :freq_down_btn, :click}, model), do: step_freq(model, -@freq_step_hz)
  def handle_event({:ui_event, :freq_up_btn, :click}, model), do: step_freq(model, @freq_step_hz)

  def handle_event({:ui_event, :gain_spin, :change, db}, model) do
    Link.gain(db)
    %{model | gain_db: db}
  end

  def handle_event({:ui_event, :db_min_spin, :change, v}, model),
    do: apply_range(%{model | db_min: v})

  def handle_event({:ui_event, :db_max_spin, :change, v}, model),
    do: apply_range(%{model | db_max: v})

  def handle_event({:ui_event, :pause_toggle, :toggle, flag}, model) do
    Link.pause(flag)
    %{model | paused: flag}
  end

  def handle_event({:ui_event, :clear_btn, :click}, model) do
    WxMVU.Visual.send_data(:waterfall, {:history, :clear})
    WxMVU.GLCanvas.send_data(:spectrum, :clear)
    model
  end

  def handle_event({:ui_event, :main, :close_window, _}, model) do
    Link.disconnect()
    model
  end

  def handle_event(_event, model), do: model

  # ------------------------------------------------------------------
  # Link notifications
  # ------------------------------------------------------------------

  def handle_info({:scope_link, :connected}, model) do
    {:noreply, %{model | connected: true, status_text: "Connected.", last_error: nil}}
  end

  def handle_info({:scope_link, :disconnected}, model) do
    {:noreply, %{model | connected: false, fps: 0.0, status_text: "Disconnected."}}
  end

  def handle_info({:scope_link, {:meta, meta}}, model) do
    push_freq(meta)
    {:noreply, %{model | meta: meta, status_text: meta_text(meta, model.fps)}}
  end

  def handle_info({:scope_link, {:stats, %{fps: fps}}}, model) do
    # Re-push the tick window on the 1 Hz stats tick as well as on meta
    # changes: Link only notifies meta ON CHANGE, and at startup the hello
    # beats the canvases into existence — the first push lands on
    # unregistered canvases and is dropped (measured 2026-08-03: legend
    # correct, zero ticks drawn). The canvases dedupe by window, so this
    # costs nothing when nothing changed, and any (re)created canvas
    # self-heals within a second.
    push_freq(model.meta)
    {:noreply, %{model | fps: fps, status_text: meta_text(model.meta, fps)}}
  end

  def handle_info({:scope_link, {:status, map}}, model) do
    Logger.info("Board status: #{inspect(map)}")
    {:noreply, model}
  end

  def handle_info({:scope_link, {:error, term}}, model) do
    {:noreply, %{model | last_error: term, status_text: "Board error: #{inspect(term)}"}}
  end

  def handle_info(_msg, model), do: {:noreply, model}

  # ------------------------------------------------------------------
  # View
  # ------------------------------------------------------------------

  def view(model) do
    {minors, majors} = tick_runs(model.meta)

    [
      {:ensure_window, :main, title: "Nervezynq Scope", size: {1100, 820}},
      {:ensure_panel, :root, :main, []},

      # -- connection row ------------------------------------------------
      {:ensure_widget, :host_label, :static_text, :root, label: "Board:"},
      {:ensure_widget, :host_input, :text_ctrl, :root,
       value: model.host_text, process_enter: true},
      {:ensure_widget, :connect_btn, :button, :root, label: connect_label(model)},
      {:set, :connect_btn, label: connect_label(model)},

      # -- tuning row ----------------------------------------------------
      {:ensure_widget, :freq_label, :static_text, :root, label: "Freq (MHz):"},
      {:ensure_widget, :freq_input, :text_ctrl, :root,
       value: model.freq_text, process_enter: true},
      {:ensure_widget, :tune_btn, :button, :root, label: "Tune"},
      {:ensure_widget, :freq_down_btn, :button, :root, label: "−1 MHz"},
      {:ensure_widget, :freq_up_btn, :button, :root, label: "+1 MHz"},
      {:ensure_widget, :gain_label, :static_text, :root, label: "Gain (dB):"},
      {:ensure_widget, :gain_spin, :spin_ctrl, :root, min: 0, max: 73, value: model.gain_db},

      # -- display row ---------------------------------------------------
      {:ensure_widget, :range_label, :static_text, :root, label: "dB floor/ceil:"},
      {:ensure_widget, :db_min_spin, :spin_ctrl, :root, min: -140, max: -10, value: model.db_min},
      {:ensure_widget, :db_max_spin, :spin_ctrl, :root, min: -60, max: 20, value: model.db_max},
      {:ensure_widget, :pause_toggle, :toggle_button, :root, label: "Pause"},
      {:ensure_widget, :clear_btn, :button, :root, label: "Clear"},

      # -- status --------------------------------------------------------
      {:ensure_widget, :status_line, :static_text, :root, label: model.status_text},
      {:set, :status_line, label: model.status_text},

      # -- frequency ruler legend (the ticks' decoder ring) ---------------
      {:ensure_widget, :ruler_line, :static_text, :root, label: ruler_text(model.meta)},
      {:set, :ruler_line, label: ruler_text(model.meta)},

      # -- canvases ------------------------------------------------------
      {:ensure_gl_canvas, :spectrum, :root,
       module: NzScope.Canvas.Spectrum,
       size: {1024, 200},
       fps: 30,
       opts: [
         fft_size: Link.fft_size(),
         db_min: model.db_min * 1.0,
         db_max: model.db_max * 1.0,
         smoothing: 0.35
       ]},
      {:ensure_visual, :waterfall, :layers, :root,
       size: {1024, 460},
       fps: 30,
       layers: [
         history:
           {:image,
            grid: {Link.fft_size(), 512},
            domain: {model.db_min * 1.0, model.db_max * 1.0},
            colormap: :turbo,
            advance: :per_datum},
         minor_ticks: {:line, color: {0.75, 0.75, 0.78, 1.0}, width: 1.0, polylines: minors},
         major_ticks: {:line, color: {1.0, 1.0, 1.0, 1.0}, width: 1.0, polylines: majors}
       ]},

      # -- layout --------------------------------------------------------
      {:layout, :root,
       {:vbox, [padding: 8],
        [
          {:hbox, [], [:host_label, :host_input, {:spacer, 8}, :connect_btn]},
          {:spacer, 6},
          {:hbox, [],
           [
             :freq_label,
             :freq_input,
             {:spacer, 4},
             :tune_btn,
             {:spacer, 8},
             :freq_down_btn,
             :freq_up_btn,
             {:spacer, 16},
             :gain_label,
             :gain_spin
           ]},
          {:spacer, 6},
          {:hbox, [],
           [
             :range_label,
             :db_min_spin,
             :db_max_spin,
             {:spacer, 16},
             :pause_toggle,
             {:spacer, 8},
             :clear_btn
           ]},
          {:spacer, 6},
          :status_line,
          {:spacer, 2},
          :ruler_line,
          {:spacer, 6},
          {:spectrum, proportion: 0, flag: :expand},
          {:spacer, 4},
          {:waterfall, proportion: 1, flag: :expand}
        ]}},
      {:refresh, :main}
    ]
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp do_connect(model) do
    host = String.trim(model.host_text)

    if host == "" do
      %{model | status_text: "Enter a board address first."}
    else
      Link.connect(host)
      %{model | status_text: "Connecting to #{host}…"}
    end
  end

  defp do_tune(model) do
    case parse_mhz(model.freq_text) do
      {:ok, hz} ->
        Link.retune(hz)
        %{model | status_text: "Retuning to #{format_hz(hz)}…"}

      :error ->
        %{model | status_text: "Bad frequency: #{inspect(model.freq_text)} (MHz expected)"}
    end
  end

  defp step_freq(model, delta_hz) do
    base =
      case {parse_mhz(model.freq_text), model.meta} do
        {{:ok, hz}, _} -> hz
        {:error, %{freq: hz}} when is_integer(hz) -> hz
        _ -> nil
      end

    case base do
      nil ->
        model

      hz ->
        new_hz = hz + delta_hz
        Link.retune(new_hz)

        %{
          model
          | freq_text: mhz_text(new_hz),
            status_text: "Retuning to #{format_hz(new_hz)}…"
        }
    end
  end

  # The waterfall is not told. Its domain is part of its declaration, so
  # changing db_min here is a model change the differ turns into one uniform
  # write - and specifically not into a new texture, so the scroll history
  # survives a drag of the floor control. The spectrum is still a hand-rolled
  # canvas and still needs telling.
  defp apply_range(%{db_min: lo, db_max: hi} = model) when lo < hi do
    WxMVU.GLCanvas.send_data(:spectrum, {:set_range, lo * 1.0, hi * 1.0})
    model
  end

  defp apply_range(model), do: model

  defp parse_mhz(text) do
    case Float.parse(String.trim(text)) do
      {mhz, ""} when mhz > 0 -> {:ok, round(mhz * 1.0e6)}
      _ -> :error
    end
  end

  defp mhz_text(hz), do: :erlang.float_to_binary(hz / 1.0e6, decimals: 3)

  defp format_hz(hz) when hz >= 1.0e9, do: "#{Float.round(hz / 1.0e9, 6)} GHz"
  defp format_hz(hz), do: "#{Float.round(hz / 1.0e6, 3)} MHz"

  defp connect_label(%{connected: true}), do: "Disconnect"
  defp connect_label(_), do: "Connect"

  # Only the spectrum. The waterfall's ticks are declared in view/1 now, so
  # they arrive through the differ - which cannot race the visual into
  # existence the way a send_data could, and does not need re-pushing on the
  # stats tick to self-heal.
  defp push_freq(%{freq: freq, fs: fs}) when is_integer(freq) and is_integer(fs) do
    WxMVU.GLCanvas.send_data(:spectrum, {:set_freq, freq, fs})
  end

  defp push_freq(_), do: :ok

  # Ticks as geometry, in the clip space the :line visual draws in. Each tick
  # is its own two-point run: they are disjoint verticals, and joining them
  # into one polyline would draw the connecting strokes across the display.
  defp tick_runs(%{freq: freq, fs: fs}) when is_integer(freq) and is_integer(fs) do
    %{ticks: ticks} = NzScope.Ticks.plan(freq, fs)
    {minors, majors} = Enum.split_with(ticks, &(not &1.major?))

    {Enum.map(minors, &tick_run/1), Enum.map(majors, &tick_run/1)}
  end

  defp tick_runs(_), do: {[], []}

  defp tick_run(%{x: x}), do: [{x * 1.0, -1.0}, {x * 1.0, 1.0}]

  defp ruler_text(%{freq: freq, fs: fs}) when is_integer(freq) and is_integer(fs) do
    case NzScope.Ticks.legend(freq, fs) do
      nil -> "ticks: —"
      legend -> "ticks: " <> legend
    end
  end

  defp ruler_text(_), do: "ticks: — (waiting for board meta)"

  defp meta_text(nil, fps), do: "Connected. #{fmt_fps(fps)}"

  defp meta_text(meta, fps) do
    freq = if meta[:freq], do: format_hz(meta.freq * 1.0), else: "?"
    fs = if meta[:fs], do: "#{Float.round(meta.fs / 1.0e6, 2)} Msps", else: "?"
    gain = if meta[:gain], do: "#{meta.gain} dB", else: "?"
    n = meta[:n] || "?"

    "LO #{freq}  |  #{fs}  |  gain #{gain}  |  #{n} pairs/frame  |  #{fmt_fps(fps)}"
  end

  defp fmt_fps(fps), do: "#{Float.round(fps * 1.0, 1)} rows/s"
end
