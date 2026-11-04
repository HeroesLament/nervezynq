defmodule Nervezynq.PortWire do
  @moduledoc """
  The wire protocol to `oxibit`, in one place.

  ## Two ports, one protocol

  `oxibit` (priv/oxibit, built from the oxibit repo; see the Makefile) is the
  only native code between this app and physical memory. It runs in one of
  two modes, both speaking this protocol:

  - `open_pl/2` starts `oxibit port`: the PL aperture (M_AXI_GP0). It owns
    loading as well as access, and refuses every access op unless hardware
    says the PL is configured and the PS-PL boundary is open. Only
    `Nervezynq.Fabric` opens one.
  - `open/2` starts `oxibit mem <base> <len>`: PS-side memory (DDR buffers,
    SLCR, DevC, PS GPIO). It refuses any range inside M_AXI_GP0/GP1, so no
    mapping opened here can reach the PL behind the guard's back.

  Ops 0x01 to 0x06 are byte-identical to the retired `fabric_port`. Op 0x07
  (EXEC) runs a register program -- interleaved read32/write32 -- in one
  message, returning the reads in order.

  ## Why the format lives here

  Copy-pasting a decoder is how two decoders drift apart and one of them starts
  lying. That is not hypothetical here: this project has already shipped six
  instruments that produced confident wrong answers, and a silently divergent
  wire format would be the easiest possible seventh -- a wrong opcode reads a
  plausible number from the wrong offset and nothing crashes.

  ## The format

  Request: one opcode byte, then arguments, big-endian.
  Reply: one status byte (`0x00` ok, `0x01` error) then the payload. Errors are
  UTF-8 text for ops up to 0x06 and JSON objects for LOAD, STATUS and CLEAR.
  """

  @op_read32 0x01
  @op_write32 0x02
  @op_read_block 0x03
  @op_write_block 0x04
  @op_info 0x05
  @op_read_repeat 0x06
  @op_exec 0x07
  @op_load 0x10
  @op_status 0x11
  @op_clear 0x12

  @resp_ok 0x00
  @resp_err 0x01

  @doc """
  Open `oxibit mem` over `len` bytes of PS-side physical memory at `base`.

  `{:packet, 4}` is NOT optional and is the whole reason opening lives here
  rather than at each call site: the port reads a 4-byte big-endian length
  before every request, and without the option every call times out. That
  happened once, when the first version of this module left each caller to
  open its own port.
  """
  def open(base, len) do
    spawn_oxibit(["mem", hex(base), Integer.to_string(len)])
  end

  @doc "Open `oxibit port`, the guarded PL port, over the aperture at `base`."
  def open_pl(base, len) do
    spawn_oxibit(["port", "--base", hex(base), "--len", Integer.to_string(len)])
  end

  defp spawn_oxibit(args) do
    exe = Path.join(:code.priv_dir(:nervezynq), "oxibit")

    if File.exists?(exe) do
      {:ok,
       Port.open({:spawn_executable, exe}, [
         {:args, args},
         {:packet, 4},
         :binary,
         :exit_status
       ])}
    else
      {:error, {:missing_port_binary, exe}}
    end
  end

  defp hex(n), do: "0x" <> Integer.to_string(n, 16)

  def encode({:read32, offset}), do: <<@op_read32, offset::32>>
  def encode({:write32, offset, value}), do: <<@op_write32, offset::32, value::32>>
  def encode({:read_block, offset, count}), do: <<@op_read_block, offset::32, count::16>>
  def encode({:read_repeat, offset, count}), do: <<@op_read_repeat, offset::32, count::16>>

  def encode({:write_block, offset, values}) do
    words = for v <- values, into: <<>>, do: <<v::32>>
    <<@op_write_block, offset::32, length(values)::16, words::binary>>
  end

  # Same op as write_block, payload already in wire order (each word
  # big-endian): no per-word list round trip for bulk DDR writes.
  def encode({:write_block_raw, offset, bin}) when rem(byte_size(bin), 4) == 0 do
    <<@op_write_block, offset::32, div(byte_size(bin), 4)::16, bin::binary>>
  end

  def encode({:exec, ops}) do
    body =
      for op <- ops, into: <<>> do
        case op do
          {:r, offset} -> <<0x01, offset::32>>
          {:w, offset, value} -> <<0x02, offset::32, value::32>>
        end
      end

    <<@op_exec>> <> body
  end

  def encode(:info), do: <<@op_info>>
  def encode({:load, path, aperture?}), do: encode({:load, path, aperture?, true})

  def encode({:load, path, aperture?, hash?}),
    do: <<@op_load>> <> JSON.encode!(%{path: path, aperture: aperture?, hash: hash?})
  def encode(:status), do: <<@op_status>>
  def encode(:clear), do: <<@op_clear>>

  def decode({:read32, _}, <<value::32>>), do: {:ok, value}
  def decode({:write32, _, _}, <<>>), do: :ok
  def decode({:read_block, _, _}, payload), do: {:ok, for(<<w::32 <- payload>>, do: w)}
  def decode({:read_repeat, _, _}, payload), do: {:ok, for(<<w::32 <- payload>>, do: w)}
  def decode({:write_block, _, _}, <<>>), do: :ok
  def decode({:write_block_raw, _, _}, <<>>), do: :ok
  def decode({:exec, _}, payload), do: {:ok, for(<<w::32 <- payload>>, do: w)}
  def decode(:info, <<base::64, length::32>>), do: {:ok, %{base: base, length: length}}
  def decode({:load, _, _}, json), do: {:ok, JSON.decode!(json)}
  def decode({:load, _, _, _}, json), do: {:ok, JSON.decode!(json)}
  def decode(:status, json), do: {:ok, JSON.decode!(json)}
  def decode(:clear, json), do: {:ok, JSON.decode!(json)}
  def decode(_request, payload), do: {:error, {:unexpected_reply, payload}}

  @doc "Send one request and wait for its reply."
  def transact(port, request, timeout \\ 5_000) do
    send(port, {self(), {:command, encode(request)}})

    receive do
      {^port, {:data, <<@resp_ok, payload::binary>>}} -> decode(request, payload)
      {^port, {:data, <<@resp_err, message::binary>>}} -> {:error, error_reason(request, message)}
      {^port, {:exit_status, status}} -> {:error, {:port_exited, status}}
    after
      timeout -> {:error, :timeout}
    end
  end

  # LOAD/STATUS/CLEAR errors are JSON objects ({"error": kind, ...}). An
  # access op refused by the guard comes back as "PL access refused: <why>".
  defp error_reason({:load, _, _}, message), do: json_error(message)
  defp error_reason(:status, message), do: json_error(message)
  defp error_reason(:clear, message), do: json_error(message)
  defp error_reason(_request, "PL access refused: " <> why), do: {:pl_not_ready, why}
  defp error_reason(_request, message), do: message

  defp json_error(message) do
    case JSON.decode(message) do
      {:ok, map} -> map
      _ -> message
    end
  end

  @doc """
  The largest `write_block` the framing allows.

  The count field is 16 bits, so 65535 words, but the port's read buffer is the
  real limit. Chunk against this rather than discovering it as a truncated
  transfer, which would look like corrupted frame data rather than like a
  framing error.
  """
  def max_block_words, do: 1024
end
