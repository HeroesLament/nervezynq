defmodule NzScope.Link do
  @moduledoc """
  TCP client to the board-side `Nervezynq.WFTap` (or `NzScope.Sim`).

  Owns the hot path: every `{:iq, meta, binary}` frame is FFT'd here and the
  dB bins go straight to the GL canvases via `WxMVU.GLCanvas.send_data/2`,
  bypassing the scene entirely — the same reason GLCanvas bypasses MVU
  diffing. The scene only hears about things at human rate: connect state,
  meta changes (freq/fs/gain), a 1 Hz stats tick, status/error terms.

  Scene messages (to the attached owner):

      {:scope_link, :connected}
      {:scope_link, :disconnected}
      {:scope_link, {:meta, %{fs:, freq:, gain:, n:}}}      # on change only
      {:scope_link, {:stats, %{fps: float, frames: n}}}     # 1 Hz
      {:scope_link, {:status, map}}
      {:scope_link, {:error, term}}

  Protocol: `{:packet, 4}` + `term_to_binary`, see wf_tap.exs header.
  """

  use GenServer
  require Logger

  alias NzScope.FFT

  @default_port 7355
  @fft_size 1024
  @reconnect_ms 2_000
  @waterfall_canvas :waterfall
  @spectrum_canvas :spectrum

  # --- API ---------------------------------------------------------------------

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The scene calls this from init/1 to receive link notifications."
  def attach(pid \\ self()), do: GenServer.cast(__MODULE__, {:attach, pid})

  def connect(host, port \\ @default_port), do: GenServer.cast(__MODULE__, {:connect, host, port})
  def disconnect, do: GenServer.cast(__MODULE__, :disconnect)

  def retune(hz), do: send_command({:retune, hz})
  def gain(db), do: send_command({:gain, db})
  def pause(flag), do: send_command({:pause, flag})
  def request_status, do: send_command(:status)

  def fft_size, do: @fft_size

  defp send_command(term), do: GenServer.cast(__MODULE__, {:command, term})

  # --- GenServer ---------------------------------------------------------------

  @impl true
  def init(_opts) do
    state = %{
      sock: nil,
      host: nil,
      port: @default_port,
      owner: nil,
      want_connected: false,
      meta: nil,
      frames: 0,
      frames_this_tick: 0
    }

    :timer.send_interval(1_000, :stats_tick)
    {:ok, state}
  end

  @impl true
  def handle_cast({:attach, pid}, state), do: {:noreply, %{state | owner: pid}}

  def handle_cast({:connect, host, port}, state) do
    state = close_socket(state)
    state = %{state | host: to_charlist(host), port: port, want_connected: true}
    {:noreply, try_connect(state)}
  end

  def handle_cast(:disconnect, state) do
    state = close_socket(%{state | want_connected: false})
    notify(state, :disconnected)
    {:noreply, state}
  end

  def handle_cast({:command, term}, %{sock: sock} = state) when sock != nil do
    :gen_tcp.send(sock, :erlang.term_to_binary(term))
    {:noreply, state}
  end

  def handle_cast({:command, _term}, state), do: {:noreply, state}

  @impl true
  def handle_info({:tcp, _sock, bin}, state) do
    state =
      case decode(bin) do
        {:ok, term} -> handle_frame(term, state)
        :error -> state
      end

    {:noreply, state}
  end

  def handle_info({:tcp_closed, _sock}, state) do
    Logger.info("Link: connection closed")
    notify(state, :disconnected)
    state = %{state | sock: nil}
    if state.want_connected, do: Process.send_after(self(), :reconnect, @reconnect_ms)
    {:noreply, state}
  end

  def handle_info({:tcp_error, _sock, reason}, state) do
    Logger.warning("Link: tcp error #{inspect(reason)}")
    notify(state, :disconnected)
    state = close_socket(state)
    if state.want_connected, do: Process.send_after(self(), :reconnect, @reconnect_ms)
    {:noreply, state}
  end

  def handle_info(:reconnect, state) do
    state = if state.want_connected and state.sock == nil, do: try_connect(state), else: state
    {:noreply, state}
  end

  def handle_info(:stats_tick, state) do
    if state.sock != nil do
      notify(state, {:stats, %{fps: state.frames_this_tick * 1.0, frames: state.frames}})
    end

    {:noreply, %{state | frames_this_tick: 0}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- frames ------------------------------------------------------------------

  defp handle_frame({:iq, meta, iq}, state) when is_binary(iq) do
    bins = FFT.iq_db_bins(iq, @fft_size)
    to_canvas(@waterfall_canvas, {:history, {:row, bins}})
    to_canvas(@spectrum_canvas, {:bins, bins})

    state = maybe_notify_meta(state, meta)
    %{state | frames: state.frames + 1, frames_this_tick: state.frames_this_tick + 1}
  end

  defp handle_frame({:hello, meta}, state) do
    Logger.info("Link: hello #{inspect(meta)}")
    maybe_notify_meta(state, meta)
  end

  defp handle_frame({:status, map}, state) do
    notify(state, {:status, map})
    state
  end

  defp handle_frame({:error, term}, state) do
    Logger.warning("Link: board error #{inspect(term)}")
    notify(state, {:error, term})
    state
  end

  defp handle_frame(other, state) do
    Logger.debug("Link: unhandled frame #{inspect(other)}")
    state
  end

  defp maybe_notify_meta(state, meta) do
    keys = Map.take(meta, [:fs, :freq, :gain, :n])

    if keys != state.meta do
      notify(state, {:meta, keys})
      %{state | meta: keys}
    else
      state
    end
  end

  # --- plumbing ----------------------------------------------------------------

  defp try_connect(state) do
    opts = [:binary, packet: 4, active: true, nodelay: true]

    case :gen_tcp.connect(state.host, state.port, opts, 3_000) do
      {:ok, sock} ->
        Logger.info("Link: connected to #{state.host}:#{state.port}")
        notify(state, :connected)
        %{state | sock: sock}

      {:error, reason} ->
        Logger.info("Link: connect failed (#{inspect(reason)}), retrying")
        Process.send_after(self(), :reconnect, @reconnect_ms)
        state
    end
  end

  defp close_socket(%{sock: nil} = state), do: state

  defp close_socket(%{sock: sock} = state) do
    :gen_tcp.close(sock)
    %{state | sock: nil}
  end

  # NOT binary_to_term/2 with [:safe]: :safe rejects terms containing atoms
  # the local VM hasn't interned yet, and under `iex -S mix` (interactive
  # mode, lazy module loading) frame-meta atoms like :seq may not exist
  # until some module referencing them loads. Both ends of this socket are
  # ours (wf_tap.exs / sim.ex), so plain decode is the correct call.
  defp decode(bin) do
    {:ok, :erlang.binary_to_term(bin)}
  rescue
    e ->
      Logger.warning("Link: frame decode failed: #{inspect(e)}")
      :error
  end

  defp notify(%{owner: nil}, _msg), do: :ok
  defp notify(%{owner: pid}, msg), do: send(pid, {:scope_link, msg})

  # send_data is a no-op with a log line when the canvas isn't up yet;
  # the try is for the headless case (tests) where wx_mvu isn't running.
  defp to_canvas(id, msg) do
    WxMVU.GLCanvas.send_data(id, msg)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
