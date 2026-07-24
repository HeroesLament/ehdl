defmodule Hw.Diag.SerialStream55 do
  @moduledoc """
  Diagnostic UART streamer: transmits the byte 0x55 ('U', 0b01010101) back to
  back, forever, with no inter-byte gap. Used to characterize the serial link:

  - 0x55 is the classic baud "ruler" — a maximally regular alternating pattern,
    so whatever the host decodes reveals baud/sampling error directly (clean
    0x55 = correct baud; predictable neighbors = ratio error).
  - Continuous, gapless output means the host byte-rate directly reports whether
    the transmit FSM is actually streaming (thousands/sec) or stalled (a handful
    /sec). This isolates "FSM handshake broken" from "baud wrong."

  Same registered valid/ready handshake as the real reporter, reduced to a single
  constant byte, so it also validates that handshake in isolation.

  ## Ports
  - `clk` — clock (48 MHz)
  - `rst` — synchronous reset, active high
  - `txd` — serial output (wire to FTDI RX pin, idle high)
  """

  use Hw.Component

  param :CLK_FREQ,  default: 48_000_000
  param :BAUD_RATE, default: 115_200

  clock :clk, freq: 48.0
  input  :rst, 1
  output :txd, 1

  wire :uart_data,  8
  wire :uart_valid, 1
  wire :uart_ready, 1

  # SLOW baud (9600) to test the FTDI-overrun hypothesis: at 9600 the FPGA emits
  # ~960 bytes/s, far under the FTDI/USB drain rate, so if the earlier stall was an
  # RX-FIFO overrun this should stream continuously instead of bursting once.
  instance :uart, Hw.UART.TX,
    CLK_FREQ:  48_000_000,
    BAUD_RATE: 9_600,
    clk:   :clk,
    rst:   :rst,
    data:  :uart_data,
    valid: :uart_valid,
    ready: :uart_ready,
    txd:   :txd

  # Simplest possible driver: hold valid HIGH and data=0x55 forever. UART.TX's
  # `on valid` is level-sensitive in :idle (verified by isolated sim: with valid
  # held high it re-sends 0x55 back-to-back and cycles idle->sending->idle). So a
  # constant valid gives a continuous gapless 0x55 stream with no handshake FSM
  # at all — exactly what we want for the baud-ruler / rate diagnostic.
  comb do
    uart_data  = 0x55
    uart_valid = 1
  end
end
