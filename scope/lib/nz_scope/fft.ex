defmodule NzScope.FFT do
  @moduledoc """
  Pure-Elixir complex FFT for the spectrum path. No NIFs, no deps.

  Input is what `Nervezynq.SDR.rx_binary/1` ships: interleaved
  `<<i::little-signed-16, q::little-signed-16, ...>>`, 12-bit samples
  sign-extended into s16 (full scale ±2048 — |z| ~2047 on the BIST tone).

  Output is what the Waterfall/Spectrum canvases eat: `fft_size` f32-native
  dB values, **DC-centered** (fftshift applied), so bin 0 is -fs/2 and bin
  fft_size/2 is the LO. Calibration: a full-scale complex tone lands at
  ~0 dBFS regardless of window (coherent gain is divided out).

  1024-point cost is a few ms on anything mac-shaped; comfortable at
  snapshot-capture row rates. This is deliberately not the V2 streaming
  answer — when `stream_rx/2` lands and row rates go up 100x, this module
  is the thing to replace with a NIF (minutemodem's `ui_dsp` is the
  template, it just needs a complex-input entry point).
  """

  import Bitwise

  @full_scale 2048.0

  @doc """
  Interleaved s16le IQ binary → f32-native dB bins, DC-centered.

  Zero-pads (or truncates) to `fft_size`, which must be a power of two.
  `rx/1`'s ~1020-pair captures against a 1024 FFT lose ~0.03 dB to
  padding — noise, not signal.
  """
  @spec iq_db_bins(binary(), pos_integer(), keyword()) :: binary()
  def iq_db_bins(iq_binary, fft_size \\ 1024, opts \\ []) do
    window = Keyword.get(opts, :window, :hann)

    samples = parse_iq(iq_binary, fft_size)
    w = window(window, fft_size)
    cg = coherent_gain(window, fft_size)

    windowed =
      Enum.zip_with(samples, w, fn {re, im}, wn -> {re * wn, im * wn} end)

    spectrum = fft(windowed)

    scale = 1.0 / (fft_size * cg)
    s2 = scale * scale

    dbs =
      for {re, im} <- spectrum do
        # 20*log10(|X| * scale), computed without the sqrt
        10.0 * :math.log10((re * re + im * im) * s2 + 1.0e-12)
      end

    dbs
    |> fftshift()
    |> pack_f32()
  end

  @doc """
  In-order (NOT shifted) complex FFT of a list of `{re, im}` tuples.
  Length must be a power of two.
  """
  def fft([_] = one), do: one

  def fft(list) do
    n = length(list)

    if (n &&& n - 1) != 0 do
      raise ArgumentError, "FFT length must be a power of two, got #{n}"
    end

    do_fft(list, n)
  end

  defp do_fft([_] = one, 1), do: one

  defp do_fft(list, n) do
    {evens, odds} = split_evens_odds(list)
    half = div(n, 2)

    fe = do_fft(evens, half)
    fo = do_fft(odds, half)

    tw = twiddles(n)

    prods =
      Enum.zip_with(tw, fo, fn {c, s}, {re, im} ->
        {c * re - s * im, c * im + s * re}
      end)

    front = Enum.zip_with(fe, prods, fn {ar, ai}, {br, bi} -> {ar + br, ai + bi} end)
    back = Enum.zip_with(fe, prods, fn {ar, ai}, {br, bi} -> {ar - br, ai - bi} end)

    front ++ back
  end

  defp split_evens_odds(list), do: split_evens_odds(list, [], [])
  defp split_evens_odds([], evens, odds), do: {Enum.reverse(evens), Enum.reverse(odds)}
  defp split_evens_odds([e], evens, odds), do: {Enum.reverse([e | evens]), Enum.reverse(odds)}

  defp split_evens_odds([e, o | rest], evens, odds),
    do: split_evens_odds(rest, [e | evens], [o | odds])

  # e^{-2πik/n} for k in 0..n/2-1, cached per n — the same tables are hit
  # on every frame, no reason to re-run trig.
  defp twiddles(n) do
    key = {__MODULE__, :tw, n}

    case :persistent_term.get(key, nil) do
      nil ->
        tw =
          for k <- 0..(div(n, 2) - 1) do
            ang = -2.0 * :math.pi() * k / n
            {:math.cos(ang), :math.sin(ang)}
          end

        :persistent_term.put(key, tw)
        tw

      tw ->
        tw
    end
  end

  # --- windows -----------------------------------------------------------------

  defp window(kind, n) do
    key = {__MODULE__, :win, kind, n}

    case :persistent_term.get(key, nil) do
      nil ->
        w = build_window(kind, n)
        :persistent_term.put(key, w)
        w

      w ->
        w
    end
  end

  defp build_window(:none, n), do: List.duplicate(1.0, n)

  defp build_window(:hann, n) do
    for i <- 0..(n - 1), do: 0.5 * (1.0 - :math.cos(2.0 * :math.pi() * i / (n - 1)))
  end

  defp build_window(:hamming, n) do
    for i <- 0..(n - 1), do: 0.54 - 0.46 * :math.cos(2.0 * :math.pi() * i / (n - 1))
  end

  defp build_window(:blackman, n) do
    for i <- 0..(n - 1) do
      x = 2.0 * :math.pi() * i / (n - 1)
      0.42 - 0.5 * :math.cos(x) + 0.08 * :math.cos(2.0 * x)
    end
  end

  defp coherent_gain(kind, n) do
    key = {__MODULE__, :cg, kind, n}

    case :persistent_term.get(key, nil) do
      nil ->
        cg = Enum.sum(window(kind, n)) / n
        :persistent_term.put(key, cg)
        cg

      cg ->
        cg
    end
  end

  # --- parsing / packing --------------------------------------------------------

  defp parse_iq(bin, fft_size) do
    take = min(div(byte_size(bin), 4), fft_size)

    samples =
      for <<i::little-signed-16, q::little-signed-16 <- binary_part(bin, 0, take * 4)>> do
        {i / @full_scale, q / @full_scale}
      end

    case fft_size - take do
      0 -> samples
      pad -> samples ++ List.duplicate({0.0, 0.0}, pad)
    end
  end

  defp fftshift(list) do
    half = div(length(list), 2)
    {front, back} = Enum.split(list, half)
    back ++ front
  end

  defp pack_f32(floats) do
    for f <- floats, into: <<>>, do: <<f::float-32-native>>
  end
end
