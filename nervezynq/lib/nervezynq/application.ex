defmodule Nervezynq.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        # Children for all targets
        # Starts a worker by calling: Nervezynq.Worker.start_link(arg)
        # {Nervezynq.Worker, arg},
      ] ++ target_children()

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Nervezynq.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # List all child processes to be supervised
  if Mix.target() == :host do
    defp target_children() do
      [
        # Children that only run on the host during development or test.
        # In general, prefer using `config/host.exs` for differences.
        #
        # Starts a worker by calling: Host.Worker.start_link(arg)
        # {Host.Worker, arg},
      ]
    end
  else
    defp target_children() do
      [
        # Children for all targets except host
        # Starts a worker by calling: Target.Worker.start_link(arg)
        # {Target.Worker, arg},

        # Completes the A/B failover contract: fwup arms the rollback with
        # upgrade_available=1, this clears it once the firmware proves
        # healthy. Without it, every OTA reverts after bootlimit.
        {Nervezynq.FirmwareValidator, []},

        # Erlang distribution on the USB gadget link, for the host-side
        # campaign controller (hidden node, :erpc). Fails closed without
        # /data/dist_cookie.
        {Nervezynq.Dist, []}
      ] ++ fabric_children()
    end
  end

  # The PL control plane only exists on the LibreSDR. Every other target in
  # this project has no programmable logic to talk to, and `oxibit port` would
  # fail to map the Zynq registers on any of them.
  if Mix.target() == :libresdr do
    # Autostart after the fabric: /data/autostart.exs brings a board up with
    # no controller (bitstream, radio, applications). See Nervezynq.Autostart.
    defp fabric_children(), do: [{Nervezynq.Fabric, []}, {Nervezynq.Autostart, []}]
  else
    defp fabric_children(), do: []
  end
end
