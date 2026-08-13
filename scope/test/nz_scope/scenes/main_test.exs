defmodule NzScope.Scenes.MainTest do
  @moduledoc """
  The scene's declaration, as data.

  `view/1` is a pure function, so the shape of what it asks for can be checked
  without wx, without a GL context and without a board. That is worth doing
  for the waterfall in particular: its dB range and its frequency ticks are
  part of the declaration now, and a mistake there does not crash — it renders
  a waterfall with no ruler, or one whose floor control does nothing.
  """

  use ExUnit.Case, async: true

  alias NzScope.Scenes.Main

  defp model(overrides \\ %{}) do
    base = %{
      host_text: "127.0.0.1",
      connected: true,
      freq_text: "2412.0",
      gain_db: 40,
      db_min: -100,
      db_max: 0,
      paused: false,
      meta: %{freq: 2_412_000_000, fs: 8_000_000, gain: 40, n: 1020},
      fps: 20.0,
      status_text: "",
      last_error: nil
    }

    Map.merge(base, overrides)
  end

  defp waterfall(model) do
    model
    |> Main.view()
    |> Enum.find(fn
      {:ensure_visual, :waterfall, _type, _parent, _opts} -> true
      _ -> false
    end)
  end

  defp layer(model, name) do
    {:ensure_visual, :waterfall, :layers, :root, opts} = waterfall(model)
    Keyword.fetch!(Keyword.fetch!(opts, :layers), name)
  end

  describe "the waterfall declaration" do
    test "is a layered visual, not a hand-written canvas" do
      assert {:ensure_visual, :waterfall, :layers, :root, _opts} = waterfall(model())
    end

    test "stacks the ticks over the history, in that order" do
      # Draw order is declaration order. Reversed, the image would paint over
      # the ruler and the overlay would silently not exist.
      {:ensure_visual, :waterfall, :layers, :root, opts} = waterfall(model())

      assert Keyword.keys(opts[:layers]) == [:history, :minor_ticks, :major_ticks]
    end

    test "the dB range is declared, so the differ carries a change" do
      {:image, opts} = layer(model(%{db_min: -120, db_max: -10}), :history)

      assert opts[:domain] == {-120.0, -10.0}
    end

    test "changing the floor changes only the image layer" do
      # The point of declaring it: the runtime sees one layer's options change
      # and writes a uniform. It does not reallocate the texture, so the
      # scroll history survives a drag of the floor control.
      before = layer(model(%{db_min: -100}), :minor_ticks)
      later = layer(model(%{db_min: -130}), :minor_ticks)

      assert before == later
    end

    test "the history is a full-width scrolling ring" do
      {:image, opts} = layer(model(), :history)

      assert opts[:grid] == {NzScope.Link.fft_size(), 512}
      assert opts[:advance] == :per_datum
      assert opts[:colormap] == :turbo
    end
  end

  describe "the frequency ticks" do
    test "are declared as geometry, not pushed as data" do
      {:line, opts} = layer(model(), :minor_ticks)

      assert is_list(opts[:polylines])
      assert opts[:polylines] != []
    end

    test "each tick is its own run" do
      # Disjoint verticals. As one polyline the connecting strokes would be
      # drawn straight across the display.
      {:line, opts} = layer(model(), :minor_ticks)

      assert Enum.all?(opts[:polylines], fn run ->
               match?([{_x0, -1.0}, {_x1, +1.0}], run)
             end)
    end

    test "a tick is vertical" do
      {:line, opts} = layer(model(), :major_ticks)
      [[{x0, _}, {x1, _}] | _] = opts[:polylines]

      assert x0 == x1
    end

    test "ticks land inside clip space" do
      {:line, opts} = layer(model(), :minor_ticks)

      assert Enum.all?(opts[:polylines], fn [{x, _}, _] -> x >= -1.0 and x <= 1.0 end)
    end

    test "majors are brighter than minors" do
      {:line, minor} = layer(model(), :minor_ticks)
      {:line, major} = layer(model(), :major_ticks)

      assert elem(major[:color], 0) > elem(minor[:color], 0)
    end

    test "majors and minors are disjoint sets" do
      {:line, minor} = layer(model(), :minor_ticks)
      {:line, major} = layer(model(), :major_ticks)

      minor_x = MapSet.new(minor[:polylines], fn [{x, _}, _] -> x end)
      major_x = MapSet.new(major[:polylines], fn [{x, _}, _] -> x end)

      assert MapSet.disjoint?(minor_x, major_x)
      assert MapSet.size(major_x) > 0
    end

    test "retuning moves the ticks" do
      # Absolute anchoring: markers sit on round frequencies and slide as the
      # radio retunes, rather than being nailed to the window.
      here = layer(model(), :minor_ticks)
      there = layer(model(%{meta: %{freq: 2_413_500_000, fs: 8_000_000}}), :minor_ticks)

      refute here == there
    end

    test "no board meta means no ticks, not a crash" do
      {:line, opts} = layer(model(%{meta: nil}), :minor_ticks)

      assert opts[:polylines] == []
    end
  end
end
