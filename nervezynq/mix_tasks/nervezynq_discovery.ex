defmodule Nervezynq.Discovery do
  @moduledoc false
  #
  # Shared implementation behind `mix nerves.discover.first`,
  # `mix nerves.discover.expect` and `mix nerves.discover.watch`.
  #
  # These are separate task names rather than flags on `mix nerves.discover`
  # because that module already exists in the :nerves dependency. Defining it
  # again here compiled fine and even won `mix help`, but lost the code-path
  # race at run time, so `mix nerves.discover --watch` silently ran the dep's
  # one-shot scan. Distinct module names have no such ambiguity.
  #
  # The table formatting below is lifted from nerves v1.15.0
  # (lib/mix/tasks/nerves.discover.ex) so output matches plain
  # `mix nerves.discover`. Diff against upstream when bumping :nerves.
  #
  # > #### macOS timeouts
  # >
  # > NervesDiscovery.MacOS.discover_service/2 computes its browse duration
  # > with min(div(timeout, 1000), 1), so on macOS every scan is capped at one
  # > second regardless of what we pass. Poll rounds are therefore ~1s there no
  # > matter what --poll-interval says.

  alias Nerves.Fwup.Word34567

  @default_poll_interval 1000
  @default_miss_threshold 3

  @wait_switches [timeout: :integer, poll_interval: :integer, quiet: :boolean]
  @wait_aliases [q: :quiet]

  @watch_switches [poll_interval: :integer, miss_threshold: :integer]

  def wait_switches(), do: @wait_switches
  def wait_aliases(), do: @wait_aliases
  def watch_switches(), do: @watch_switches
  def default_poll_interval(), do: @default_poll_interval
  def default_miss_threshold(), do: @default_miss_threshold

  ## Discovery

  @doc """
  Run one discovery round, yielding `[]` rather than crashing on a bad round.

  `NervesDiscovery.discover/1` awaits its two query tasks for only
  `timeout + 1000` ms. On macOS the browse inside those tasks is hard-capped at
  one second and each device resolve costs roughly another 1.2s on top, so
  handing it a 1000 ms poll interval both blows that await budget (taking the
  caller down with it) and kills the resolves that would have produced
  addresses. macOS ignores the timeout for browse duration anyway, so it gets
  upstream's proven 5000 ms of headroom and a round simply takes as long as it
  takes -- about two seconds. `--poll-interval` is a floor there, not a period.

  A round that exits regardless is reported as "no devices" instead of killing
  a long-running watch. `--watch` ages devices out over several rounds
  precisely so that one bad round is survivable.
  """
  @spec discover(non_neg_integer()) :: [map()]
  def discover(poll) do
    NervesDiscovery.discover(timeout: discovery_budget(poll))
  catch
    :exit, _ -> []
  end

  defp discovery_budget(poll) do
    case :os.type() do
      {:unix, :darwin} -> max(poll, 5000)
      _ -> poll
    end
  end

  @spec discover_names(non_neg_integer()) :: MapSet.t(String.t())
  def discover_names(timeout), do: timeout |> discover() |> MapSet.new(& &1.name)

  @doc """
  Build a predicate for an `--expect`-style target.

  An argument that parses as an IP address matches on address membership.
  Anything else is a hostname pattern where `*` matches any run of characters,
  tested case-insensitively against the device's mDNS name, its hostname, and
  its hostname with a trailing `.local` removed.
  """
  @spec build_matcher(String.t()) :: (map() -> boolean())
  def build_matcher(target) do
    case target |> String.to_charlist() |> :inet.parse_address() do
      {:ok, ip} -> fn device -> ip in device.addresses end
      {:error, :einval} -> name_matcher(target)
    end
  end

  defp name_matcher(pattern) do
    regex =
      pattern
      |> Regex.escape()
      |> String.replace("\\*", ".*")
      |> then(&Regex.compile!("\\A#{&1}\\z", "i"))

    fn device -> device |> candidate_names() |> Enum.any?(&Regex.match?(regex, &1)) end
  end

  defp candidate_names(device) do
    [device[:name], device[:hostname]]
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(&[&1, String.replace_suffix(&1, ".local", "")])
    |> Enum.uniq()
  end

  ## Blocking wait, shared by .first and .expect

  @spec wait(MapSet.t(String.t()), (map() -> boolean()), keyword()) :: {:ok, map()} | :timeout
  def wait(baseline, match?, opts) do
    loop(baseline, match?, poll_interval(opts), deadline(opts), opts)
  end

  defp loop(baseline, match?, poll, deadline, opts) do
    match =
      poll
      |> discover()
      |> Enum.reject(&MapSet.member?(baseline, &1.name))
      |> Enum.find(match?)

    cond do
      match ->
        progress(opts, "\n")
        {:ok, match}

      expired?(deadline) ->
        progress(opts, "\n")
        :timeout

      true ->
        progress(opts, ".")
        loop(baseline, match?, poll, deadline, opts)
    end
  end

  @doc """
  Print the outcome of a `wait/3` and, on timeout, exit with status 1.
  """
  @spec report({:ok, map()} | :timeout, keyword()) :: :ok
  def report({:ok, device}, opts) do
    if opts[:quiet] do
      IO.puts(device.ip)
    else
      Mix.shell().info("")
      Tablet.puts([device], tablet_options([device]))
    end
  end

  def report(:timeout, _opts) do
    Mix.raise("Timed out waiting for a Nerves device")
  end

  ## Watch

  @spec watch(keyword()) :: :ok
  def watch(opts) do
    poll = poll_interval(opts)
    threshold = Keyword.get(opts, :miss_threshold, @default_miss_threshold)

    trap_sigint(self())
    hide_cursor()

    try do
      watch_loop(%{}, poll, threshold, 1)
    after
      show_cursor()
    end
  end

  # The inter-round sleep and the Ctrl-C check are the same receive: a trapped
  # SIGINT arrives as a message, which falls out of the loop and lets the
  # `after` in watch/1 put the cursor back before mix exits.
  defp watch_loop(tracked, poll, threshold, round) do
    started = System.monotonic_time(:millisecond)

    tracked = merge_round(tracked, discover(poll), threshold)
    draw(tracked, round, poll)

    remaining = max(poll - (System.monotonic_time(:millisecond) - started), 0)

    receive do
      :sigint -> :ok
    after
      remaining -> watch_loop(tracked, poll, threshold, round + 1)
    end
  end

  # Devices seen this round reset to zero misses; everything else ages by one
  # and is dropped once absent for `threshold` consecutive rounds. mDNS is
  # lossy, so a healthy device routinely misses a single round.
  defp merge_round(tracked, devices, threshold) do
    seen = Map.new(devices, &{&1.name, &1})

    aged =
      tracked
      |> Enum.reject(fn {name, {_device, misses}} ->
        not Map.has_key?(seen, name) and misses + 1 >= threshold
      end)
      |> Map.new(fn {name, {device, misses}} ->
        case Map.fetch(seen, name) do
          {:ok, fresh} -> {name, {fresh, 0}}
          :error -> {name, {device, misses + 1}}
        end
      end)

    Enum.reduce(seen, aged, fn {name, device}, acc -> Map.put_new(acc, name, {device, 0}) end)
  end

  defp draw(tracked, round, poll) do
    devices =
      tracked
      |> Map.values()
      |> Enum.map(fn {device, _misses} -> device end)
      |> Enum.sort_by(& &1.name)

    clear_screen()
    IO.puts("Watching for Nerves devices -- round #{round}, every #{poll}ms. Ctrl-C to stop.\n")

    if devices == [] do
      IO.puts("No devices found.")
    else
      Tablet.puts(devices, tablet_options(devices))
    end
  end

  ## Options

  def poll_interval(opts), do: Keyword.get(opts, :poll_interval, @default_poll_interval)

  defp deadline(opts) do
    case Keyword.get(opts, :timeout) do
      nil -> :infinity
      ms -> System.monotonic_time(:millisecond) + ms
    end
  end

  defp expired?(:infinity), do: false
  defp expired?(deadline), do: System.monotonic_time(:millisecond) >= deadline

  ## Terminal
  #
  # Progress goes to stderr so --quiet leaves stdout holding only the address.

  def progress(opts, message) do
    if !opts[:quiet], do: IO.write(:stderr, message)
  end

  defp clear_screen(), do: IO.write("\e[H\e[2J")
  defp hide_cursor(), do: IO.write("\e[?25l")
  defp show_cursor(), do: IO.write("\e[?25h")

  # Handing the signal back as a message keeps System.halt/1 out of the handler
  # closure -- the closure is spec'd to return :ok and halting makes it return
  # nothing, which Elixir 1.20's type checker flags -- and it means the cursor
  # is restored on the way out rather than abandoned mid-draw.
  defp trap_sigint(parent) do
    System.trap_signal(:sigint, fn ->
      send(parent, :sigint)
      :ok
    end)

    :ok
  rescue
    _ -> :ok
  end

  ## Table formatting (from nerves v1.15.0)

  def tablet_options(devices) do
    base_columns = [:hostname, :addresses]
    optional_columns = [:serial, :product, :version, :platform, :uuid]

    all_keys =
      Enum.reduce(devices, MapSet.new(), fn device, set ->
        set_put_many(set, non_empty_keys(device))
      end)

    additional_columns = Enum.filter(optional_columns, &MapSet.member?(all_keys, &1))

    [
      keys: base_columns ++ additional_columns,
      formatter: &formatter/2,
      column_widths: %{uuid: :expand}
    ]
  end

  defp non_empty_keys(map) do
    Enum.reduce(map, [], fn {k, v}, acc -> if v != nil and v != "", do: [k | acc], else: acc end)
  end

  defp set_put_many(set, values), do: Enum.reduce(values, set, &MapSet.put(&2, &1))

  defp formatter(:__header__, key), do: {:ok, key |> to_string() |> String.upcase()}

  defp formatter(:addresses, addresses),
    do: {:ok, addresses |> Enum.map(&:inet.ntoa/1) |> Enum.map_join("\n", &to_string/1)}

  defp formatter(:uuid, uuid) when byte_size(uuid) == 36,
    do: {:ok, "#{uuid_to_nickname(uuid)} (#{uuid})"}

  defp formatter(_, _), do: :default

  defp uuid_to_nickname(uuid) do
    <<first::8, second::8, _rest::binary>> =
      uuid |> String.replace("-", "") |> Base.decode16!(case: :mixed)

    "#{Word34567.word(first)}-#{Word34567.word(second)}"
  end
end
