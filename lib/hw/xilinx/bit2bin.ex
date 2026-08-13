defmodule Hw.Xilinx.Bit2Bin do
  @moduledoc """
  Convert a Xilinx `.bit` into the `.bin` the Zynq FPGA manager will accept.

  Two transformations, both mandatory:

  1. **Strip the TLV header.** A `.bit` carries design name, part, build date
     and time as tag/length/value records ahead of the configuration data.

  2. **Byte-swap within each 32-bit word.** The legacy `xdevcfg` interface
     detected and corrected endianness itself. `fpga_manager` deliberately does
     not — which is why bitstreams that worked on older kernels now fail with
     `Invalid bitstream, could not find a sync word. Bitstream must be a byte
     swapped .bin file`.

  The sync word 0xAA995566 appears as the bytes `AA 99 55 66` in a `.bit` and
  must appear as `66 55 99 AA` in the `.bin`. That is the check used here, and
  it is worth keeping: a silently mis-converted bitstream is indistinguishable
  from a hardware fault once it reaches the board.
  """

  @sync_bit <<0xAA, 0x99, 0x55, 0x66>>
  @sync_bin <<0x66, 0x55, 0x99, 0xAA>>

  @doc "Convert `bit_path` to `bin_path`. Raises on a malformed bitstream."
  def convert!(bit_path, bin_path) do
    bin = bit_path |> File.read!() |> to_bin!()
    File.write!(bin_path, bin)
    bin
  end

  @doc "Pure conversion: `.bit` contents in, `.bin` contents out."
  def to_bin!(data) when is_binary(data) do
    payload = strip_header!(data)

    unless contains?(payload, @sync_bit) do
      raise ArgumentError,
            "no sync word AA 99 55 66 in the config data — header mis-parsed, " <>
              "or this is not a 7-series bitstream"
    end

    swapped = swap32!(payload)

    unless contains?(swapped, @sync_bin) do
      raise ArgumentError, "byte-swapped output lacks the sync word 66 55 99 AA"
    end

    swapped
  end

  # Header: <<u16 len, len bytes>>, <<0x00 0x01>>, then tagged records.
  # 'a'..'d' carry u16-length strings; 'e' carries a u32 length followed by the
  # configuration data itself.
  defp strip_header!(<<len::16, _preamble::binary-size(len), 0x00, 0x01, rest::binary>>),
    do: find_config!(rest)

  defp strip_header!(_),
    do: raise(ArgumentError, "unrecognised .bit header — expected a length-prefixed preamble")

  defp find_config!(<<?e, len::32, data::binary-size(len), _rest::binary>>), do: data

  defp find_config!(<<key, len::16, _value::binary-size(len), rest::binary>>)
       when key in [?a, ?b, ?c, ?d],
       do: find_config!(rest)

  defp find_config!(_),
    do: raise(ArgumentError, "no 'e' (config data) record found in .bit header")

  defp swap32!(data) when rem(byte_size(data), 4) == 0 do
    for <<a, b, c, d <- data>>, into: <<>>, do: <<d, c, b, a>>
  end

  defp swap32!(data),
    do:
      raise(ArgumentError, "config data is not a multiple of 4 bytes (#{byte_size(data)} bytes)")

  defp contains?(hay, needle), do: :binary.match(hay, needle) != :nomatch
end
