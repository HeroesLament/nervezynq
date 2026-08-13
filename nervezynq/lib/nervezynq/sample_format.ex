defmodule Nervezynq.SampleFormat do
  @moduledoc """
  Work out what the captured 12-bit words actually mean.

  **This is settled. Use `decode_mimo/2`.** Everything below it —
  `decode/1`, `decode2/1`, `analyse/1`, `validate/1`, `validate2/1` — predates the
  answer and is kept only to decode old captures and to document how the answer
  was reached. `decode2/1` in particular brute-force searches `pa`/`pb` for the
  assignment that minimises `mag_cv`; that is a fit, not a measurement, it ignores
  `RX_FRAME` entirely, and it decimates by two on the assumption that both
  channels carry the same pattern — which is true only for the BIST tone and
  discards the second channel. It also lands on the conjugate of the correct
  assignment, which is why it reports `deg_per_sample = -11.252` where the tone
  actually advances `+11.25`.

  What settled it:

    * `RX_FRAME` in **pulse mode** (`0x010` bit 3) gives a clean period-4 cycle
      `[3, 1, 0, 2]` in the captured frame bits. Level mode reads a constant `3`
      and is a dead end — pulse mode is what LibreSDR ships
      (`adi,rx-frame-pulse-mode-enable`). Rotating each capture so the frame
      sequence starts at `3` makes slot identity stable; without it the capture
      start phase is random mod 4 and every per-slot statistic is void.
    * The 12-bit word is `{previous 6 bits, current 6 bits}` from one edge, per
      ADI's `axi_ad9361_lvds_if.v`. The AD9363 sends the MSB nibble first, so at
      the cycle a word completes the current six bits are the LSBs. Measured under
      BIST: `mag_cv 3.4e-4` with the swap against `0.376` without.
    * Channel assignment confirmed twice independently — by per-channel gain
      (19 dB split falling exactly on the pair boundary) and by `RX_CHANNEL_SWAP`
      cleanly exchanging the pairs.
    * I/Q assignment and rotation sign confirmed against the tone's known
      direction: `+11.25` deg/sample on both channels, no conjugation.

  ## The measurement

  The AD9363's BIST tone at frequency index 0 is `Fs/32`, so over 32 samples at
  `Fs` the tone advances exactly one full cycle. If a candidate pair of slots
  really is `(I, Q)` of a complex tone, then interpreted correctly:

    * `I^2 + Q^2` is **constant** — the magnitude of a complex sinusoid does not
      vary — so the coefficient of variation of the magnitude is near zero
    * the phase `atan2(Q, I)` advances by a constant `2*pi/32` per sample

  Both fail for the wrong pairing, the wrong signedness, or a real (non-complex)
  tone. So the format falls out of one capture: score every hypothesis and read
  off the winner. Constant magnitude is the sharp test, because it is a property
  no incorrect interpretation reproduces by accident.
  """

  import Bitwise
  alias Nervezynq.{AD9363, LVDSProbe}

  @doc "12-bit two's complement."
  def signed12(v) when v >= 2048, do: v - 4096
  def signed12(v), do: v

  @doc "12-bit offset binary (0x800 = zero), the alternative hypothesis."
  def offset12(v), do: v - 2048

  @doc """
  Find the frame phase, using the slot0 == slot2 invariant.

  Returns the offset to drop from the front of the capture so that index 0 is
  slot 0 of a frame.
  """
  def frame_phase(words) do
    arr = words |> Enum.map(&(&1 &&& 0xFFF)) |> List.to_tuple()
    n = tuple_size(arr)

    0..3
    |> Enum.map(fn p ->
      hits =
        for(i <- 0..(n - 3), rem(i, 4) == p, do: elem(arr, i) == elem(arr, i + 2))
        |> Enum.count(& &1)

      {p, hits}
    end)
    |> Enum.max_by(fn {_p, hits} -> hits end)
    |> elem(0)
  end

  @doc """
  Score every (I slot, Q slot, interpretation) hypothesis against one capture.

  Lower `mag_cv` is better: it is the coefficient of variation of `I^2 + Q^2`
  across the capture. A correct complex-tone interpretation gives a small value;
  everything else does not.
  """
  def analyse(words) do
    phase = frame_phase(words)

    frames =
      words
      |> Enum.map(&(&1 &&& 0xFFF))
      |> Enum.drop(phase)
      |> Enum.chunk_every(4, 4, :discard)

    slots = Enum.map(0..3, fn k -> Enum.map(frames, &Enum.at(&1, k)) end)

    hypotheses =
      for {name, conv} <- [{:twos_complement, &signed12/1}, {:offset_binary, &offset12/1}],
          i <- 0..3,
          q <- 0..3,
          i != q do
        is = Enum.at(slots, i) |> Enum.map(conv)
        qs = Enum.at(slots, q) |> Enum.map(conv)

        mags = Enum.zip(is, qs) |> Enum.map(fn {a, b} -> a * a + b * b end)
        mean = Enum.sum(mags) / length(mags)

        cv =
          if mean > 0 do
            var = Enum.reduce(mags, 0, fn m, acc -> acc + (m - mean) * (m - mean) end) / length(mags)
            :math.sqrt(var) / mean
          else
            999.0
          end

        %{format: name, i_slot: i, q_slot: q, mag_cv: Float.round(cv, 4),
          mag_rms: round(:math.sqrt(mean))}
      end

    %{frame_phase: phase, frames: length(frames),
      ranked: hypotheses |> Enum.sort_by(& &1.mag_cv) |> Enum.take(6)}
  end

  @doc """
  Estimate the tone's cycles-per-frame from the winning hypothesis, by counting
  sign changes of I. `Fs/32` predicts one cycle per 32 frames.
  """
  def tone_period(words, i_slot, conv \\ &__MODULE__.signed12/1) do
    phase = frame_phase(words)

    is =
      words
      |> Enum.map(&(&1 &&& 0xFFF))
      |> Enum.drop(phase)
      |> Enum.chunk_every(4, 4, :discard)
      |> Enum.map(&conv.(Enum.at(&1, i_slot)))

    crossings =
      is
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.count(fn [a, b] -> (a < 0 and b >= 0) or (a >= 0 and b < 0) end)

    # two zero crossings per cycle
    if crossings > 0, do: Float.round(2 * length(is) / crossings, 2), else: :none
  end

  @doc """
  Decode a capture into I/Q sample pairs. **This is the confirmed format.**

  Transcribed from ADI's `axi_ad9361_lvds_if.v`:

      adc_data_p[23:12] <= {rx_data_1, rx_data_1_s};
      adc_data_p[11: 0] <= {rx_data_0, rx_data_0_s};

  `rx_data_0` and `rx_data_1` are the two DDR edges, 6 bits each; `_s` is the
  registered *previous* cycle. So a 12-bit sample is `{current 6 bits, previous 6
  bits} from the same edge` — and the two edges carry **two different samples in
  parallel**, each taking two DATA_CLK cycles to deliver its 12 bits.

  That is the thing this project got structurally wrong. `sample_word = {fall_q,
  rise_q}` in `LibreSDRRadio.Top` glues 6 bits of one sample to 6 bits of a
  *different* one, so every 12-bit word was half of each of two samples. It
  looked like a plausible sample stream — 491 distinct values, a period-4
  structure, a clean eye diagram — and none of it decoded, which is exactly the
  failure mode this project keeps meeting: a wrong reading that is not obviously
  wrong.

  Confirmed on hardware with the `Fs/32` BIST tone: constant magnitude at 2048
  (full scale) and phase advancing 11.25 degrees per sample, which is precisely
  360/32.

  Returns `{i_samples, q_samples}`, decimated by two because both receive
  channels carry the same BIST pattern and each sample therefore appears twice.
  """
  def decode(words) do
    rise = Enum.map(words, &(&1 &&& 0x3F))
    fall = Enum.map(words, &(&1 >>> 6 &&& 0x3F))

    # The two edges need opposite pair-phase: `sample_word` combines fall(n) with
    # rise(n), and the design's one-cycle realignment offsets them by one.
    i = pair(rise, 1)
    q = pair(fall, 0)

    # Both channels carry the same pattern, so each sample lands twice.
    {dec2(i), dec2(q)}
  end

  defp pair(stream, phase) do
    stream
    |> Enum.drop(phase)
    |> Enum.chunk_every(2, 2, :discard)
    |> Enum.map(fn [prev, cur] -> signed12(cur <<< 6 ||| prev) end)
  end

  defp dec2(l), do: l |> Enum.chunk_every(2, 2, :discard) |> Enum.map(&hd/1)

  @doc """
  Validate a capture against the complex-tone invariants.

  `mag_cv` near zero says the magnitude is constant, which only a correct complex
  reading gives. `deg_per_sample` should be 360/32 = 11.25 for tone index 0.
  """
  def validate(words) do
    {is, qs} = decode(words)
    pairs = Enum.zip(is, qs)

    mags = Enum.map(pairs, fn {i, q} -> :math.sqrt(i * i + q * q) end)
    mean = Enum.sum(mags) / length(mags)
    var = Enum.reduce(mags, 0, fn m, a -> a + (m - mean) * (m - mean) end) / length(mags)

    phases = Enum.map(pairs, fn {i, q} -> :math.atan2(q, i) end)

    steps =
      phases
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] ->
        d = b - a
        cond do
          d > :math.pi() -> d - 2 * :math.pi()
          d < -:math.pi() -> d + 2 * :math.pi()
          true -> d
        end
      end)

    med = steps |> Enum.sort() |> Enum.at(div(length(steps), 2))

    %{
      samples: length(pairs),
      mag_mean: Float.round(mean, 1),
      mag_cv: Float.round(:math.sqrt(var) / mean, 5),
      deg_per_sample: Float.round(med * 180 / :math.pi(), 3),
      predicted_deg: Float.round(360 / 32, 3)
    }
  end


  # --- the fabric-assembled format (top4.v onwards) ---------------------------

  @doc """
  Decode a capture from the **fixed** fabric, where each word already carries two
  properly assembled 12-bit samples.

      [11:0]  sample_a  -- rising-edge sample,  {current 6, previous 6}
      [23:12] sample_b  -- falling-edge sample, likewise
      [25:24] RX_FRAME pair

  `decode/1` above exists to re-splice captures from *before* that fix and should
  not be used on new ones.

  Three binary choices remain, and all three are properties of the wire rather
  than of the design, so they are resolved by measurement:

    * **pair parity** — a sample spans two DATA_CLK cycles, so one of the two
      word parities aligns and the other straddles. Chosen independently for each
      edge, because the two edges are captured half a cycle apart.
    * **channel parity** — in 2R2T both receive channels share each edge's
      stream, alternating, and both carry the same BIST pattern. Decimating by
      two picks one channel.
    * **relative offset** — the two edges are not two halves of one complex
      sample. In 2R2T the transceiver sends `I1, Q1, I2, Q2` spread across both
      edges, so I and Q of a channel can be a whole sample apart in the stream.

  The offsets are searched over **eight** words each, not four. Four is the
  decimation stride, so `0..3` looks like it must exhaust the grid — and it does
  for `I` considered alone. But `I` and `Q` are offset independently, and the
  physical requirement turns out to be `pb = pa - 1` in every capture:

  **Q's assembly window sits one DATA_CLK cycle earlier than I's.** The two DDR
  edges do not carry I and Q of the same instant.

  When a capture happens to begin with `pa` congruent to 0, expressing that needs
  `pa = 4`, which `0..3` cannot reach. Two intermediate wrong answers are worth
  recording, because each was wrong in an informative way:

    * `pa, pb` in `0..1` — magnitude oscillated *smoothly* between 1836 and 2241
      at **twice** the tone frequency, 223 of 255 samples off by more than 1%. Bit
      errors are isolated and random; a smooth ripple at `2f` is `cos(wt)` paired
      against `sin(w(t+d))`, and its amplitude gives `d` — `sin(w*d) ~ 0.2` at
      `w = 11.25 deg` puts `d` at one whole sample, which is what it was.
    * `pa, pb` in `0..3` — one capture hit `3.4e-4` and the next two plateaued at
      `0.0077`, a 20x spread with nothing else changed. Alignment that depends on
      when you pressed capture is alignment you have not found. Widening to `0..7`
      put every capture at `3.4e-4` at `(pa, pa - 1)`.

  Searching a grid this way is not the blind hypothesis search that failed
  earlier: `mag_cv` is now a *validated* discriminator, `3.4e-4` for the right
  answer against order-unity for every wrong one. A metric with three orders of
  magnitude of contrast is a measurement, not a fit — and it was sharp enough to
  catch both of the above rather than quietly accept them.

  Returns `{:ok, %{i: [...], q: [...], parity_a: _, parity_b: _, mag_cv: _}}`.
  """
  def decode2(words) do
    a = Enum.map(words, &(&1 &&& 0xFFF))
    b = Enum.map(words, &(&1 >>> 12 &&& 0xFFF))

    for pa <- 0..7, pb <- 0..7 do
      is = a |> Enum.drop(pa) |> alternate() |> alternate() |> Enum.map(&signed12/1)
      qs = b |> Enum.drop(pb) |> alternate() |> alternate() |> Enum.map(&signed12/1)
      n = min(length(is), length(qs))
      is = Enum.take(is, n)
      qs = Enum.take(qs, n)
      %{i: is, q: qs, parity_a: pa, parity_b: pb, mag_cv: mag_cv(is, qs)}
    end
    |> Enum.min_by(& &1.mag_cv)
    |> then(&{:ok, &1})
  end

  # Twice, not once. Pair parity and channel parity are two independent strides of
  # two: the first picks the aligned word of each pair, the second picks one of the
  # two receive channels sharing that edge. Collapsing them into one stride leaves
  # the two channels interleaved, and because both carry the same tone the
  # magnitude test still passes -- `mag_cv` came out 0.008 -- while the phase step
  # collapses to a meaningless -0.851 deg, since half the adjacent pairs are the
  # same instant on the other channel and the median lands between the two
  # populations. A metric that survives the mistake is not a check on it.
  #
  # Which channel is taken does not matter: both are fed the same BIST pattern, so
  # either offset gives the same 11.25 deg per sample.
  defp alternate(l), do: l |> Enum.chunk_every(2, 2, :discard) |> Enum.map(&hd/1)

  defp mag_cv([], _), do: 999.0
  defp mag_cv(is, qs) do
    mags = Enum.zip(is, qs) |> Enum.map(fn {i, q} -> :math.sqrt(i * i + q * q) end)
    mean = Enum.sum(mags) / length(mags)

    if mean <= 0 do
      999.0
    else
      var = Enum.reduce(mags, 0, fn m, acc -> acc + (m - mean) * (m - mean) end) / length(mags)
      :math.sqrt(var) / mean
    end
  end

  @doc """
  The tone oracle: `mag_cv` for the best decoding of a capture.

  This replaces `LVDSProbe.match_rate/1` for anything that needs a quality
  number. `match_rate/1` scored `w[n] == w[n+2]` on the old mis-assembled words;
  that invariant was an artefact of splicing two half-samples and does not hold
  for correctly assembled ones. Low is good here, where high was good there.
  """
  def tone_cv(words) do
    {:ok, r} = decode2(words)
    r.mag_cv
  end

  @doc "Validate a fabric-assembled capture: magnitude constant, phase step 11.25 deg."
  def validate2(words) do
    {:ok, r} = decode2(words)

    Map.merge(
      phase_stats(r.i, r.q),
      %{parity_a: r.parity_a, parity_b: r.parity_b, mag_cv: Float.round(r.mag_cv, 5)}
    )
  end

  defp phase_stats(is, qs) do
    pairs = Enum.zip(is, qs)
    mags = Enum.map(pairs, fn {i, q} -> :math.sqrt(i * i + q * q) end)

    steps =
      pairs
      |> Enum.map(fn {i, q} -> :math.atan2(q, i) end)
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [x, y] -> wrap(y - x) end)

    %{
      samples: length(pairs),
      mag_mean: Float.round(Enum.sum(mags) / length(mags), 1),
      deg_per_sample:
        Float.round(Enum.at(Enum.sort(steps), div(length(steps), 2)) * 180 / :math.pi(), 3),
      predicted_deg: Float.round(360 / 32, 3)
    }
  end

  defp wrap(d) when d > 3.141592653589793, do: d - 2 * :math.pi()
  defp wrap(d) when d < -3.141592653589793, do: d + 2 * :math.pi()
  defp wrap(d), do: d

  @doc "Set up the Fs/32 tone, capture, and report the format."
  def identify(opts \\ []) do
    level = Keyword.get(opts, :level_db, 0)
    {:ok, _} = AD9363.bist_tone(:rx, 0, level, 0)
    Process.sleep(80)

    with {:ok, words} <- LVDSProbe.capture(1024) do
      a = analyse(words)
      best = hd(a.ranked)

      IO.puts("frame phase #{a.frame_phase}, #{a.frames} frames")
      IO.puts("")
      IO.puts("  format            I  Q   mag_cv   mag_rms")

      Enum.each(a.ranked, fn h ->
        IO.puts(
          "  #{String.pad_trailing(to_string(h.format), 17)} #{h.i_slot}  #{h.q_slot}   " <>
            "#{String.pad_leading(to_string(h.mag_cv), 6)}    #{h.mag_rms}"
        )
      end)

      conv = if best.format == :twos_complement, do: &signed12/1, else: &offset12/1
      period = tone_period(words, best.i_slot, conv)

      IO.puts("")
      IO.puts("best: #{best.format}, I=slot#{best.i_slot} Q=slot#{best.q_slot}, mag_cv=#{best.mag_cv}")
      IO.puts("tone period from I sign changes: #{period} frames  (Fs/32 predicts 32)")

      {:ok, Map.put(a, :tone_period_frames, period)}
    end
  end
end
