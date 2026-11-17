defmodule Nervezynq.MacAddr do
  @moduledoc """
  Stable per-board MAC for eth0.

  The Zynq GEM has no burned-in address and the U-Boot env carries no
  `ethaddr`, so the kernel assigns a random MAC every boot
  (`addr_assign_type` 1) and DHCP hands out a new lease each time.

  Same scheme as `usb-gadget-init`: djb2 over `nerves_serial_number`, masked
  to 24 bits, low 16 bits into a locally administered unicast address
  `02:1a:35:HH:LL:24` (`:22`/`:23` are the usb0 gadget pair). Returns `nil`
  with no serial, which leaves the kernel's random address in place.

  Wired up as `mac_address: {Nervezynq.MacAddr, :eth0, []}` in the
  VintageNetEthernet config.
  """

  import Bitwise

  @doc "MAC string for eth0, or nil when the board has no serial provisioned."
  @spec eth0() :: String.t() | nil
  def eth0 do
    case serial() do
      nil -> nil
      serial -> mac(serial, 0x24)
    end
  end

  @doc false
  def mac(serial, tail) do
    h = djb2(serial)
    :io_lib.format("02:1a:35:~2.16.0b:~2.16.0b:~2.16.0b", [(h >>> 8) &&& 0xFF, h &&& 0xFF, tail])
    |> IO.iodata_to_binary()
    |> String.downcase()
  end

  # Matches the shell loop in usb-gadget-init byte for byte.
  defp djb2(serial) do
    for <<c <- serial>>, reduce: 5381 do
      h -> (h * 33 + c) &&& 0xFFFFFF
    end
  end

  defp serial do
    case Nerves.Runtime.KV.get("nerves_serial_number") do
      s when is_binary(s) and s != "" -> s
      _ -> nil
    end
  end
end
