defmodule Mix.Tasks.Nerves.Discover.Expect do
  @shortdoc "Block until a specific Nerves device appears"

  @moduledoc """
  Block until a Nerves device matching TARGET appears on the network.

      $ mix nerves.discover.expect TARGET

  TARGET is treated as an IP address if it parses as one, in which case it
  matches on address membership. Otherwise it is a hostname pattern where `*`
  matches any run of characters, tested case-insensitively against the device's
  mDNS name, its hostname, and its hostname with a trailing `.local` removed.

  An IP target only matches a device that is *advertising* over mDNS. A host
  that is up but not running mDNS will never match -- "is it reachable" is a
  different question from "is it advertising as a Nerves device".

  ## Examples

      $ mix nerves.discover.expect nerves-8465
      $ mix nerves.discover.expect nerves-8465.local
      $ mix nerves.discover.expect 'nerves-84*'
      $ mix nerves.discover.expect 192.168.7.48
      $ ssh nerves@$(mix nerves.discover.expect 'nerves-84*' --quiet)

  Quote patterns containing `*` so the shell doesn't glob them against files
  in the current directory first.

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
    {opts, args, _} =
      OptionParser.parse(argv,
        switches: Discovery.wait_switches(),
        aliases: Discovery.wait_aliases()
      )

    target = target!(args)

    Discovery.progress(opts, "Waiting for #{target}")

    MapSet.new()
    |> Discovery.wait(Discovery.build_matcher(target), opts)
    |> Discovery.report(opts)
  end

  defp target!([target]), do: target
  defp target!([]), do: Mix.raise("Expected a hostname, pattern or IP address. See mix help nerves.discover.expect")

  defp target!(args),
    do: Mix.raise("Expected exactly one target, got #{length(args)}: #{Enum.join(args, " ")}")
end
