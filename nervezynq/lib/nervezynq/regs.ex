defmodule Nervezynq.Regs do
  @moduledoc """
  Typed accessors for the LibreSDR fabric register map.

  Generated at compile time from the SAME spec the fabric is built from
  (`ehdl/designs/libresdr_radio/regmap.exs`), so a bit offset cannot disagree
  between hardware and driver. Recompiles automatically when the spec changes.

  Replaces call-site constants like `Fabric.write32(0x14, bor(arm, addr))` and
  `AD9363.writef(0x010, 0x08, 1)` with `Regs.put_cap_rd_addr/1` and
  `Regs.pulse_cap_arm/0`.
  """
  use Nervezynq.RegMap,
    spec: "../../../../ehdlslop/designs/libresdr_radio/regmap.exs",
    ctrl_base: 0x0C,
    status_base: 0x1C
end
