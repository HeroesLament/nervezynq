defmodule Nervezynq.PL do
  @moduledoc """
  Reconfigure the programmable logic at runtime.

  A thin layer over `Nervezynq.Fabric.load/2`, which sends the load to the
  application's `oxibit port`. oxibit does the work and owns the safety:

  - the file is parsed and checked (structure, CRC, IDCODE against this
    device) before anything is touched, so a bad file changes nothing;
  - the PL is erased, the bitstream staged in the `no-map` PCAP buffer, read
    back, and configured; any failure after the erase leaves the PL blank and
    aperture access refused, never allowed;
  - access is allowed again only when hardware reports the PL configured and
    the PS-PL boundary open.

  `PROG_B` erases the running design before the replacement arrives, so a load
  is not an atomic swap and a failure is not a no-op. Recover from a failed
  load by loading a known-good bitstream, not by rebooting: nothing loads the
  PL at boot, so a reboot only returns to a blank PL. No `.bit` belongs on the
  boot partition (U-Boot would program it and could hang the boot).

  Designs with no slave on the aperture (hp_loop) must be loaded with
  `aperture: false`, or the first `Fabric` access hangs the CPU.
  """

  alias Nervezynq.Fabric

  @doc """
  Load `path` into the PL. Accepts `.bit`, raw or byte-swapped `.bin`, gzipped
  files and `BOOT.BIN`; see `Nervezynq.Fabric.load/2` for options.

  Returns `{:ok, %{ms: n, report: oxibit_report}}` or `{:error, reason}`, where
  a rejected or failed load is `{:error, %{"error" => kind, ...}}` with kind
  `"rejected"` or `"wrong_device"` (nothing touched) or `"program"` (PL blank).
  """
  @spec reload(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def reload(path, opts \\ []) do
    with {:ok, report} <- Fabric.load(path, opts) do
      {:ok, %{ms: report["program"]["ms"], report: report}}
    end
  end

  @doc """
  Reload and then prove the fabric answers, in one step.

  Reads the magic word and two heartbeat samples. A correct magic says the right
  bitstream is loaded and the AXI slave is decoding; two differing heartbeats say
  the fabric clock is actually running. Those are separate claims with separate
  failure modes, and a design can satisfy the first while failing the second.

  The reads are safe because `oxibit port` refuses them unless the load left
  the PL configured and the boundary open.
  """
  @spec reload_and_verify(Path.t()) :: {:ok, map()} | {:error, term()}
  def reload_and_verify(bin_path) do
    with {:ok, info} <- reload(bin_path),
         # 0x00 is the fixed ID word, deliberately outside the register map:
         # it must be readable before any map is trusted.
         {:ok, magic} <- Fabric.read32(0x00) do
      hb1 = Nervezynq.Regs.heartbeat()
      Process.sleep(50)
      hb2 = Nervezynq.Regs.heartbeat()

      {:ok,
       Map.merge(info, %{
         magic: magic,
         magic_ok: magic == 0x4548_4431,
         heartbeat_running: hb2 != hb1
       })}
    end
  end
end
