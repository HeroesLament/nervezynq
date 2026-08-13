defmodule Nervezynq.RegMap do
  @moduledoc """
  Compile a fabric register map into typed accessors.

      defmodule Nervezynq.Regs do
        use Nervezynq.RegMap,
          spec: "../../ehdl/designs/libresdr_radio/regmap.exs",
          ctrl_base: 0x08,
          status_base: 0x18
      end

  Generates, from the same spec the fabric is built from:

      Regs.spi_tx_data()          # read a :rw field  (from shadow)
      Regs.put_spi_tx_data(0x37)  # write a :rw field (shadow + one write32)
      Regs.cap_done()             # read a :ro field  (from status word)
      Regs.pulse_cap_arm()        # flip a :wtoggle bit -> one-shot command
      Regs.dump()                 # every field, for a human

  ## Why a shadow

  A `ctrl*` word is write-only from the fabric's side, so setting one field
  means read-modify-write. Reading back over the AXI bus is slow and, on a
  write-only register, meaningless. So RW state is mirrored in an Agent and
  writes are computed locally -- the same choice Maia SDR makes in software.
  `sync/0` re-reads the status words; `reset_shadow/0` zeroes the mirror.

  The point of all this is that **no offset appears in driver code**. Every
  `0x14` and `&&& 0xFFF` that used to sit at a call site is now derived from
  the spec the fabric was generated from, so the two cannot disagree.
  """

  # Needed in the MACRO body (mask arithmetic below), not just in the caller.
  # Imports are lexical: at the bottom of the module it is not in scope here.
  import Bitwise

  defmacro __using__(opts) do
    spec_path = Keyword.fetch!(opts, :spec)
    ctrl_base = Keyword.get(opts, :ctrl_base, 0x0C)
    status_base = Keyword.get(opts, :status_base, 0x1C)

    path = Path.expand(spec_path, Path.dirname(__CALLER__.file))
    {spec, _} = Code.eval_file(path)

    fields = expand(spec)

    ctrl_regs =
      fields |> Enum.filter(&(elem(&1, 4) != :ro)) |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    accessors =
      for {name, reg, hi, lo, access, width} <- fields do
        mask = (1 <<< width) - 1
        addr = reg_addr(reg, ctrl_base, status_base)

        case access do
          :ro ->
            quote do
              @doc "Read `#{unquote(name)}` from `#{unquote(reg)}` [#{unquote(hi)}:#{unquote(lo)}]."
              def unquote(name)() do
                {:ok, v} = Nervezynq.Fabric.read32(unquote(addr))
                v >>> unquote(lo) &&& unquote(mask)
              end
            end

          :rw ->
            put = String.to_atom("put_#{name}")

            quote do
              @doc "Read `#{unquote(name)}` from the shadow copy of `#{unquote(reg)}`."
              def unquote(name)() do
                shadow(unquote(reg)) >>> unquote(lo) &&& unquote(mask)
              end

              @doc "Set `#{unquote(name)}` (shadow + one 32-bit write)."
              def unquote(put)(value) when is_integer(value) do
                if value > unquote(mask) do
                  raise ArgumentError,
                        "#{unquote(name)}: #{value} does not fit in #{unquote(width)} bits"
                end

                word =
                  (shadow(unquote(reg)) &&& bnot(unquote(mask) <<< unquote(lo))) |||
                    value <<< unquote(lo)

                put_shadow(unquote(reg), word)
                Nervezynq.Fabric.write32(unquote(addr), word)
              end
            end

          :wtoggle ->
            pulse = String.to_atom("pulse_#{name}")

            quote do
              @doc "Flip `#{unquote(name)}`; the fabric edge-detects it as a one-shot."
              def unquote(pulse)() do
                cur = shadow(unquote(reg)) >>> unquote(lo) &&& 1
                word =
                  (shadow(unquote(reg)) &&& bnot(1 <<< unquote(lo))) |||
                    bxor(cur, 1) <<< unquote(lo)

                put_shadow(unquote(reg), word)
                Nervezynq.Fabric.write32(unquote(addr), word)
              end

              @doc "Current value of the `#{unquote(name)}` toggle bit."
              def unquote(name)() do
                shadow(unquote(reg)) >>> unquote(lo) &&& 1
              end
            end
        end
      end

    readable = for {n, _, _, _, a, _} <- fields, a != :wtoggle, do: n

    quote do
      import Bitwise
      @spec_path unquote(path)
      @external_resource unquote(path)
      @ctrl_regs unquote(ctrl_regs)

      def __spec_path__, do: @spec_path
      def __fields__, do: unquote(Macro.escape(fields))

      # --- shadow state for write-only control words ---
      defp agent do
        case Process.whereis(__MODULE__.Shadow) do
          nil ->
            {:ok, pid} = Agent.start_link(fn -> %{} end, name: __MODULE__.Shadow)
            pid

          pid ->
            pid
        end
      end

      defp shadow(reg), do: Agent.get(agent(), &Map.get(&1, reg, 0))
      defp put_shadow(reg, v), do: Agent.update(agent(), &Map.put(&1, reg, v))

      @doc "Zero the shadow copy of every control word (does not touch the fabric)."
      def reset_shadow, do: Agent.update(agent(), fn _ -> %{} end)

      @doc """
      Re-read every control word from the fabric into the shadow.

      The AXI slave stores control words in real registers, so they read back.
      Call this before the first read-modify-write in a session (or after a
      bitstream reload) so the shadow starts from what the fabric actually
      holds rather than from zero -- otherwise the first `put_*` clobbers
      every other field in that word.
      """
      def sync_shadow do
        Enum.each(@ctrl_regs, fn reg ->
          case Nervezynq.Fabric.read32(unquote(ctrl_base) + reg_index(reg) * 4) do
            {:ok, v} -> put_shadow(reg, v)
            _ -> :ok
          end
        end)
      end

      @doc "Push the shadow copy of every control word back to the fabric."
      def flush do
        Enum.each(@ctrl_regs, fn reg ->
          Nervezynq.Fabric.write32(unquote(ctrl_base) + reg_index(reg) * 4, shadow(reg))
        end)
      end

      defp reg_index(reg) do
        reg |> Atom.to_string() |> String.replace(~r/\D/, "") |> String.to_integer()
      end

      unquote_splicing(accessors)

      @doc """
      Set several fields of one control word in a SINGLE 32-bit write.

          Regs.put(ctrl0: [spi_tx_data: byte, spi_cs_hold: 1], toggle: [:spi_go])

      `put_*/1` is one bus write per field, which is fine for setup but not for
      an inner loop -- an SPI byte would cost three round trips instead of one.
      This composes the word from the shadow and writes it once. `toggle:` flips
      the named `:wtoggle` bits in the same word.
      """
      def put(opts) do
        {toggles, regs} = Keyword.pop(opts, :toggle, [])
        specs = __fields__()

        Enum.each(regs, fn {reg, fields} ->
          word =
            Enum.reduce(fields, shadow(reg), fn {name, value}, acc ->
              {_, ^reg, _hi, lo, _a, width} = find_field!(specs, reg, name)
              mask = (1 <<< width) - 1

              if value > mask do
                raise ArgumentError, "#{name}: #{value} does not fit in #{width} bits"
              end

              (acc &&& bnot(mask <<< lo)) ||| value <<< lo
            end)

          word =
            Enum.reduce(toggles, word, fn name, acc ->
              case Enum.find(specs, fn {n, r, _, _, _, _} -> n == name and r == reg end) do
                nil -> acc
                {_, _, _, lo, _, _} -> (acc &&& bnot(1 <<< lo)) ||| bxor(acc >>> lo &&& 1, 1) <<< lo
              end
            end)

          put_shadow(reg, word)
          Nervezynq.Fabric.write32(unquote(ctrl_base) + reg_index(reg) * 4, word)
        end)
      end

      defp find_field!(specs, reg, name) do
        Enum.find(specs, fn {n, r, _, _, _, _} -> n == name and r == reg end) ||
          raise ArgumentError, "no field #{inspect(name)} in #{inspect(reg)}"
      end

      @doc "Every readable field, as a map. For humans."
      def dump do
        Map.new(unquote(readable), fn f -> {f, apply(__MODULE__, f, [])} end)
      end
    end
  end

  @doc false
  def expand(spec) do
    Enum.flat_map(spec, fn {reg, fields} ->
      {out, _} =
        Enum.map_reduce(fields, 0, fn {name, access, width}, off ->
          {{name, reg, off + width - 1, off, access, width}, off + width}
        end)

      Enum.reject(out, fn {name, _, _, _, _, _} -> name == :_pad end)
    end)
  end

  defp reg_addr(reg, ctrl_base, status_base) do
    s = Atom.to_string(reg)
    idx = s |> String.replace(~r/\D/, "") |> String.to_integer()
    if String.starts_with?(s, "ctrl"), do: ctrl_base + idx * 4, else: status_base + idx * 4
  end

end
