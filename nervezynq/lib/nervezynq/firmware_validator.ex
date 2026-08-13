defmodule Nervezynq.FirmwareValidator do
  @moduledoc """
  Marks the running firmware as valid once it has proven itself.

  This is the userspace half of the A/B failover contract. `fwup.conf` arms
  the rollback by setting `upgrade_available=1` when it stages an upgrade;
  u-boot's `nerves_bootcount` then increments `bootcount` on every boot and
  runs `nerves_revert` once it passes `bootlimit`. Calling
  `Nerves.Runtime.validate_firmware/1` sets `nerves_fw_validated=1` and
  clears `upgrade_available`, which is what tells u-boot "this one stuck".

  If nothing ever calls this, *every* upgrade reverts -- including good ones.

  ## What counts as healthy

  Deliberately just "the BEAM stayed up for `validate_after_ms`". That catches
  the failure mode A/B actually protects against: firmware that boots into a
  crash loop. It intentionally does NOT wait for network, because a link that
  is legitimately down (an unplugged Ethernet cable) would then revert
  perfectly good firmware -- turning the safety net into the outage.

  Tighten this later by adding checks that are genuinely fatal if absent.
  """

  require Logger

  @default_validate_after_ms 30_000

  @doc """
  Child spec for the application supervisor.

  Temporary restart: if this task dies, it must not be restarted, or a crash
  here could validate firmware that never became healthy.
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {Task, :start_link, [fn -> run(opts) end]},
      restart: :temporary,
      type: :worker
    }
  end

  defp run(opts) do
    delay = Keyword.get(opts, :validate_after_ms, @default_validate_after_ms)
    Process.sleep(delay)

    case Nerves.Runtime.validate_firmware() do
      :ok ->
        Logger.info("[firmware] validated after #{delay}ms healthy uptime")

      other ->
        # Do not raise. A failure here means the next boot increments
        # bootcount and eventually reverts -- which is the correct,
        # conservative outcome.
        Logger.warning("[firmware] validation failed: #{inspect(other)}")
    end
  rescue
    e ->
      Logger.warning("[firmware] validation raised: #{inspect(e)}")
  end
end
