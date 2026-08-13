defmodule Mix.Tasks.Nerves.Discover.First do
  @shortdoc "Block until a new Nerves device appears on the network"

  @moduledoc """
  Block until a Nerves device appears that was not already on the network.

  Intended to be run *after* a burn, while the device is rebooting: everything
  already advertising when this task starts is treated as baseline and ignored.

      $ mix firmware.burn && mix nerves.discover.first

  A device that reboots back with the same hostname is only reported if it was
  already down when this task started. If you run it while the old firmware is
  still up, it will wait forever on a device that never looks new.

  ## Examples

      $ mix nerves.discover.first
      $ mix nerves.discover.first --timeout 60000
      $ ssh nerves@$(mix nerves.discover.first --quiet)

  ## Options

    * `--timeout` - overall deadline in milliseconds. Defaults to no deadline.
    * `--poll-interval` - length of each poll round (default 1000 ms).
    * `--quiet` (`-q`) - print only the matched device's IP address on stdout.
      Progress goes to stderr either way.

  Exits with status 1 if the deadline passes without a match.
  """
  use Mix.Task

  alias Nervezynq.Discovery

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        switches: Discovery.wait_switches(),
        aliases: Discovery.wait_aliases()
      )

    Discovery.progress(opts, "Taking a baseline of the network...\n")
    baseline = Discovery.discover_names(Discovery.poll_interval(opts))

    if MapSet.size(baseline) > 0 do
      Discovery.progress(
        opts,
        "Ignoring #{MapSet.size(baseline)} device(s) already up: " <>
          Enum.join(Enum.sort(baseline), ", ") <> "\n"
      )
    end

    Discovery.progress(opts, "Waiting for a new Nerves device")

    baseline
    |> Discovery.wait(fn _device -> true end, opts)
    |> Discovery.report(opts)
  end
end
