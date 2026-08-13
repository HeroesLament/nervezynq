defmodule Mix.Tasks.Nerves.Discover.Watch do
  @shortdoc "Continuously watch for Nerves devices on the network"

  @moduledoc """
  Poll the network forever, redrawing the device table each round.

      $ mix nerves.discover.watch

  Runs until interrupted with Ctrl-C. Devices are aged out only after several
  consecutive missed rounds, because mDNS is lossy and a healthy device
  routinely fails to answer a single round.

  ## Examples

      $ mix nerves.discover.watch
      $ mix nerves.discover.watch --poll-interval 2000
      $ mix nerves.discover.watch --miss-threshold 5

  ## Options

    * `--poll-interval` - minimum length of each poll round (default 1000 ms).
      On macOS this is a floor rather than a period: the underlying browse is
      capped at one second and resolving each device costs about another
      second, so rounds land nearer two seconds however low you set it.
    * `--miss-threshold` - consecutive absent rounds before a device is
      dropped from the table (default 3).
  """
  use Mix.Task

  alias Nervezynq.Discovery

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, switches: Discovery.watch_switches())

    Discovery.watch(opts)
  end
end
