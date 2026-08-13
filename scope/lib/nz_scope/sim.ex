defmodule NzScope.Sim do
  @moduledoc """
  Protocol-identical fake board, for developing the GUI with no silicon on
  the bench. Speaks exactly what `Nervezynq.WFTap` speaks, from the hello
  down to honouring `{:retune, hz}` — the carrier moves when you retune, so
  the whole control loop is exercisable.

      iex> NzScope.Sim.start()
      iex> NzScope.Link.connect("127.0.0.1")

  Signal content per frame (1020 pairs, like a real snapshot):
  a noise floor, one strong carrier that tracks (sim_carrier_hz - freq),
  a weaker slowly-drifting second carrier, and a periodic wideband burst —
  enough texture to judge the waterfall with eyes only.
  """

  require Logger

  @port 7355
  @n 1020
  @interval_ms 50
  @fs 8_000_000
  # Where the simulated emitter lives in RF. open() defaults put the LO at
  # 2.412 GHz, so it starts 500 kHz right of center.
  @carrier_rf 2_412_500_000

  def start(port \\ @port) do
    case Process.whereis(__MODULE__) do
      nil ->
        pid = spawn(fn -> listen(port) end)
        Process.register(pid, __MODULE__)
        {:ok, pid}

      pid ->
        {:ok, pid}
    end
  end

  def stop do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> Process.exit(pid, :kill)
    end

    :ok
  end

  # --- guts --------------------------------------------------------------------

  defp listen(port) do
    {:ok, lsock} =
      :gen_tcp.listen(port, [:binary, packet: 4, active: false, reuseaddr: true, nodelay: true])

    Logger.info("Sim: fake board listening on #{port}")
    accept_loop(lsock)
  end

  defp accept_loop(lsock) do
    {:ok, sock} = :gen_tcp.accept(lsock)
    :inet.setopts(sock, active: true)

    st = %{
      sock: sock,
      seq: 0,
      fs: @fs,
      freq: 2_412_000_000,
      gain: 40,
      paused: false,
      phase1: 0.0,
      phase2: 0.0,
      drift: 0.0
    }

    send_term(sock, {:hello, %{fs: st.fs, freq: st.freq, gain: st.gain, n: @n, interval_ms: @interval_ms}})
    serve(st)
    accept_loop(lsock)
  end

  defp serve(st) do
    case drain(st) do
      :closed ->
        :ok

      st ->
        st =
          if st.paused do
            Process.sleep(50)
            st
          else
            {iq, st2} = frame(st)

            meta = %{seq: st2.seq, fs: st2.fs, freq: st2.freq, gain: st2.gain, n: @n}
            send_term(st2.sock, {:iq, meta, iq})
            Process.sleep(@interval_ms)
            %{st2 | seq: st2.seq + 1}
          end

        serve(st)
    end
  end

  defp drain(st) do
    receive do
      {:tcp, _s, bin} ->
        st =
          case safe_decode(bin) do
            {:retune, hz} ->
              send_term(st.sock, {:status, %{lo: hz, sim: true}})
              %{st | freq: hz}

            {:gain, db} ->
              send_term(st.sock, {:status, %{gain: db, sim: true}})
              %{st | gain: db}

            {:pause, flag} ->
              %{st | paused: flag}

            :status ->
              send_term(st.sock, {:status, %{sim: true, freq: st.freq, gain: st.gain}})
              st

            _ ->
              st
          end

        drain(st)

      {:tcp_closed, _s} ->
        :closed

      {:tcp_error, _s, _r} ->
        :closed
    after
      0 -> st
    end
  end

  # Synthetic IQ, s16le interleaved, 12-bit-ish scale to match the silicon.
  defp frame(st) do
    # Carrier offset from the current "LO" — retuning moves the line.
    f1 = @carrier_rf - st.freq
    f2 = f1 + 900_000 + trunc(st.drift)

    w1 = 2.0 * :math.pi() * f1 / st.fs
    w2 = 2.0 * :math.pi() * f2 / st.fs

    # Gain scales signal against a fixed noise floor, roughly like MGC would.
    a1 = 900.0 * :math.pow(10.0, (st.gain - 40) / 20.0)
    a2 = a1 * 0.12
    burst? = rem(st.seq, 40) < 3
    a3 = if burst?, do: 250.0, else: 0.0

    {iq, p1, p2} = gen_samples(@n, st.phase1, st.phase2, w1, w2, a1, a2, a3)

    st = %{
      st
      | phase1: :math.fmod(p1, 2.0 * :math.pi()),
        phase2: :math.fmod(p2, 2.0 * :math.pi()),
        drift: st.drift + 8_000.0 * (:rand.uniform() - 0.5)
    }

    {iq, st}
  end

  defp gen_samples(n, p1, p2, w1, w2, a1, a2, a3) do
    {list, p1, p2} =
      Enum.reduce(1..n, {[], p1, p2}, fn _, {acc, ph1, ph2} ->
        noise_i = (:rand.uniform() - 0.5) * 12.0
        noise_q = (:rand.uniform() - 0.5) * 12.0

        i = a1 * :math.cos(ph1) + a2 * :math.cos(ph2) + a3 * (:rand.uniform() - 0.5) + noise_i
        q = a1 * :math.sin(ph1) + a2 * :math.sin(ph2) + a3 * (:rand.uniform() - 0.5) + noise_q

        {[{clamp(i), clamp(q)} | acc], ph1 + w1, ph2 + w2}
      end)

    iq =
      for {i, q} <- Enum.reverse(list), into: <<>> do
        <<i::little-signed-16, q::little-signed-16>>
      end

    {iq, p1, p2}
  end

  defp clamp(x) do
    x = trunc(x)
    cond do
      x > 2047 -> 2047
      x < -2048 -> -2048
      true -> x
    end
  end

  defp send_term(sock, term), do: :gen_tcp.send(sock, :erlang.term_to_binary(term))

  defp safe_decode(bin) do
    :erlang.binary_to_term(bin, [:safe])
  rescue
    _ -> :error
  end
end
