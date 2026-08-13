defmodule NzScope.Ticks do
  @moduledoc """
  The frequency-marker rule, in one pure place.

  Given the tuned LO and the sample rate (== visible span), produce tick
  positions that sit on NICE ABSOLUTE frequencies — multiples of a 1/2/5
  step — so the lines land on round numbers (…2460, 2462, 2464…) and
  slide across the display when the radio retunes. That absolute anchoring
  is the whole point: the markers tell you where you ARE, not where the
  window is.

  The step is chosen 1-2-5-style from the span aiming at ~`target` ticks
  (12 MHz span → 2 MHz/div, 8 MHz → 1 MHz/div), and every 5th step —
  multiples of `5 × step` — is a MAJOR tick, drawn brighter, so absolute
  identification survives even without per-tick labels: find a major,
  count minors. The scene renders the matching legend text; the canvases
  only ever see `{hz, x_ndc, major?}`.

  All arithmetic is integer Hz until the final NDC projection, so ticks
  never drift off their nominal frequencies.
  """

  @doc """
  Plan ticks for a window: `lo_hz` center, `fs_hz` span, ~`target` ticks.

  Returns `%{step: hz, major: hz, ticks: [%{hz:, x:, major?:}]}` with `x`
  in NDC (-1.0 .. +1.0). Degenerate input returns an empty plan.
  """
  def plan(lo_hz, fs_hz, target \\ 8)

  def plan(lo_hz, fs_hz, target)
      when is_integer(lo_hz) and is_integer(fs_hz) and fs_hz > 0 and target > 0 do
    step = nice_125(max(div(fs_hz, target), 1))
    major = step * 5
    half = div(fs_hz, 2)

    f_lo = lo_hz - half
    f_hi = lo_hz + half
    first = ceil_div(f_lo, step) * step

    ticks =
      first
      |> Stream.iterate(&(&1 + step))
      |> Enum.take_while(&(&1 <= f_hi))
      |> Enum.map(fn f ->
        %{hz: f, x: (f - lo_hz) / half, major?: rem(f, major) == 0}
      end)

    %{step: step, major: major, ticks: ticks}
  end

  def plan(_lo, _fs, _target), do: %{step: nil, major: nil, ticks: []}

  @doc "Legend line for the scene's ruler text, or nil for a degenerate plan."
  def legend(lo_hz, fs_hz, target \\ 8)

  def legend(lo_hz, fs_hz, target) when is_integer(lo_hz) and is_integer(fs_hz) and fs_hz > 0 do
    %{step: step, major: major} = plan(lo_hz, fs_hz, target)
    half = div(fs_hz, 2)

    "#{mhz(step)} MHz/div (bright = #{mhz(major)} MHz)  |  " <>
      "#{mhz(lo_hz - half)} … #{mhz(lo_hz)} … #{mhz(lo_hz + half)} MHz"
  end

  def legend(_lo, _fs, _target), do: nil

  # Snap up to the nearest 1/2/5 x 10^k, in integer Hz.
  defp nice_125(x) when x >= 1 do
    k = pow10(x)

    cond do
      x <= 1 * k -> 1 * k
      x <= 2 * k -> 2 * k
      x <= 5 * k -> 5 * k
      true -> 10 * k
    end
  end

  defp pow10(x), do: pow10(x, 1)
  defp pow10(x, acc) when x >= 10, do: pow10(div(x, 10), acc * 10)
  defp pow10(_x, acc), do: acc

  defp ceil_div(a, b) when a >= 0, do: div(a + b - 1, b)
  defp ceil_div(a, b), do: -div(-a, b)

  defp mhz(hz) do
    m = hz / 1.0e6
    if m == trunc(m), do: "#{trunc(m)}", else: "#{Float.round(m, 3)}"
  end
end
