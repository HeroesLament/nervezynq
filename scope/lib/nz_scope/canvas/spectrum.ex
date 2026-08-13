defmodule NzScope.Canvas.Spectrum do
  @moduledoc """
  Live spectrum trace — the instantaneous view above the waterfall.

  Takes the same `{:bins, f32-native dB binary}` rows as the waterfall, so
  the producer sends one message to each. EMA smoothing keeps the trace
  readable at snapshot rates; the dB→screen mapping happens in the vertex
  shader so the grid and trace both re-map for free when the range changes.

  GL work is deliberately split by callback: `handle_data/2` only does CPU
  work (parse, smooth, build vertex binaries); all uploads and draws happen
  in `render/1`, where the runtime guarantees the context is current.

  ## Data

      WxMVU.GLCanvas.send_data(:spectrum, {:bins, binary})
      WxMVU.GLCanvas.send_data(:spectrum, {:set_range, -100.0, 0.0})
      WxMVU.GLCanvas.send_data(:spectrum, {:set_freq, lo_hz, fs_hz})
      WxMVU.GLCanvas.send_data(:spectrum, :clear)

  `set_freq` drives the frequency gridlines: vertical ticks on nice
  ABSOLUTE frequencies (NzScope.Ticks — the rule lives there), minors dim,
  majors (5x step) brighter. The scene sends it on every meta frame; the
  tick geometry only rebuilds when LO or fs actually changed.

  ## Options

      opts: [
        fft_size: 1024,
        db_min: -100.0, db_max: 0.0,
        smoothing: 0.35   # EMA weight of the NEW frame; 1.0 = no smoothing
      ]
  """

  use WxMVU.GLCanvas
  alias WxMVU.Renderer.GL
  require Logger

  @default_fft_size 1024
  @default_db_min -100.0
  @default_db_max 0.0
  @default_smoothing 0.35

  # Vertices carry {x_ndc, dB}; the shader maps dB into NDC from uniforms.
  @vertex_shader """
  #version 410 core
  layout(location = 0) in vec2 a_pos;   // x in NDC, y in dB
  uniform float u_db_min;
  uniform float u_db_max;
  void main() {
    float t = (a_pos.y - u_db_min) / (u_db_max - u_db_min);
    gl_Position = vec4(a_pos.x, clamp(t, -0.05, 1.05) * 2.0 - 1.0, 0.0, 1.0);
  }
  """

  @fragment_shader """
  #version 410 core
  uniform vec4 u_color;
  out vec4 frag_color;
  void main() { frag_color = u_color; }
  """

  @impl true
  def init(ctx, opts) do
    fft_size = Keyword.get(opts, :fft_size, @default_fft_size)
    db_min = Keyword.get(opts, :db_min, @default_db_min)
    db_max = Keyword.get(opts, :db_max, @default_db_max)
    smoothing = Keyword.get(opts, :smoothing, @default_smoothing)

    case create_program() do
      {:ok, program, uniforms} ->
        # Trace VBO: streamed every frame it changes.
        trace_vao = GL.create_vertex_array()
        trace_vbo = GL.create_buffer()
        bind_pos_vbo(trace_vao, trace_vbo)

        # Grid VBO: static line list at 10 dB steps over a generous span;
        # lines outside the current range clip away on their own.
        grid_vao = GL.create_vertex_array()
        grid_vbo = GL.create_buffer()
        bind_pos_vbo(grid_vao, grid_vbo)
        grid = grid_vertices()
        GL.bind_vertex_array(grid_vao)
        GL.bind_buffer(:array, grid_vbo)
        GL.buffer_data(:array, grid, :static)
        GL.bind_vertex_array(0)

        # Frequency-tick VBO: rebuilt whenever the tuned window changes.
        tick_vao = GL.create_vertex_array()
        tick_vbo = GL.create_buffer()
        bind_pos_vbo(tick_vao, tick_vbo)

        {w, h} = ctx.pixel_size
        GL.viewport(0, 0, w, h)

        {:ok,
         %{
           fft_size: fft_size,
           db_min: db_min,
           db_max: db_max,
           smoothing: smoothing,
           smoothed: nil,
           trace: nil,
           trace_dirty: false,
           program: program,
           uniforms: uniforms,
           trace_vao: trace_vao,
           trace_vbo: trace_vbo,
           grid_vao: grid_vao,
           grid_vbo: grid_vbo,
           grid_count: div(byte_size(grid), 8),
           tick_vao: tick_vao,
           tick_vbo: tick_vbo,
           tick_window: nil,
           tick_bin: nil,
           tick_minor_count: 0,
           tick_major_count: 0,
           tick_dirty: false
         }}

      {:error, reason} ->
        Logger.error("Spectrum: shader compilation failed: #{reason}")
        {:error, {:shader_failed, reason}}
    end
  end

  @impl true
  def handle_event(%Resize{pixel_size: {w, h}}, state) do
    GL.viewport(0, 0, w, h)
    {:noreply, state}
  end

  def handle_event(_event, state), do: {:noreply, state}

  @impl true
  def handle_data({:bins, binary}, state) when is_binary(binary) do
    n = min(div(byte_size(binary), 4), state.fft_size)
    fresh = for <<db::float-32-native <- binary_part(binary, 0, n * 4)>>, do: db

    smoothed =
      case state.smoothed do
        prev when is_list(prev) and length(prev) == n ->
          a = state.smoothing
          b = 1.0 - a
          Enum.zip_with(fresh, prev, fn f, p -> a * f + b * p end)

        _ ->
          fresh
      end

    trace = trace_vertices(smoothed, n)

    {:noreply, %{state | smoothed: smoothed, trace: trace, trace_dirty: true}}
  end

  def handle_data({:set_range, db_min, db_max}, state)
      when is_number(db_min) and is_number(db_max) and db_min < db_max do
    {:noreply, %{state | db_min: db_min * 1.0, db_max: db_max * 1.0}}
  end

  def handle_data({:set_freq, lo_hz, fs_hz}, state)
      when is_integer(lo_hz) and is_integer(fs_hz) do
    if {lo_hz, fs_hz} == state.tick_window do
      {:noreply, state}
    else
      %{ticks: ticks} = NzScope.Ticks.plan(lo_hz, fs_hz)
      {minors, majors} = Enum.split_with(ticks, &(not &1.major?))
      bin = tick_vertices(minors) <> tick_vertices(majors)

      {:noreply,
       %{
         state
         | tick_window: {lo_hz, fs_hz},
           tick_bin: bin,
           tick_minor_count: length(minors) * 2,
           tick_major_count: length(majors) * 2,
           tick_dirty: true
       }}
    end
  end

  def handle_data(:clear, state) do
    {:noreply, %{state | smoothed: nil, trace: nil, trace_dirty: true}}
  end

  def handle_data(_msg, state), do: {:noreply, state}

  @impl true
  def render(state) do
    GL.clear_color(0.04, 0.05, 0.08, 1.0)
    GL.clear(:color)

    GL.use_program(state.program)
    GL.uniform_1f(state.uniforms.db_min, state.db_min)
    GL.uniform_1f(state.uniforms.db_max, state.db_max)

    # Grid + center-frequency marker
    GL.uniform_4f(state.uniforms.color, 0.25, 0.28, 0.33, 1.0)
    GL.bind_vertex_array(state.grid_vao)
    GL.draw_arrays(:lines, 0, state.grid_count)

    # Frequency ticks: minors dim, majors brighter. Same dB-mapping shader
    # — the vertical extent uses the ±10000 dB trick the DC marker uses.
    state =
      if state.tick_dirty and is_binary(state.tick_bin) do
        GL.bind_vertex_array(state.tick_vao)
        GL.bind_buffer(:array, state.tick_vbo)
        GL.buffer_data(:array, state.tick_bin, :stream)
        %{state | tick_dirty: false}
      else
        state
      end

    if state.tick_minor_count + state.tick_major_count > 0 do
      GL.bind_vertex_array(state.tick_vao)
      GL.uniform_4f(state.uniforms.color, 0.34, 0.42, 0.56, 1.0)
      GL.draw_arrays(:lines, 0, state.tick_minor_count)
      GL.uniform_4f(state.uniforms.color, 0.62, 0.72, 0.92, 1.0)
      GL.draw_arrays(:lines, state.tick_minor_count, state.tick_major_count)
    end

    # Trace
    state =
      if state.trace_dirty and is_binary(state.trace) do
        GL.bind_vertex_array(state.trace_vao)
        GL.bind_buffer(:array, state.trace_vbo)
        GL.buffer_data(:array, state.trace, :stream)
        %{state | trace_dirty: false}
      else
        state
      end

    if is_binary(state.trace) do
      GL.uniform_4f(state.uniforms.color, 0.55, 0.95, 0.55, 1.0)
      GL.bind_vertex_array(state.trace_vao)
      GL.draw_arrays(:line_strip, 0, div(byte_size(state.trace), 8))
    end

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    GL.delete_program(state.program)
    GL.delete_vertex_array(state.trace_vao)
    GL.delete_buffer(state.trace_vbo)
    GL.delete_vertex_array(state.grid_vao)
    GL.delete_buffer(state.grid_vbo)
    GL.delete_vertex_array(state.tick_vao)
    GL.delete_buffer(state.tick_vbo)
    :ok
  end

  # --- geometry ----------------------------------------------------------------

  defp trace_vertices(dbs, n) do
    step = if n > 1, do: 2.0 / (n - 1), else: 0.0

    {bin, _} =
      Enum.reduce(dbs, {<<>>, 0}, fn db, {acc, i} ->
        x = -1.0 + step * i
        {acc <> <<x::float-32-native, db::float-32-native>>, i + 1}
      end)

    bin
  end

  defp tick_vertices(ticks) do
    for %{x: x} <- ticks, into: <<>> do
      xf = x * 1.0

      <<xf::float-32-native, -10_000.0::float-32-native, xf::float-32-native,
        10_000.0::float-32-native>>
    end
  end

  defp grid_vertices do
    # Horizontal dB lines every 10 dB across a wide span…
    horizontals =
      for db <- -140..0//10, into: <<>> do
        d = db * 1.0

        <<-1.0::float-32-native, d::float-32-native, 1.0::float-32-native, d::float-32-native>>
      end

    # …plus the DC / LO marker: a vertical line at x = 0 spanning any range.
    vertical =
      <<0.0::float-32-native, -10_000.0::float-32-native, 0.0::float-32-native,
        10_000.0::float-32-native>>

    horizontals <> vertical
  end

  # --- GL setup ----------------------------------------------------------------

  defp bind_pos_vbo(vao, vbo) do
    GL.bind_vertex_array(vao)
    GL.bind_buffer(:array, vbo)
    GL.vertex_attrib_pointer(0, 2, :float, false, 8, 0)
    GL.enable_vertex_attrib_array(0)
    GL.bind_vertex_array(0)
  end

  defp create_program do
    with {:ok, vs} <- GL.create_shader(:vertex, @vertex_shader),
         {:ok, fs} <- GL.create_shader(:fragment, @fragment_shader),
         {:ok, program} <- GL.create_program(vs, fs) do
      GL.delete_shader(vs)
      GL.delete_shader(fs)

      {:ok, program,
       %{
         db_min: GL.get_uniform_location(program, "u_db_min"),
         db_max: GL.get_uniform_location(program, "u_db_max"),
         color: GL.get_uniform_location(program, "u_color")
       }}
    end
  end
end
