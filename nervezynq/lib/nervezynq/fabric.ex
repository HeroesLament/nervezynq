defmodule Nervezynq.Fabric do
  @moduledoc """
  The PS→PL control plane: load the Zynq programmable logic and read and write
  it from Elixir.

  Owns one `oxibit port` (`Nervezynq.PortWire.open_pl/2`) for the life of the
  application. That process holds oxibit's lock, so it is the only thing on
  the board that can load the PL or touch its aperture, and this GenServer
  serialises access to it.

      iex> Nervezynq.Fabric.load("/data/hp_dma_s1.bin")
      {:ok, %{"loaded" => %{"config_sha256" => "b29a4a4a...", ...}, ...}}

      iex> Nervezynq.Fabric.read32(0x00)
      {:ok, 0x45484431}

      iex> Nervezynq.Fabric.status()
      {:ok, %{"ready" => true, "loaded" => %{...}, "hardware" => %{...}}}

  Offsets are relative to the base of the mapping, not absolute addresses. The
  register map lives in `Hw.AXI4Lite.Slave`.

  ## The guard is in the port, not here

  Reading the aperture with no configured slave behind it does not fault: the
  Zynq AXI interconnect has no timeout, so the CPU hangs outright, and the
  SWDT resets the board about 37 s later. This module used to guard against
  that with its own state (a sysfs check plus `invalidate/0` / `authorise/0`
  around `devcfg_load`). That state lived in a different process from the
  loader and could only ever be as right as the last thing that told it.

  `oxibit port` checks hardware before every access op instead: the DevC
  STATUS configuration levels (`PSS_FST_CFG_B`, `PSS_GTS_CFG_B`) and the PS-PL
  boundary (`LVL_SHFTR_EN`, `FPGA_RST_CTRL`). A refused access comes back as
  `{:error, {:pl_not_ready, why}}`, never as a bus cycle. Loading runs in the
  same process, so nothing can reconfigure the PL between the check and the
  access. Details: oxibit `docs/zynq7.md`.

  One hazard the port cannot see on its own: a design with **no slave** on the
  aperture (EMIO/DDR-only designs such as hp_loop) hangs the CPU on access just
  like a blank PL. Load those with `load(path, aperture: false)`; the port then
  refuses aperture access until the next load.

  ## Why a port and not a NIF

  In a NIF, an AXI access that decodes but errors arrives as an imprecise abort:
  `SIGBUS`, on a scheduler thread, taking the whole VM with it. As a port it is
  one OS process; the VM sees `{:exit_status, n}`, this GenServer stops, the
  supervisor restarts it, and the device stays reachable to receive the fix.

  After every boot, watchdog resets included, the PL is blank: nothing loads it
  at boot (see `nerves_system_libresdr/docs/boot-chain.md`). Mapping the
  aperture issues no bus traffic, so the port starts at boot and simply refuses
  access until a load.
  """

  use GenServer
  require Logger

  alias Nervezynq.PortWire

  # Zynq-7000 M_AXI_GP0.
  @default_base 0x4000_0000
  @default_len 0x20000

  # Generous for what is a sub-microsecond bus access. If this ever fires,
  # something is wrong with the port process, not with the timeout.
  @call_timeout 5_000
  # A load is about 180 ms on the LibreSDR; the rest is headroom for reading a
  # large file from flash.
  @load_timeout 30_000

  # Offsets from Hw.AXI4Lite.Slave's register map. The slave carries four
  # control and four status registers, not one of each — a single 32-bit
  # control word runs out as soon as a design carries an SPI byte, a
  # chip-select hold bit, a go toggle and a handful of radio pin controls.
  @registers [
    magic: 0x00,
    version: 0x04,
    scratch: 0x08,
    ctrl0: 0x0C,
    ctrl1: 0x10,
    ctrl2: 0x14,
    ctrl3: 0x18,
    status0: 0x1C,
    status1: 0x20,
    status2: 0x24,
    status3: 0x28
  ]

  @type offset :: non_neg_integer()
  @type reason ::
          {:pl_not_ready, String.t()} | :timeout | {:port_exited, integer()} | map() | String.t()

  # --- API -------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc """
  Load a bitstream into the PL: `.bit`, raw or byte-swapped `.bin`, gzipped,
  or a `BOOT.BIN` (its PL partition). The file is checked (structure, CRC,
  IDCODE against this device) before anything is touched.

  Options:

    * `aperture: false` - the design has no slave on the aperture; aperture
      access is refused until the next load.
    * `hash: false` - skip the configuration SHA-256 (every check still runs;
      the marker records no hash). It is most of a load's CPU time on this
      part, so a caller that already knows what it loads can skip it.

  Returns oxibit's load report, or `{:error, %{"error" => kind, ...}}`. A
  failed load after the erase leaves the PL blank and access refused; recover
  by loading a known-good bitstream.
  """
  @spec load(Path.t(), keyword()) :: {:ok, map()} | {:error, reason()}
  def load(path, opts \\ []) do
    request = {:load, path, Keyword.get(opts, :aperture, true), Keyword.get(opts, :hash, true)}
    GenServer.call(__MODULE__, request, @load_timeout)
  end

  @doc "Erase the PL and close the PS-PL boundary."
  @spec clear() :: {:ok, map()} | {:error, reason()}
  def clear(), do: GenServer.call(__MODULE__, :clear, @call_timeout)

  @doc """
  What the hardware says now: `"ready"`, the configuration and boundary
  registers, FCLKs, and what oxibit loaded (`"loaded"`, with its config hash).
  Reads PS-side registers only.
  """
  @spec status() :: {:ok, map()} | {:error, reason()}
  def status(), do: GenServer.call(__MODULE__, :status, @call_timeout)

  @doc "Whether aperture access is allowed right now."
  @spec ready?() :: boolean()
  def ready?() do
    match?({:ok, %{"ready" => true}}, status())
  end

  @doc "Read one 32-bit word at `offset` bytes into the aperture."
  @spec read32(offset()) :: {:ok, 0..0xFFFFFFFF} | {:error, reason()}
  def read32(offset), do: GenServer.call(__MODULE__, {:read32, offset}, @call_timeout)

  @doc "Write one 32-bit word at `offset` bytes into the aperture."
  @spec write32(offset(), 0..0xFFFFFFFF) :: :ok | {:error, reason()}
  def write32(offset, value), do: GenServer.call(__MODULE__, {:write32, offset, value}, @call_timeout)

  @doc "Read `count` consecutive words starting at `offset`."
  @spec read_block(offset(), pos_integer()) :: {:ok, [0..0xFFFFFFFF]} | {:error, reason()}
  def read_block(offset, count), do: GenServer.call(__MODULE__, {:read_block, offset, count}, @call_timeout)

  @doc """
  Read the SAME word `count` times.

  For a register in front of an auto-advancing buffer -- the capture memory,
  whose read pointer steps on every STATUS3 access -- each read of one address
  returns the NEXT word. `read_block/2` walks addresses and is wrong for that;
  this walks time.

  The point is the round trip, not the bus. A read costs ~1.06 us of bus time
  and ~215 us as its own userspace call, so pulling a whole capture buffer in
  one call is roughly 200x faster than reading it word by word.
  """
  @spec read_repeat(offset(), pos_integer()) :: {:ok, [0..0xFFFFFFFF]} | {:error, reason()}
  def read_repeat(offset, count), do: GenServer.call(__MODULE__, {:read_repeat, offset, count}, @call_timeout)

  @doc "Write `values` to consecutive words starting at `offset`."
  @spec write_block(offset(), [0..0xFFFFFFFF]) :: :ok | {:error, reason()}
  def write_block(offset, values), do: GenServer.call(__MODULE__, {:write_block, offset, values}, @call_timeout)

  @doc """
  Run a register program in one port round trip: a list of `{:r, offset}`
  and `{:w, offset, value}`, executed in order. Returns the reads, in order.
  Stops at the first failing access.
  """
  @spec exec([{:r, offset()} | {:w, offset(), 0..0xFFFFFFFF}]) :: {:ok, [0..0xFFFFFFFF]} | {:error, reason()}
  def exec(ops), do: GenServer.call(__MODULE__, {:exec, ops}, @call_timeout)

  @doc "The physical base and length of the mapping, as reported by the port."
  @spec info() :: {:ok, %{base: non_neg_integer(), length: non_neg_integer()}} | {:error, reason()}
  def info(), do: GenServer.call(__MODULE__, :info, @call_timeout)

  @doc false
  @deprecated "The guard is in oxibit port now; nothing needs invalidating."
  def invalidate(), do: :ok

  @doc false
  @deprecated "The guard is in oxibit port now; access is allowed when hardware says so."
  def authorise(), do: :ok

  @doc """
  Read the whole register map in one round trip.

  On the LibreSDR radio design the status words decode as:

    * `status0` — SPI: `[7:0]` last byte in, `[8]` done toggle, `[9]` tx_ready
    * `status1` — `[23:0]` fabric heartbeat on the AXI clock
    * `status2` — `[23:0]` DATA_CLK/512 edge count. Zero means the AD9363 is
      not driving its data port yet, which is its state out of reset
    * `status3` — the capture buffer read port: `[11:0]` `sample_a` (rising
      edge), `[23:12]` `sample_b` (falling edge), `[25:24]` the RX_FRAME pair,
      `[26]` capture-done. Each half is a complete 12-bit sample assembled as
      `{current 6 bits, previous 6 bits}` from one DDR edge — see
      `Nervezynq.SampleFormat`

  Two reads returning different heartbeats prove the fabric clock is running;
  two returning different `status2` values prove the transceiver's clock is.
  Those are separate clocks with separate failure modes, and from userspace a
  dead one looks exactly like a broken bus.
  """
  @spec dump() :: {:ok, map()} | {:error, reason()}
  def dump() do
    with {:ok, words} <- read_block(0x00, length(@registers)) do
      {:ok, @registers |> Enum.map(&elem(&1, 0)) |> Enum.zip(words) |> Map.new()}
    end
  end

  @doc "The register map this driver knows about, as `{name, offset}` pairs."
  def registers(), do: @registers

  # --- GenServer -------------------------------------------------------------

  @impl true
  def init(opts) do
    base = opts[:base] || @default_base
    len = opts[:length] || @default_len

    {:ok, port} = PortWire.open_pl(base, len)
    Logger.info("Fabric: oxibit port on #{inspect(base, base: :hex)}+#{len}")

    {:ok, %{port: port, base: base, length: len}}
  end

  @impl true
  def handle_call({:load, path, _aperture?, _hash?} = request, _from, state) do
    reply = PortWire.transact(state.port, request, @load_timeout)

    case reply do
      {:ok, %{"loaded" => m}} -> Logger.info("[pl] loaded #{m["source"]} (#{m["config_sha256"]}, #{m["load_ms"]} ms)")
      {:error, e} -> Logger.error("[pl] load of #{path} FAILED: #{inspect(e)}")
    end

    {:reply, reply, state}
  end

  def handle_call(request, _from, state) do
    {:reply, PortWire.transact(state.port, request, @call_timeout), state}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    # Let the supervisor restart us with a fresh port. Crashing here rather
    # than reopening in place keeps the "port died" signal visible. Exit 75
    # means another process holds oxibit's lock (an `oxibit` CLI command run
    # from a shell, say); the restart takes the lock once it is released.
    {:stop, {:port_exited, status}, state}
  end

  def handle_info(_message, state), do: {:noreply, state}
end
