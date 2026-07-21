defmodule Hw.USB.CRC16 do
  @moduledoc """
  USB CRC16 combinational update function.

  Polynomial: x^16 + x^15 + x^2 + 1 (0x8005), reflected form (CRC-16/USB).
  Computes the next CRC state from the current state and one input bit.
  Purely combinational — zero latency. Register crc_out → crc_in externally.

  ## USB CRC16 conventions

  - Data bytes are transmitted LSB-first on the USB bus.
  - CRC is computed over the data bits in the order they arrive (LSB-first).
  - The reflected LFSR (feedback from bit 0, reflected polynomial 0xA001) matches
    this natural bit order without needing to reverse bytes before feeding them in.
  - The CRC is initialized to 0xFFFF, complemented before transmission, and
    transmitted MSB-first (bit 15 first) immediately after the last data byte.
  - A correct received packet (data bytes + 16 CRC bits, all processed through
    this module) leaves residual **0xB001** in the running CRC register.

  ## Ports

  - `crc_in`  - Current CRC state (16 bits)
  - `bit_in`  - Incoming data bit (LSB-first from the wire)
  - `crc_out` - Next CRC state (16 bits, combinational)
  - `valid`   - High when crc_in matches the RX residual (0xB001)
  """

  use Hw.Component

  input  :crc_in,  16
  input  :bit_in,  1
  output :crc_out, 16
  output :valid,   1

  # Intermediate: the feedback/inversion bit (from LSB for reflected LFSR)
  wire :inv, 1

  # Reflected CRC-16/USB LFSR step.
  #
  # Reflected polynomial 0xA001 has taps at bit positions 0, 1, and 13
  # (0-indexed from LSB), corresponding to x^1, x^2, and x^14 in the
  # original polynomial x^16 + x^15 + x^2 + 1.
  #
  # Update rule for one input bit arriving LSB-first:
  #   inv         = bit_in XOR crc_in[0]      <- feedback from LSB
  #   crc_out[15] = inv
  #   crc_out[14] = crc_in[15]
  #   crc_out[13] = crc_in[14] XOR inv        <- tap (x^14 -> bit 13)
  #   crc_out[12..2] = crc_in[13..3]          <- plain right-shift
  #   crc_out[1]  = crc_in[2]                 <- plain right-shift (no tap at bit 1)
  #   crc_out[0]  = crc_in[1] XOR inv         <- tap (0xA001 bit 0 = x^1)
  #
  # Concat is MSB first, so crc_out[15] is leftmost.

  comb do
    inv = bxor(bit_in, crc_in[0..0])

    crc_out = {
      inv,                          # crc_out[15] = inv
      crc_in[15..15],               # crc_out[14] = crc_in[15]
      bxor(crc_in[14..14], inv),    # crc_out[13] = crc_in[14] ^ inv  (tap x^14)
      crc_in[13..13],               # crc_out[12] = crc_in[13]
      crc_in[12..12],               # crc_out[11] = crc_in[12]
      crc_in[11..11],               # crc_out[10] = crc_in[11]
      crc_in[10..10],               # crc_out[9]  = crc_in[10]
      crc_in[ 9.. 9],               # crc_out[8]  = crc_in[9]
      crc_in[ 8.. 8],               # crc_out[7]  = crc_in[8]
      crc_in[ 7.. 7],               # crc_out[6]  = crc_in[7]
      crc_in[ 6.. 6],               # crc_out[5]  = crc_in[6]
      crc_in[ 5.. 5],               # crc_out[4]  = crc_in[5]
      crc_in[ 4.. 4],               # crc_out[3]  = crc_in[4]
      crc_in[ 3.. 3],               # crc_out[2]  = crc_in[3]
      crc_in[ 2.. 2],               # crc_out[1]  = crc_in[2]         (no tap here)
      bxor(crc_in[ 1.. 1], inv)     # crc_out[0]  = crc_in[1] ^ inv   (tap x^1, 0xA001 bit 0)
    }

    # RX residual check: correctly received data+CRC leaves 0xB001
    valid = (crc_in == 0xB001)
  end

  @doc """
  Elixir reference implementation for testing.
  Computes the next CRC16 state given current state and one input bit.

  Uses the reflected LFSR: feedback from bit 0, polynomial 0xA001.
  """
  def next(crc, bit) do
    import Bitwise
    inv = bxor(bit, band(crc, 1))
    crc = bsr(crc, 1)
    if inv == 1, do: bxor(crc, 0xA001), else: crc
  end

  @doc """
  Compute CRC16 over a list of bits. Initialize with 0xFFFF.

  Bits should be supplied in the order they arrive from the wire (LSB-first
  per byte). The CRC is transmitted as the bitwise complement of the final
  register value, MSB (bit 15) first.
  """
  def compute(bits, crc \\ 0xFFFF) do
    Enum.reduce(bits, crc, &next(&2, &1))
  end
end
