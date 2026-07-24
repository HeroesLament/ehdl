defmodule Hw.Diag.SerialReport do
  @moduledoc """
  Streams a handful of 1-bit diagnostic signals out a UART as a repeating
  ASCII line, so a host on the other end of the serial link can read the
  device's internal state as plain text — no logic analyzer required.

  This exists to close the hardware debugging loop over the ULX3S US1 FTDI
  serial port (which appears as `/dev/cu.usbserial-*` on the host). The
  DSLogic U2Basic is not supported by open-source sigrok (it uses a Pango
  FPGA, not the Xilinx parts sigrok's driver targets), so analyzer capture
  can't be automated; this serial reporter is the analyzer-free substitute
  for yes/no state questions.

  ## What it emits

  Once per report period it transmits the 6 input bits `b0..b5` as ASCII
  `'0'`/`'1'` characters (b0 first), followed by CR (`0x0D`) and LF
  (`0x0A`). Example line on the wire: `101000\\r\\n`.

  Read it on the host with e.g.:

      screen /dev/cu.usbserial-XXXX 115200
      # or, scriptable:
      stty -f /dev/cu.usbserial-XXXX 115200 && head -c 64 /dev/cu.usbserial-XXXX

  ## Ports

  - `clk`   — clock (48 MHz)
  - `rst`   — synchronous reset, active high
  - `b0..b5`— the six 1-bit signals to report (latches, flags, etc.)
  - `txd`   — serial output, wire it to the FTDI RX pin (idle high)

  ## Design notes

  Pure passive observer: it only READS its `b0..b5` inputs and drives its own
  UART. It shares no state with the logic under test, so it cannot perturb it.
  Instantiates `Hw.UART.TX` internally at 115200 8N1.
  """

  use Hw.Component

  param :CLK_FREQ,  default: 48_000_000
  param :BAUD_RATE, default: 115_200
  # Cycles allotted to each byte slot: one full 10-bit frame plus margin. The
  # sender pulses `valid` at slot start and advances at slot end — a purely
  # timer-based cadence that does NOT depend on reading the UART's `ready`
  # (which lags across the instance boundary and caused earlier stalls).
  # 12 bit-times at (CLK_FREQ/BAUD_RATE) cyc/bit leaves ~2 bits of margin.
  param :BYTE_CYCLES, default: 6000   # ~12 bits * 500 cyc/bit; overridden per baud
  # Report period in clock cycles between the end of one line and the next.
  param :GAP_CYCLES, default: 4_800_000

  clock :clk, freq: 48.0
  input  :rst, 1

  input  :b0, 1
  input  :b1, 1
  input  :b2, 1
  input  :b3, 1
  input  :b4, 1
  input  :b5, 1

  output :txd, 1

  # --- Internal UART TX ---
  wire :uart_data,  8
  wire :uart_valid, 1, init: 0
  wire :uart_ready, 1

  # Inner UART fixed at 9600 8N1. (Param forwarding into a sub-instance isn't
  # supported by the DSL, and 9600 is the rate the FTDI/USB path drains reliably
  # without RX-FIFO overrun — see BYTE_CYCLES note.)
  instance :uart, Hw.UART.TX,
    CLK_FREQ:  48_000_000,
    BAUD_RATE: 9_600,
    clk:   :clk,
    rst:   :rst,
    data:  :uart_data,
    valid: :uart_valid,
    ready: :uart_ready,
    txd:   :txd

  # --- Reporter state ---
  # idx selects which of the 8 line bytes to send: 0..5 = b0..b5 as ASCII,
  # 6 = CR, 7 = LF. After 7, wait GAP_CYCLES then restart at 0.
  wire :idx,       3, init: 0
  wire :slot_cnt, 24, init: 0   # cycles elapsed in the current byte slot
  wire :gap_cnt,  23, init: 0
  wire :sending,   1, init: 1   # 1 while walking the line, 0 while in the inter-line gap
  wire :sel_char,  8            # comb: the ASCII byte for the current idx
  wire :sel_bit,   1            # comb: the selected input bit for idx 0..5

  # ASCII: '0' = 0x30, '1' = 0x31, CR = 0x0D, LF = 0x0A
  wire :bit_char, 8   # comb: selected input bit rendered as ASCII '0'/'1'

  comb do
    # Pick the input bit for the current index (0..5) via an explicit case.
    hdl_case <<idx::3>> do
      <<0::3>> -> sel_bit = b0
      <<1::3>> -> sel_bit = b1
      <<2::3>> -> sel_bit = b2
      <<3::3>> -> sel_bit = b3
      <<4::3>> -> sel_bit = b4
      <<5::3>> -> sel_bit = b5
      <<_::3>> -> sel_bit = 0
    end

    # ASCII '0'(0x30)/'1'(0x31) = 0b0011000<bit>. The 7-bit high prefix is
    # 0b0011000 = 0x18; concat with the 1-bit value yields 0x30 or 0x31.
    bit_char = {0b0011000[6..0], sel_bit}

    # idx 6 -> CR, idx 7 -> LF, else the ASCII bit char.
    hdl_case <<idx::3>> do
      <<6::3>> -> sel_char = 0x0D
      <<7::3>> -> sel_char = 0x0A
      <<_::3>> -> sel_char = bit_char
    end
  end

  on :clk do
    if rst do
      idx        = 0
      slot_cnt   = 0
      gap_cnt    = 0
      sending    = 1
      uart_valid = 0
    else
      uart_data = sel_char
      if sending do
        # Timer-based byte cadence, immune to cross-instance ready latency.
        # At the START of each byte slot (slot_cnt==0) pulse valid for one cycle;
        # UART.TX latches it (its `on valid` in :idle) and transmits the frame.
        # We hold the slot for BYTE_CYCLES (> one frame) then advance. valid is a
        # 1-cycle pulse so the UART sees exactly one byte per slot.
        if slot_cnt == 0 do
          uart_valid = 1
        else
          uart_valid = 0
        end

        if slot_cnt == BYTE_CYCLES do
          slot_cnt = 0
          if idx == 7 do
            idx     = 0
            gap_cnt = 0
            sending = 0
          else
            idx = idx + 1
          end
        else
          slot_cnt = slot_cnt + 1
        end
      else
        # Inter-line gap, then start the next line.
        uart_valid = 0
        if gap_cnt == GAP_CYCLES do
          sending  = 1
          gap_cnt  = 0
          slot_cnt = 0
        else
          gap_cnt = gap_cnt + 1
        end
      end
    end
  end
end
