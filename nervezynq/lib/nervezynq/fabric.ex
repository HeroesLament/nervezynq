defmodule Nervezynq.Fabric do
  @moduledoc """
  The PS→PL control plane: read and write the Zynq programmable logic from
  Elixir.

  Wraps `fabric_port`, a small Rust program that mmaps the PL aperture and
  speaks a length-prefixed binary protocol over stdio. This GenServer owns that
  port, serialises access to it, and refuses to touch the bus until the fabric
  is actually configured.

      iex> Nervezynq.Fabric.read32(0x00)
      {:ok, 0x45484431}

      iex> Nervezynq.Fabric.write32(0x08, 0xDEADBEEF)
      :ok

      iex> Nervezynq.Fabric.dump()
      %{magic: 0x45484431, version: 0x00010000, scratch: 0xDEADBEEF, ...}

  Offsets are relative to the base of the mapping, not absolute addresses. The
  register map lives in `Hw.AXI4Lite.Slave`.

  ## Why a port and not a NIF

  `/dev/mem` cannot be read with `pread` here: ARM's `valid_phys_addr_range()`
  restricts the read/write path to physical RAM, so a `pread` at `0x4000_0000`
  returns `EFAULT`. `mmap` has no such restriction, and mmap needs native code —
  so *something* outside the BEAM has to exist. The choice is where it runs.

  In a NIF it runs on a scheduler thread, and an AXI access that decodes but
  errors arrives as an imprecise abort: `SIGBUS`, on that thread, taking the
  whole VM with it. No supervisor, no ssh, no OTA — a field device that needs
  physically visiting. As a port it is one OS process; the VM sees
  `{:exit_status, n}`, this GenServer stops, the supervisor restarts it, and the
  device stays reachable to receive the fix.

  ## What the guard does and does not cover

  Every call checks that `/sys/class/fpga_manager/fpga0/state` reads
  `operating`, because reading an aperture with no bitstream loaded does not
  fault — the Zynq AXI interconnect has no timeout, so the CPU hangs outright,
  with no oops and no recovery short of a power cycle. That failure is beyond
  the reach of a process boundary; no port, NIF or language prevents it. Only
  not issuing the access prevents it, which is what this guard is for.

  The state is cached once it reads `operating`, since nothing short of an
  explicit reconfiguration can move it back. Anything that gains the ability to
  reload a bitstream at runtime must invalidate that cache.

  `Nervezynq.PL` is that thing, and the first time it ran and failed it hung the
  board exactly as described above. So the guard is now two-part: the sysfs check
  still covers the bitstream u-boot loaded at boot, but `invalidate/0` sets a
  sticky block that no amount of re-reading sysfs will clear. Only `authorise/0`
  clears it, and only hardware-confirmed `PCFG_DONE` justifies calling that.

  Note that the mapping itself is safe to establish early: `mmap` populates page
  tables and issues no bus traffic, so the port can be started before the PL is
  configured. Only the accesses need gating.
  """

  use GenServer
  require Logger

  # Zynq-7000 M_AXI_GP0. One 4 KB page is the minimum the PS decodes, and the
  # bring-up register map needs five words of it.
  @default_base 0x4000_0000
  @default_len 0x20000

  @fpga_state_path "/sys/class/fpga_manager/fpga0/state"

  # Generous for what is a sub-microsecond bus access. If this ever fires,
  # something is wrong with the port process, not with the timeout.
  @call_timeout 5_000

  @op_read32 0x01
  @op_write32 0x02
  @op_read_block 0x03
  @op_write_block 0x04
  @op_info 0x05
  @op_read_repeat 0x06

  @resp_ok 0x00
  @resp_err 0x01

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
  @type reason :: :fpga_not_configured | :timeout | {:port_exited, integer()} | String.t()

  # --- API -------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
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

  @doc "The physical base and length of the mapping, as reported by the port."
  @spec info() :: {:ok, %{base: non_neg_integer(), length: non_neg_integer()}} | {:error, reason()}
  def info(), do: GenServer.call(__MODULE__, :info, @call_timeout)

  @doc "Whether the fabric is configured and accesses are permitted."
  @spec ready?() :: boolean()
  def ready?(), do: GenServer.call(__MODULE__, :ready?, @call_timeout)

  @doc """
  Block all bus access until something positively re-authorises it.

  Call this **before** reconfiguring the PL. The sysfs check this module
  otherwise relies on cannot see a userspace reconfiguration: it reports the
  kernel FPGA manager driver's last operation, so it keeps reading `operating`
  while the PL is blank. That is not a theoretical gap — `devcfg_load` pulses
  `PROG_B`, which erases the running design before the first byte of the
  replacement is sent, so a load that fails anywhere after that point leaves the
  PL configured with nothing at all. The next read into the aperture then hangs
  the CPU with no oops and no recovery short of a power cycle.

  Once invalidated, the state is **not** recoverable by re-reading sysfs. Only
  `authorise/0` clears it, and the only thing entitled to call that is code
  holding hardware's own confirmation that configuration completed.
  """
  @spec invalidate() :: :ok
  def invalidate(), do: GenServer.call(__MODULE__, :invalidate, @call_timeout)

  @doc """
  Re-authorise bus access after a reconfiguration that is known to have
  succeeded.

  "Known" means `PCFG_DONE` was observed in the DevC interrupt status — which is
  hardware's own report and the only trustworthy answer. In practice that means
  `devcfg_load` exited 0. Do not call this on the strength of anything weaker:
  not the sysfs state, not the absence of an error message, and not the fact
  that a read happened to return a plausible-looking value.
  """
  @spec authorise() :: :ok
  def authorise(), do: GenServer.call(__MODULE__, :authorise, @call_timeout)

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

    # Opened through Nervezynq.PortWire so the framing options live in exactly
    # one place. They were duplicated once, a second mapping was opened without
    # {:packet, 4}, and every call on it timed out while this one kept working.
    {:ok, port} = Nervezynq.PortWire.open(base, len)

    Logger.info("Fabric: mapped #{inspect(base, base: :hex)}+#{len}")

    {:ok, %{port: port, base: base, length: len, configured?: false}}
  end

  @impl true
  def handle_call(:ready?, _from, state) do
    {ready?, state} = ensure_configured(state)
    {:reply, ready?, state}
  end

  def handle_call(:invalidate, _from, state) do
    {:reply, :ok, state |> Map.put(:configured?, false) |> Map.put(:blocked?, true)}
  end

  def handle_call(:authorise, _from, state) do
    {:reply, :ok, state |> Map.put(:configured?, true) |> Map.put(:blocked?, false)}
  end

  def handle_call(request, _from, state) do
    case gate(request, state) do
      {{:error, _} = error, state} ->
        {:reply, error, state}

      {:ok, state} ->
        {:reply, transact(state.port, request), state}
    end
  end

  # INFO does not touch the bus — it reports what the port mapped — so it is
  # allowed through before the fabric is configured. Everything else waits.
  defp gate(:info, state), do: {:ok, state}

  defp gate(_request, state) do
    # `blocked?` is read with a default so this module can be hot-loaded into a
    # running GenServer whose state map predates the field.
    if Map.get(state, :blocked?, false) do
      {{:error, :pl_unconfigured}, state}
    else
      case ensure_configured(state) do
        {true, state} -> {:ok, state}
        {false, state} -> {{:error, :fpga_not_configured}, state}
      end
    end
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    # Let the supervisor restart us with a fresh mapping. Crashing here rather
    # than reopening in place keeps the "port died" signal visible.
    {:stop, {:port_exited, status}, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # --- guard -----------------------------------------------------------------

  defp ensure_configured(%{configured?: true} = state), do: {true, state}

  defp ensure_configured(state) do
    case File.read(@fpga_state_path) do
      {:ok, contents} ->
        if String.trim(contents) == "operating" do
          {true, %{state | configured?: true}}
        else
          {false, state}
        end

      {:error, _} ->
        {false, state}
    end
  end

  # --- wire format -----------------------------------------------------------
  #
  # Moved to Nervezynq.PortWire so the SLCR, devcfg and the readback DMA buffer
  # can share one encoder instead of each carrying a copy that can drift.

  defp transact(port, request), do: Nervezynq.PortWire.transact(port, request, @call_timeout)
end
