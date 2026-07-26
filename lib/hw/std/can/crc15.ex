defmodule Hw.CAN.CRC15 do
  @moduledoc """
  CAN CRC-15 combinational update function.

  Polynomial: x^15 + x^14 + x^10 + x^8 + x^7 + x^4 + x^3 + 1 (0x4599).
  Purely combinational — zero latency, one bit per call.

  CAN initialises the CRC register to 0 and feeds it every bit of the frame
  from SOF through the end of the data field, **before** bit stuffing (stuff
  bits are not fed to the CRC). A receiver that also feeds in the 15 received
  CRC bits ends with a register of 0 — that is the residual check on `valid`.

  ## Ports

  - `crc_in`  - Current CRC state (15 bits)
  - `bit_in`  - Incoming data bit (destuffed)
  - `crc_out` - Next CRC state (15 bits, combinational)
  - `valid`   - High when `crc_in` is 0, the correct RX residual

  ## Update rule

      inv = bit_in XOR crc_in[14]
      crc_out = (crc_in << 1) XOR (inv ? 0x4599 : 0)

  Expanded, with taps at 0, 3, 4, 7, 8, 10, 14:

      crc_out[0]  = inv                    crc_out[8]  = crc_in[7] XOR inv
      crc_out[1]  = crc_in[0]              crc_out[9]  = crc_in[8]
      crc_out[2]  = crc_in[1]              crc_out[10] = crc_in[9] XOR inv
      crc_out[3]  = crc_in[2] XOR inv      crc_out[11] = crc_in[10]
      crc_out[4]  = crc_in[3] XOR inv      crc_out[12] = crc_in[11]
      crc_out[5]  = crc_in[4]              crc_out[13] = crc_in[12]
      crc_out[6]  = crc_in[5]              crc_out[14] = crc_in[13] XOR inv
      crc_out[7]  = crc_in[6] XOR inv
  """

  use Hw.Component

  input  :crc_in,  15
  input  :bit_in,   1
  output :crc_out, 15
  output :valid,    1

  wire :inv, 1

  comb do
    inv = bxor(bit_in, crc_in[14..14])

    # Concat is MSB first: crc_out[14] leftmost, crc_out[0] rightmost.
    crc_out = {
      bxor(crc_in[13..13], inv),   # 14  tap
      crc_in[12..12],              # 13
      crc_in[11..11],              # 12
      crc_in[10..10],              # 11
      bxor(crc_in[9..9], inv),     # 10  tap
      crc_in[8..8],                #  9
      bxor(crc_in[7..7], inv),     #  8  tap
      bxor(crc_in[6..6], inv),     #  7  tap
      crc_in[5..5],                #  6
      crc_in[4..4],                #  5
      bxor(crc_in[3..3], inv),     #  4  tap
      bxor(crc_in[2..2], inv),     #  3  tap
      crc_in[1..1],                #  2
      crc_in[0..0],                #  1
      inv                          #  0  tap
    }

    # RX residual: after clocking in the frame plus its 15 CRC bits, a good
    # frame leaves the register at zero.
    valid = (crc_in == 0)
  end

  @poly 0x4599

  @doc """
  Elixir reference implementation. Computes the next CRC-15 state given the
  current state and one input bit. Mirrors the combinational logic above.
  """
  def next(crc, bit) do
    import Bitwise
    inv = bxor(bit, band(bsr(crc, 14), 1))
    shifted = band(bsl(crc, 1), 0x7FFF)
    if inv == 1, do: bxor(shifted, @poly), else: shifted
  end

  @doc """
  Compute CRC-15 over a list of bits (MSB first), starting from 0.

  Feed the destuffed frame bits from SOF through the end of the data field.
  """
  def compute(bits, crc \\ 0) do
    Enum.reduce(bits, crc, &next(&2, &1))
  end

  @doc """
  Expand an integer into a list of `width` bits, MSB first. Convenience for
  building test vectors and for computing a frame's CRC from field values.
  """
  def bits(value, width) do
    import Bitwise
    for i <- (width - 1)..0//-1, do: band(bsr(value, i), 1)
  end

  @doc "The polynomial, as an integer, for reference and tests."
  def poly, do: @poly
end
