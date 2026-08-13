defmodule Nervezynq.MIMO do
  @moduledoc """
  The confirmed 2R2T receive decode.

  `Nervezynq.SampleFormat` is the archaeology: hypothesis searches, parity grids
  and a `decode2/1` that brute-forces the assignment minimising `mag_cv`. That is
  a fit, not a measurement. This module is the answer, and every step of it is
  either read out of ADI's `axi_ad9361_lvds_if.v` or confirmed by a measurement
  with three orders of magnitude of contrast.

  ## The chain

      RX_FRAME pulse mode (0x010 bit 3) -> frame bits [25:24] give cycle [3,1,0,2]
      rotate so the sequence starts at 3            -> stable slot identity
      one cap word = one DATA_CLK cycle
      per cycle one 12-bit word completes, alternating fall- and rise-derived
      word = {previous 6 bits, current 6 bits}, same edge
      four words per frame:
        phase 0 -> bits [23:12] -> I1     phase 1 -> bits [11:0] -> Q1
        phase 2 -> bits [23:12] -> I2     phase 3 -> bits [11:0] -> Q2

  Per-channel sample rate is `DATA_CLK / 4`.

  ## Why the rotation is not optional

  The capture start phase is random mod 4. Twenty back-to-back captures with no
  configuration change landed in one of two states that swap even and odd slots in
  both halves at once; the four underlying values were stable and only their
  labels moved. Every per-slot statistic taken without rotating first is void, and
  a whole sequence of apparent hardware faults - junk sub-streams, a noisy RX2, a
  broken RX1 gain register - dissolved once this was applied.

  ## Required transceiver state

      0x010 bit 3 = 1   RX_FRAME_PULSE_MODE   (level mode reads constant 3)
      0x010 bit 6 = 1   PP_RX_SWAP_IQ         (as LibreSDR ships)
      0x010 bit 4 = 0   RX_CHANNEL_SWAP

  With bit 6 cleared the I/Q assignment inverts and the tone rotates backwards;
  with bit 4 set the two channel pairs exchange. Both were confirmed by toggling.
  """

  import Bitwise

  # Frame bits [25:24] are {fall, rise}. ADI's rx_frame_s is {rise, fall}, so our
  # bit order is the reverse of theirs -- self-consistent, but do not read ADI's
  # case values directly against our captures.
  @frame_cycle [3, 1, 0, 2]

  # The fabric assembles sample_a = {rise_q, rise_q_d}, i.e. {current, previous},
  # which is the reverse of what the wire delivers. Until it is rebuilt as
  # {rise_q_d, rise_q}, software swaps the halves. Flip this in the same commit as
  # that rebuild, and verify with `validate/1` reporting mag_cv ~3e-4.
  @fabric_needs_nibble_swap true

  def fabric_needs_nibble_swap?, do: @fabric_needs_nibble_swap

  @doc "12-bit two's complement."
  def signed12(v) when v >= 2048, do: v - 4096
  def signed12(v), do: v

  @doc "Swap the two 6-bit halves of a 12-bit word."
  def swap_nibbles(v), do: (v <<< 6 ||| v >>> 6) &&& 0xFFF

  @doc """
  Words to drop so the capture starts at frame phase 0.

  `{:error, :no_frame}` means the first word's frame bits are not one of the four
  cycle values, which in practice means `RX_FRAME` is in level mode - where it
  reads a constant 3 and carries no phase at all.
  """
  def frame_offset([first | _]) do
    case Enum.find_index(@frame_cycle, &(&1 == (first >>> 24 &&& 0x3))) do
      nil -> {:error, :no_frame}
      idx -> {:ok, rem(4 - idx, 4)}
    end
  end

  def frame_offset([]), do: {:error, :no_frame}

  @doc """
  Check the frame bits actually follow `[3,1,0,2]` for the whole capture.

  Returns the fraction of words whose frame bits match the expected cycle. A
  healthy pulse-mode capture is `1.0`; anything less means the frame is not
  locked and the decode below is not trustworthy.
  """
  def frame_integrity(words) do
    with {:ok, off} <- frame_offset(words) do
      w = Enum.drop(words, off)

      ok =
        w
        |> Enum.with_index()
        |> Enum.count(fn {x, i} ->
          (x >>> 24 &&& 0x3) == Enum.at(@frame_cycle, rem(i, 4))
        end)

      {:ok, ok / max(length(w), 1)}
    end
  end

  @doc """
  Decode a capture into `%{ch1: [{i, q}], ch2: [{i, q}], frame_offset: n}`.

  Options:

    * `:nibble_swap` - override the fabric default, for decoding captures taken
      with a different bitstream.
  """
  def decode(words, opts \\ []) do
    swap = Keyword.get(opts, :nibble_swap, @fabric_needs_nibble_swap)

    with {:ok, off} <- frame_offset(words) do
      frames =
        words
        |> Enum.drop(off)
        |> Enum.chunk_every(4, 4, :discard)

      pairs =
        Enum.map(frames, fn [w0, w1, w2, w3] ->
          {{field(w0, 12, swap), field(w1, 0, swap)},
           {field(w2, 12, swap), field(w3, 0, swap)}}
        end)

      {:ok,
       %{
         ch1: Enum.map(pairs, &elem(&1, 0)),
         ch2: Enum.map(pairs, &elem(&1, 1)),
         frame_offset: off,
         samples: length(pairs)
       }}
    end
  end

  defp field(word, shift, swap) do
    raw = word >>> shift &&& 0xFFF
    signed12(if swap, do: swap_nibbles(raw), else: raw)
  end

  @doc """
  Validate a capture against the BIST tone invariants, per channel.

  With the `Fs/32` tone running, a correct decode gives constant magnitude near
  full scale and `+11.25` deg/sample on *both* channels. A negative rotation means
  I and Q are exchanged (check `PP_RX_SWAP_IQ`); a large `mag_cv` means the nibble
  order is wrong.
  """
  def validate(words, opts \\ []) do
    with {:ok, d} <- decode(words, opts) do
      {:ok,
       %{
         frame_offset: d.frame_offset,
         samples: d.samples,
         ch1: stats(d.ch1),
         ch2: stats(d.ch2),
         predicted_deg: Float.round(360 / 32, 3)
       }}
    end
  end

  defp stats([]), do: %{mag_mean: 0.0, mag_cv: 999.0, deg_per_sample: 0.0}

  defp stats(pairs) do
    mags = Enum.map(pairs, fn {i, q} -> :math.sqrt(i * i + q * q) end)
    mean = Enum.sum(mags) / length(mags)
    var = Enum.reduce(mags, 0, fn m, a -> a + (m - mean) * (m - mean) end) / length(mags)

    # Mean of arg(z[n+1] * conj(z[n])). Taken as a vector sum rather than a median
    # of wrapped differences: the median silently lands between two populations
    # when the stream is mis-decimated, which is exactly how an earlier decode
    # reported a meaningless -0.851 deg while looking healthy.
    {sx, sy} =
      pairs
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.reduce({0.0, 0.0}, fn [{i1, q1}, {i2, q2}], {x, y} ->
        {x + (i2 * i1 + q2 * q1), y + (q2 * i1 - i2 * q1)}
      end)

    %{
      mag_mean: Float.round(mean, 1),
      mag_cv: Float.round(if(mean > 0, do: :math.sqrt(var) / mean, else: 999.0), 5),
      deg_per_sample: Float.round(:math.atan2(sy, sx) * 180 / :math.pi(), 3)
    }
  end
end
