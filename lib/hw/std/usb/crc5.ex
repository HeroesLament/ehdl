defmodule Hw.USB.CRC5 do
  @moduledoc """
  USB CRC5 combinational update function.

  Polynomial: x^5 + x^2 + 1 (0x05)
  Used for USB token packets (SOF, IN, OUT, SETUP).
  Purely combinational — zero latency.

  USB CRC5 is initialized to 0x1F, transmitted as bitwise complement, LSB first.
  A correct received token has residual 0x0C.

  ## Ports

  - `crc_in`  - Current CRC state (5 bits)
  - `bit_in`  - Incoming data bit
  - `crc_out` - Next CRC state (5 bits, combinational)
  - `valid`   - High when crc_in matches the expected RX residual (0x0C)
  """

  use Hw.Component

  input  :crc_in,  5
  input  :bit_in,  1
  output :crc_out, 5
  output :valid,   1

  wire :inv, 1

  # USB CRC5 polynomial: x^5 + x^2 + 1
  # Taps at positions 0 and 2 (0-indexed from LSB).
  #
  # Update rule for one input bit:
  #   inv        = bit_in XOR crc_in[4]
  #   crc_out[0] = inv
  #   crc_out[1] = crc_in[0]
  #   crc_out[2] = crc_in[1] XOR inv   <- tap
  #   crc_out[3] = crc_in[2]
  #   crc_out[4] = crc_in[3]
  #
  # Concat is MSB first, so crc_out[4] is leftmost.

  comb do
    inv = bxor(bit_in, crc_in[4..4])

    crc_out = {
      crc_in[3..3],             # crc_out[4] = crc_in[3]
      crc_in[2..2],             # crc_out[3] = crc_in[2]
      bxor(crc_in[1..1], inv),  # crc_out[2] = crc_in[1] ^ inv  (tap)
      crc_in[0..0],             # crc_out[1] = crc_in[0]
      inv                       # crc_out[0] = inv
    }

    # RX residual check: a correctly received token+CRC5 field leaves 0x0C
    valid = (crc_in == 0x0C)
  end

  @doc """
  Elixir reference implementation for testing.
  Computes the next CRC5 state given current state and one input bit.
  """
  def next(crc, bit) do
    import Bitwise
    inv = bxor(bit, band(bsr(crc, 4), 1))
    b = fn n -> band(bsr(crc, n), 1) end

    bits = [b.(3), b.(2), bxor(b.(1), inv), b.(0), inv]
    Enum.reduce(bits, 0, fn b, acc -> bor(bsl(acc, 1), b) end)
  end

  @doc """
  Compute CRC5 over a list of bits. Initialize with 0x1F.
  Transmit as bitwise complement, LSB first.
  """
  def compute(bits, crc \\ 0x1F) do
    Enum.reduce(bits, crc, &next(&2, &1))
  end
end
