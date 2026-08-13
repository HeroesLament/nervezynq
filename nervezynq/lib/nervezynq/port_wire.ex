defmodule Nervezynq.PortWire do
  @moduledoc """
  The `fabric_port` wire protocol, in one place.

  ## Why this module exists

  `fabric_port` takes `<base> <len>` in argv and mmaps that physical range, so
  ONE Rust binary already serves every aperture this project needs: the PL at
  `0x4000_0000`, the SLCR at `0xF800_0000`, devcfg at `0xF800_7000`, and a
  reserved DRAM buffer for configuration readback. What it did not have was one
  encoder -- `Nervezynq.Fabric` owned the frame format privately, so a second
  mapping meant either copy-pasting it or reaching into another GenServer.

  Copy-pasting a decoder is how two decoders drift apart and one of them starts
  lying. That is not hypothetical here: this project has already shipped six
  instruments that produced confident wrong answers, and a silently divergent
  wire format would be the easiest possible seventh -- a wrong opcode reads a
  plausible number from the wrong offset and nothing crashes.

  So the format lives here, and every aperture is a thin GenServer over it.

  ## The format

  Request: one opcode byte, then arguments, big-endian.
  Reply: one status byte (`0x00` ok, `0x01` error) then the payload.

  The reply carries no opcode and does not need one: the port answers one
  request at a time, so the request still in scope at the call site says how to
  read the answer.
  """

  @op_read32 0x01
  @op_write32 0x02
  @op_read_block 0x03
  @op_write_block 0x04
  @op_info 0x05
  @op_read_repeat 0x06

  @resp_ok 0x00
  @resp_err 0x01

  @doc """
  Open a port mapping `len` bytes of physical memory at `base`.

  `{:packet, 4}` is NOT optional and is the whole reason this function exists
  here rather than being written out at each call site. `fabric_port` reads a
  4-byte big-endian length prefix before every request; without the option the
  port sits waiting for a header that never arrives and every call times out.

  That is not hypothetical. The first version of this module factored out
  `encode/decode/transact` but left each caller to open its own port, and the
  new one was opened without framing. The symptom was that even `:info` timed
  out -- a request that never touches the bus -- while `Nervezynq.Fabric`, which
  still had its own correct `Port.open`, kept working perfectly. Half a
  protocol is worse than none, because the half that is shared makes the other
  half look shared too.

  The base is passed as `"0x"`-prefixed hex to match what the port has always
  been given. It parses decimal too, but there is no reason for two call sites
  to disagree about the format of an argument.
  """
  def open(base, len) do
    exe = Path.join(:code.priv_dir(:nervezynq), "fabric_port")

    if File.exists?(exe) do
      {:ok,
       Port.open({:spawn_executable, exe}, [
         {:args, ["0x" <> Integer.to_string(base, 16), Integer.to_string(len)]},
         {:packet, 4},
         :binary,
         :exit_status
       ])}
    else
      {:error, {:missing_port_binary, exe}}
    end
  end

  def encode({:read32, offset}), do: <<@op_read32, offset::32>>
  def encode({:write32, offset, value}), do: <<@op_write32, offset::32, value::32>>
  def encode({:read_block, offset, count}), do: <<@op_read_block, offset::32, count::16>>
  def encode({:read_repeat, offset, count}), do: <<@op_read_repeat, offset::32, count::16>>

  def encode({:write_block, offset, values}) do
    words = for v <- values, into: <<>>, do: <<v::32>>
    <<@op_write_block, offset::32, length(values)::16, words::binary>>
  end

  def encode(:info), do: <<@op_info>>

  def decode({:read32, _}, <<value::32>>), do: {:ok, value}
  def decode({:write32, _, _}, <<>>), do: :ok
  def decode({:read_block, _, _}, payload), do: {:ok, for(<<w::32 <- payload>>, do: w)}
  def decode({:read_repeat, _, _}, payload), do: {:ok, for(<<w::32 <- payload>>, do: w)}
  def decode({:write_block, _, _}, <<>>), do: :ok
  def decode(:info, <<base::64, length::32>>), do: {:ok, %{base: base, length: length}}
  def decode(_request, payload), do: {:error, {:unexpected_reply, payload}}

  @doc "Send one request and wait for its reply."
  def transact(port, request, timeout \\ 5_000) do
    send(port, {self(), {:command, encode(request)}})

    receive do
      {^port, {:data, <<@resp_ok, payload::binary>>}} -> decode(request, payload)
      {^port, {:data, <<@resp_err, message::binary>>}} -> {:error, message}
      {^port, {:exit_status, status}} -> {:error, {:port_exited, status}}
    after
      timeout -> {:error, :timeout}
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
