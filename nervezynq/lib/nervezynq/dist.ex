defmodule Nervezynq.Dist do
  @moduledoc """
  Erlang distribution on one configured interface (the USB gadget link by
  default, eth0 on the bench farm), so a controller node on the host can drive
  the board with `:erpc` instead of ssh eval.

  ## Shape

  The board is one leaf of a star. The host runs a *hidden* node and opens
  every connection, so the boards never learn about each other (each sits on
  its own point-to-point /30 and could not reach the others anyway) and never
  need a route back to the host.

  ## Exposure

  Distribution is remote code execution for anyone holding the cookie, so:

    * epmd and the dist listener bind the configured interface's address only
      (plus loopback for epmd), never the wildcard. Default `usb0`; the farm
      config sets `eth0`, which puts the listener on the bench LAN;
    * the dist port is fixed (`9100` by default) so it is predictable;
    * the cookie is read from `/data/dist_cookie`, provisioned once from the
      host, and never logged. With no cookie file the node is NOT started:
      fail closed rather than come up on the release's compiled-in cookie.

  ## Lifecycle

  Waits for the interface to have an IPv4 address (stable per board: usb0
  from the gadget MAC, eth0 from a DHCP reservation), then starts epmd and
  `net_kernel`. Started once; `net_kernel` lives under `kernel_sup`, so this
  process restarting does not take the node down. If the address ever
  changes the node is restarted on the new one.

  Configure with `config :nervezynq, Nervezynq.Dist, interface: ..., port:
  ..., cookie_path: ..., name: ...`; `enabled: false` turns it off.
  """

  use GenServer
  require Logger

  @defaults [
    enabled: true,
    interface: "usb0",
    port: 9100,
    cookie_path: "/data/dist_cookie",
    name: "nerves"
  ]

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Current state: `%{ip: ..., node: ...}` (no cookie)."
  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(opts) do
    cfg = @defaults |> Keyword.merge(Application.get_env(:nervezynq, __MODULE__, [])) |> Keyword.merge(opts)

    if cfg[:enabled] do
      key = ["interface", cfg[:interface], "addresses"]
      VintageNet.subscribe(key)
      state = %{cfg: cfg, ip: nil}
      {:ok, maybe_start(state, VintageNet.get(key))}
    else
      :ignore
    end
  end

  @impl true
  def handle_info({VintageNet, ["interface", _, "addresses"], _old, addresses, _meta}, state) do
    {:noreply, maybe_start(state, addresses)}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, %{ip: state.ip && to_string(:inet.ntoa(state.ip)), node: Node.self(), alive: Node.alive?()}, state}
  end

  # -- start / restart ---------------------------------------------------------

  defp maybe_start(state, addresses) do
    case ipv4(addresses) do
      nil ->
        state

      ip when ip == state.ip and state.ip != nil ->
        state

      ip ->
        start_node(state, ip)
    end
  end

  defp ipv4(addresses) when is_list(addresses) do
    Enum.find_value(addresses, fn
      %{family: :inet, address: ip} -> ip
      _ -> nil
    end)
  end

  defp ipv4(_), do: nil

  defp start_node(state, ip) do
    cfg = state.cfg
    ip_str = to_string(:inet.ntoa(ip))

    case read_cookie(cfg[:cookie_path]) do
      {:ok, cookie} ->
        # An address change means the old listener is bound to a dead address.
        if Node.alive?(), do: Node.stop()

        start_epmd(ip_str)
        Application.put_env(:kernel, :inet_dist_use_interface, ip)
        Application.put_env(:kernel, :inet_dist_listen_min, cfg[:port])
        Application.put_env(:kernel, :inet_dist_listen_max, cfg[:port])

        name = String.to_atom("#{cfg[:name]}@#{ip_str}")

        case Node.start(name, name_domain: :longnames) do
          {:ok, _} ->
            Node.set_cookie(cookie)
            Logger.info("[dist] #{name} listening on #{ip_str}:#{cfg[:port]}")
            %{state | ip: ip}

          {:error, reason} ->
            Logger.warning("[dist] Node.start(#{name}) failed: #{inspect(reason)}")
            state
        end

      {:error, why} ->
        Logger.warning("[dist] not starting: #{why}")
        state
    end
  end

  # Cookie value never leaves this function except into Node.set_cookie/1.
  defp read_cookie(path) do
    case File.read(path) do
      {:ok, raw} ->
        case String.trim(raw) do
          "" -> {:error, "#{path} is empty"}
          c -> {:ok, String.to_atom(c)}
        end

      {:error, :enoent} ->
        {:error, "no cookie at #{path} (provision it from the host)"}

      {:error, reason} ->
        {:error, "cannot read #{path}: #{inspect(reason)}"}
    end
  end

  # epmd ships inside erts; there is none on PATH.  `-daemon` is a no-op if one
  # is already running (it then keeps its original bind addresses).
  defp start_epmd(ip_str) do
    case Path.wildcard(Path.join(:code.root_dir(), "erts-*/bin/epmd")) do
      [epmd | _] ->
        System.cmd(epmd, ["-daemon"], env: [{"ERL_EPMD_ADDRESS", ip_str <> ",127.0.0.1"}])

      [] ->
        Logger.warning("[dist] epmd not found under #{:code.root_dir()}")
    end
  end
end
