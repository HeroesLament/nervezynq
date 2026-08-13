defmodule Nervezynq.Sweep do
  @moduledoc """
  Hardware-oracle bit search: find the RIOI3 configuration bits that make IDDR
  capture work.

  ## Why this is a legitimate method and not a hack

  prjxray discovers bitstream encodings by generating designs in Vivado and
  diffing the resulting bitstreams. That is the only method it has, and it is why
  every bit in the database exists — and why twelve of the fourteen ILOGICE3 site
  muxes do not, since no specimen ever exercised them.

  This asks the question from the other end. Rather than "what did Vivado change
  when I set this property", it asks "which bit, when set, makes the hardware
  start working". The answer is the same encoding. Arguably it is better
  evidence: a bitstream diff shows a bit *correlates* with a property, whereas
  this shows the bit *does the thing*.

  It is only possible because there is a board and a sharp oracle.

  ## The oracle

  With the AD9363 in RX and a BIST PRBS injected at the digital receive control
  point, a working capture path yields many distinct sample words. A dead one
  yields exactly 1 — currently a constant `0xFC0`, unchanged across 40,000 reads,
  five BIST states and a doubling of DATA_CLK.

  So `distinct > 1` is the pass condition, and it is close to binary. Note it
  stays meaningful despite `STATUS3` being an unsynchronised crossing: tearing
  can corrupt *which* words we see, but it cannot manufacture variety out of a
  register that never changes.

  ## Why the board pulls

  Nerves' IEx over ssh does not terminate on piped stdin, so the sweep cannot be
  driven from the host that generates the bitstreams. Instead the host serves the
  candidates over the usb0 link and the board works through them by itself,
  printing one line per candidate. No interactive ssh scripting, and progress is
  visible as it happens.

  ## Failure is not fatal to the run

  A failed load leaves the PL blank and `Fabric` blocked — see `Nervezynq.PL`.
  The sweep keeps going anyway: the next candidate's load re-authorises the bus
  if it succeeds. So one bad bitstream costs one line of output, not the run.
  """

  require Logger
  alias Nervezynq.{AD9363, Fabric, LVDSProbe, PL}
  alias Nervezynq.AD9363.Bringup

  @scratch "/root/sweep.bin"

  @doc """
  Work through the manifest at `base_url`, printing a result line per candidate.

  Returns the list of `{index, segbit, distinct}` so hits can be picked out
  afterwards without re-reading the scrollback.
  """
  def run(base_url \\ "http://172.31.248.126:8000/", opts \\ []) do
    samples = Keyword.get(opts, :samples, 2000)
    limit = Keyword.get(opts, :limit)
    rate = Keyword.get(opts, :sample_rate_hz, 4_000_000)

    {:ok, _} = Application.ensure_all_started(:inets)

    {:ok, manifest} = fetch(base_url <> "manifest.txt")

    entries =
      manifest
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        [idx, segbit, file] = String.split(line)
        {idx, segbit, file}
      end)

    entries = if limit, do: Enum.take(entries, limit), else: entries

    IO.puts("sweep: #{length(entries)} candidates, oracle = distinct sample words > 1")
    IO.puts("baseline for comparison is distinct = 1 (constant 0xFC0)")
    IO.puts("")

    results =
      Enum.map(entries, fn {idx, segbit, file} ->
        distinct = one(base_url, idx, segbit, file, samples, rate)
        {idx, segbit, distinct}
      end)

    IO.puts("")
    valid = Enum.filter(results, fn {_, _, d} -> is_integer(d) end)
    hits = Enum.filter(valid, fn {_, _, d} -> d > 1 end)
    invalid = length(results) - length(valid)

    IO.puts("#{length(valid)} valid measurements, #{invalid} invalid (bring-up never reached RX)")

    cond do
      hits != [] ->
        IO.puts("HITS:")
        Enum.each(hits, fn {i, s, d} -> IO.puts("  #{i}  #{s}  distinct=#{d}") end)

      # A sweep where most candidates never produced a measurement has not
      # tested anything, and must not be reported as though it had. The earlier
      # version of this function printed "no single bit changed the oracle -- that
      # is a real result" after 48 of 50 candidates failed to reach RX, which is
      # exactly the kind of confident wrong conclusion this project keeps paying
      # for. An absence of hits is only evidence when the measurements happened.
      length(valid) < div(length(results), 2) ->
        IO.puts("")
        IO.puts("INCONCLUSIVE. Too few candidates produced a measurement, so the")
        IO.puts("absence of hits says nothing about the bits. Fix the bring-up")
        IO.puts("reliability first -- this is not evidence either way.")

      true ->
        IO.puts("")
        IO.puts("No hit among #{length(valid)} valid measurements. That is evidence:")
        IO.puts("either the encoding needs more than one bit (try pairs), or it is")
        IO.puts("not among the masked bits and the search must widen to the tile.")
    end

    results
  end

  defp one(base_url, idx, segbit, file, samples, rate) do
    with {:ok, bin} <- fetch(base_url <> file),
         :ok <- File.write(@scratch, bin),
         {:ok, _} <- PL.reload(@scratch) do
      # Sanity-check the bitstream before believing anything downstream of it.
      # A flipped configuration bit can produce a design that loads (PCFG_DONE
      # is about the config engine, not about the design being sane) but whose
      # AXI slave or SPI master no longer works. Without this check a broken
      # candidate is indistinguishable from a candidate that simply did not fix
      # the IDDR.
      case Fabric.read32(0x00) do
        {:ok, 0x4548_4431} ->
          # Settle before touching SPI. Reconfiguration takes the AD9363's
          # control pins through high-Z and then drives RESETB low from a
          # freshly-reset CTRL1, and the fabric itself has only just come out of
          # FCLK_RESET0_N with the level shifters re-enabled. Going straight
          # from `PL.reload/1` into an SPI transaction fails the first register
          # readback every time, while the same sequence typed by hand seconds
          # later always works -- which is what a missing settling delay looks
          # like. The exact mechanism is not established; the delay is empirical
          # and the retry below covers what it misses.
          Process.sleep(250)
          measure(idx, segbit, samples, rate)

        other ->
          IO.puts(
            "#{idx} #{String.pad_trailing(segbit, 8)} BAD_BITSTREAM magic=#{inspect(other)}"
          )

          :bad_bitstream
      end
    else
      {:error, {:pl_unconfigured, rc, out}} ->
        # Expected for some candidates: a bit flip can produce a bitstream the
        # config engine rejects outright. Not a problem, and not a reason to stop.
        IO.puts("#{idx} #{String.pad_trailing(segbit, 8)} LOAD_REJECTED rc=#{rc} #{out}")
        :load_rejected

      err ->
        IO.puts("#{idx} #{String.pad_trailing(segbit, 8)} ERROR #{inspect(err)}")
        :error
    end
  end

  # `AD9363.bring_up/1` and friends assert with `:ok = ...` internally, so a
  # transceiver that stops answering on SPI raises a MatchError rather than
  # returning an error tuple. That is the right behaviour at the IEx prompt and
  # the wrong behaviour inside a 50-iteration sweep, so it is caught here rather
  # than by loosening the driver.
  defp measure(idx, segbit, samples, rate, attempt \\ 1) do
    try do
      {:ok, r} = Bringup.receive_path(rate)
      # PRBS gives the widest spread a working path could produce, so it is the
      # most sensitive setting for a yes/no question.
      {:ok, _} = AD9363.bist_prbs(:rx)
      Process.sleep(50)

      s = LVDSProbe.summarise(LVDSProbe.sample(samples))

      IO.puts(
        "#{idx} #{String.pad_trailing(segbit, 8)} distinct=#{String.pad_leading(to_string(s.distinct), 4)}" <>
          "  dclk=#{r.measured_data_clk_mhz}  top=#{inspect(Enum.take(s.top, 2))}" <>
          if(s.distinct > 1, do: "   <<< HIT", else: "")
      )

      s.distinct
    rescue
      e ->
        if attempt < 2 do
          # One retry, after a full reset pulse. A transceiver that does not
          # answer on the first attempt after reconfiguration usually answers on
          # the second; a genuinely broken candidate fails both.
          Process.sleep(300)
          measure(idx, segbit, samples, rate, attempt + 1)
        else
          IO.puts(
            "#{idx} #{String.pad_trailing(segbit, 8)} BRINGUP_RAISED " <>
              (Exception.message(e) |> String.replace("\n", " ") |> String.trim())
          )

          :bringup_raised
        end
    end
  end

  @doc "Restore a known-good bitstream and prove the bus is back."
  def restore(base_url \\ "http://172.31.248.126:8000/", good \\ "good.bin") do
    with {:ok, bin} <- fetch(base_url <> good),
         :ok <- File.write(@scratch, bin) do
      PL.reload_and_verify(@scratch)
    end
  end

  defp fetch(url) do
    case :httpc.request(:get, {String.to_charlist(url), []}, [{:timeout, 30_000}], body_format: :binary) do
      {:ok, {{_, 200, _}, _headers, body}} -> {:ok, body}
      {:ok, {{_, code, _}, _, _}} -> {:error, {:http, code, url}}
      {:error, reason} -> {:error, {:http, reason, url}}
    end
  end
end
