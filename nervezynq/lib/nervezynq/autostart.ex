defmodule Nervezynq.Autostart do
  @moduledoc """
  Runs `/data/autostart.exs` once at boot, so a board can bring its own
  bitstream, radio and applications up without a controller (a node
  carried around on a battery).

  The script is evaluated in a process that then stays alive, so whatever
  it starts linked survives. A script that raises, throws or exits is
  logged and left; the firmware keeps running either way, and Erlang
  distribution (`Nervezynq.Dist`) is up for a controller to look.

  Escape hatches, both in /data:

    * `autostart.disabled` - never run (until removed);
    * `autostart.skip` - skip the next boot only (removed when seen), for
      recovering from a script that wedges the board.

  Waits for `Nervezynq.Fabric` to answer (up to `@fabric_wait_ms`) before
  evaluating, since scripts load bitstreams through it.
  """

  use GenServer

  require Logger

  @script "/data/autostart.exs"
  @disabled "/data/autostart.disabled"
  @skip "/data/autostart.skip"
  @fabric_wait_ms 30_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "`:idle | :skipped | :disabled | :running | {:done, result} | {:failed, reason}`."
  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(opts) do
    script = Keyword.get(opts, :script, @script)

    status =
      cond do
        File.exists?(@disabled) ->
          :disabled

        File.exists?(@skip) ->
          File.rm(@skip)
          :skipped

        not File.exists?(script) ->
          :idle

        true ->
          me = self()
          spawn(fn -> run(script, me) end)
          :running
      end

    if status != :running, do: Logger.info("autostart: #{status}")
    {:ok, %{status: status}}
  end

  @impl true
  def handle_call(:status, _from, s), do: {:reply, s.status, s}

  @impl true
  def handle_info({:autostart, result}, s), do: {:noreply, %{s | status: result}}

  # The evaluating process: reports, then holds whatever the script linked.
  defp run(script, server) do
    wait_fabric(@fabric_wait_ms)
    Logger.info("autostart: evaluating #{script}")

    result =
      try do
        {value, _binding} = Code.eval_file(script)
        Logger.info("autostart: done: #{inspect(value, limit: 20)}")
        {:done, value}
      rescue
        e ->
          Logger.error("autostart: #{Exception.format(:error, e, __STACKTRACE__)}")
          {:failed, Exception.message(e)}
      catch
        kind, reason ->
          Logger.error("autostart: #{kind}: #{inspect(reason)}")
          {:failed, {kind, reason}}
      end

    send(server, {:autostart, result})
    Process.sleep(:infinity)
  end

  defp wait_fabric(left) when left <= 0, do: :timeout

  defp wait_fabric(left) do
    ready =
      try do
        Process.whereis(Nervezynq.Fabric) != nil
      catch
        _, _ -> false
      end

    if ready, do: :ok, else: (Process.sleep(500); wait_fabric(left - 500))
  end
end
