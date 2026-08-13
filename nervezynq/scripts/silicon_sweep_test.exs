#!/usr/bin/env elixir
#
# silicon_sweep_test.exs -- known-answer checks for every part of the sweep
# harness that does NOT need silicon.
#
#     elixir scripts/silicon_sweep_test.exs
#
# The harness is not runnable end to end yet (it is blocked on a physical DMA
# buffer), but three pieces of it are pure functions whose being wrong would be
# invisible and fatal:
#
#   * the type-1 packet encoder      -- a wrong field shift arms the wrong register
#   * the pad-frame drop             -- an off-by-one-FRAME shifts every result
#   * the mask application           -- a wrong mask makes every comparison noise
#
# An off-by-one-frame error does not crash. It returns plausible data about the
# wrong frame, which is the exact shape of the six confident-wrong-answers this
# project has already produced. So these get tested before the board exists.

Code.require_file(Path.join(__DIR__, "silicon_sweep.exs"))

defmodule T do
  import Bitwise

  def check(name, got, want) do
    ok = got == want
    IO.puts("#{if ok, do: "PASS", else: "FAIL"}  #{name}")
    unless ok, do: IO.puts("        got  #{inspect(got)}\n        want #{inspect(want)}")
    ok
  end

  def run do
    alias SiliconSweep.{Readback, Mask}

    results = [
      # --- type-1 packet encoding, against UG470 Table 5-20 -----------------
      # header = 001 <op:2> <addr:14> 000 <count:11>
      check(
        "type1 write FAR count 1",
        Readback.type1(2, 0x01, 1),
        (1 <<< 29) ||| (2 <<< 27) ||| (0x01 <<< 13) ||| 1
      ),
      check("type1 write CMD is 0x30008001", Readback.type1(2, 0x04, 1), 0x3000_8001),
      check("type1 read FDRO count 0", Readback.type1(1, 0x03, 0), 0x2800_6000),

      # --- word budget includes the pipeline pad frame ----------------------
      check("words_for(1) = 2 frames", Readback.words_for(1), 202),
      check("words_for(30) = 31 frames", Readback.words_for(30), 3131),

      # --- the pad-frame drop -----------------------------------------------
      # 3 frames of data => 4 frames read => first 101 words are pipeline junk.
      # If this is wrong every bit lands in the wrong minor and NOTHING says so.
      (
        junk = List.duplicate(0xDEAD_BEEF, 101)
        f0 = List.duplicate(0x1111_1111, 101)
        f1 = List.duplicate(0x2222_2222, 101)
        f2 = List.duplicate(0x3333_3333, 101)
        got = Readback.to_frames(junk ++ f0 ++ f1 ++ f2)

        # Assert on the FIRST WORD of each returned frame: if the pad frame were
        # not dropped, frame 0 would read 0xDEADBEEF, and if two were dropped it
        # would read 0x22222222. Both wrong answers are the same shape as the
        # right one, which is exactly why this is asserted rather than eyeballed.
        firsts = Enum.map(got, &List.first/1)

        check("to_frames drops exactly one pad frame", {length(got), firsts},
          {3, [0x1111_1111, 0x2222_2222, 0x3333_3333]})
      ),
      (
        junk = List.duplicate(0, 101)
        f0 = List.duplicate(7, 101)
        got = Readback.to_frames(junk ++ f0 ++ [1, 2, 3])
        check("to_frames discards a short trailing frame", length(got), 1)
      ),

      # --- mask parsing and application -------------------------------------
      (
        m = Mask.parse("bit 28_100\nbit 29_5\n# comment\n\n")
        check("mask parses <minor>_<bit>", MapSet.to_list(m) |> Enum.sort(), [{28, 100}, {29, 5}])
      ),
      (
        # one frame per minor, 101 words, offset 0, 49 words of tile data.
        # bit 29_5 -> word 0, bit 5.  Masking must clear ONLY that bit.
        frames = for _ <- 0..29, do: List.duplicate(0xFFFF_FFFF, 101)
        masked = Mask.parse("bit 29_5")
        out = Mask.apply(frames, masked, 0, 49)
        w = out |> Enum.at(29) |> Enum.at(0)
        untouched = out |> Enum.at(28) |> Enum.at(0)

        check("mask clears exactly the named bit", {w, untouched},
          {0xFFFF_FFFF &&& bnot(1 <<< 5), 0xFFFF_FFFF})
      ),
      (
        # a bit outside the tile's word window must be left alone entirely
        frames = for _ <- 0..29, do: List.duplicate(0xFFFF_FFFF, 101)
        out = Mask.apply(frames, Mask.parse("bit 29_5"), 60, 4)
        check("mask respects the tile word window", Enum.at(out, 29) |> Enum.at(0), 0xFFFF_FFFF)
      ),

      # --- the dark space arithmetic ----------------------------------------
      (
        tile = %{name: "t", baseaddr: 0, frames: 30, offset: 0, words: 49}
        all = SiliconSweep.undocumented_bits(tile, MapSet.new())
        check("full minors 28+29 space is 3136", length(all), 3136)
      ),
      (
        tile = %{name: "t", baseaddr: 0, frames: 30, offset: 0, words: 49}
        doc = MapSet.new(for b <- 0..521, do: {28, b})
        check("documented bits are excluded",
          length(SiliconSweep.undocumented_bits(tile, doc)), 3136 - 522)
      ),

      # --- the WRITE path: no pad frame, and a start before desync ----------
      # The pipeline pad exists on the way OUT of the engine, not on the way in.
      # Getting that backwards shifts every written frame by one -- the same
      # invisible-and-fatal class as the readback pad, in the opposite
      # direction, so it is asserted separately.
      check("write_sequence has no pad frame in its word count",
        Readback.write_sequence(0x402400, 30) |> List.last() |> then(&(&1 &&& 0x07FF_FFFF)),
        30 * 101),
      # Found by PATTERN, not by index. The first version asserted on a fixed
      # offset and broke the moment the preamble grew from 1 word to 12 -- which
      # is exactly the kind of silent structural drift this file exists to
      # catch, so it should not itself depend on a hardcoded position.
      (
        t2 =
          Readback.arm_sequence(0x402400, 30)
          |> Enum.find(fn w -> (w >>> 29) == 2 and ((w >>> 27) &&& 3) == 1 end)

        check("read arms with one EXTRA frame for the pad", t2 &&& 0x07FF_FFFF, 31 * 101)
      ),
      check("preamble carries the bus width detect pattern",
        Enum.slice(Readback.preamble(), 8, 3), [0x0000_00BB, 0x1122_0044, 0xFFFF_FFFF]),
      check("preamble is 12 words ending in sync",
        {length(Readback.preamble()), List.last(Readback.preamble())}, {12, 0xAA99_5566}),
      check("readback cleanup is 6 words, DESYNC, no START",
        {length(Readback.readback_cleanup()), Enum.at(Readback.readback_cleanup(), 1)},
        {6, 0x0D}),
      check("disarm issues START before DESYNC",
        Readback.disarm_sequence() |> Enum.take(2) |> List.last(), 0x05),

      # --- group testing must refuse, loudly --------------------------------
      check("grouptest refuses", SiliconSweep.GroupTesting.run(nil),
        {:error, :invalid_method_see_moduledoc}),

      # --- every board strategy must report BLOCKED, never fake success -----
      check("readback strategies declare the dma buffer prerequisite",
        :dma_buffer in SiliconSweep.prerequisites(:census), true)
    ]

    n = length(results)
    ok = Enum.count(results, & &1)
    IO.puts("\n#{ok}/#{n} passed")
    if ok < n, do: System.halt(1)
  end
end

T.run()
