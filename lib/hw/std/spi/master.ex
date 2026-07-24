defmodule Hw.SPI.Master do
  @moduledoc """
  SPI master — Mode 0 (CPOL=0, CPHA=0), MSB-first, one byte per transfer.

  Generates SCK, drives MOSI, samples MISO, and frames transactions with an
  active-low chip select. Full-duplex: each byte shifted out on MOSI
  simultaneously shifts a byte in on MISO.

  Deliberately a *dumb byte pipe* — it knows nothing about any device's command
  grammar (e.g. the MCP2515's). That protocol lives on the host; this block just
  moves bytes across the wire with correct SPI timing and CS framing.

  ## Parameters

  - `CLK_FREQ` - System clock in Hz (default 48_000_000)
  - `SCK_FREQ` - Target SPI clock in Hz (default 4_000_000). The half-period is
    `CLK_FREQ / SCK_FREQ / 2` system clocks, so SCK = CLK_FREQ / (2 * that).
    Keep SCK <= the slave's maximum (MCP2515: 10 MHz).

  ## Ports

  - `clk`      - Clock
  - `rst`      - Synchronous reset, active high
  - `tx_data`  - Byte to shift out (MSB first)
  - `tx_valid` - Assert with `tx_data` stable to begin a transfer
  - `cs_hold`  - Sampled with `tx_valid`: 1 keeps CS asserted after this byte
                 (more bytes coming), 0 releases CS when the byte completes
  - `tx_ready` - High in idle; a byte is accepted on `tx_valid & tx_ready`
  - `rx_data`  - Byte shifted in from MISO (stable while `rx_valid` is high)
  - `rx_valid` - One-cycle pulse when a byte completes
  - `sck`      - SPI clock, idle low
  - `mosi`     - Master out / slave in, MSB first
  - `miso`     - Master in / slave out
  - `cs_n`     - Chip select, active low

  ## Mode 0 timing

  SCK idles low. MOSI is set up while SCK is low; the slave samples MOSI and we
  sample MISO on the SCK rising (leading) edge; MOSI advances on the falling
  (trailing) edge. The first bit (MSB) is set up as CS asserts, before the first
  rising edge — the initial SCK-low half period doubles as CS setup time.

  ## FSM states

  - `:idle` - CS at rest, `tx_ready` high. On `tx_valid`: latch the byte, assert
              CS, enter `:low`.
  - `:low`  - SCK-low half period. On tick: raise SCK, sample MISO, enter `:high`.
  - `:high` - SCK-high half period. On tick: lower SCK; if this was the 8th bit,
              latch `rx_data`, pulse `rx_valid`, release CS unless `cs_hold`, and
              return to `:idle`; otherwise advance MOSI and enter `:low`.
  """

  use Hw.Component

  param :CLK_FREQ, default: 48_000_000
  param :SCK_FREQ, default: 4_000_000

  clock :clk, freq: 48.0
  input  :rst,      1
  input  :tx_data,  8
  input  :tx_valid, 1
  input  :cs_hold,  1
  output :tx_ready, 1
  output :rx_data,  8
  output :rx_valid, 1
  output :sck,      1
  output :mosi,     1
  input  :miso,     1
  output :cs_n,     1

  wire :div_cnt,     16, init: 0
  wire :bit_cnt,      4, init: 0
  wire :tx_shift,     8, init: 0
  wire :rx_shift,     8, init: 0
  wire :sck_reg,      1, init: 0
  wire :csn_reg,      1, init: 1
  wire :rx_data_reg,  8, init: 0
  wire :rx_valid_reg, 1, init: 0
  wire :cs_hold_reg,  1, init: 0
  wire :half_tick,    1
  wire :zero,         1

  comb do
    half_tick = (div_cnt == CLK_FREQ / SCK_FREQ / 2 - 1)
    zero      = 0
    sck       = sck_reg
    mosi      = tx_shift[7..7]
    cs_n      = csn_reg
    rx_data   = rx_data_reg
    rx_valid  = rx_valid_reg
  end

  # Latch a byte and open a transfer: MOSI follows tx_shift[7] (the MSB),
  # CS asserts low, and the caller's cs_hold is captured for end-of-byte framing.
  defhw load_byte() do
    tx_shift    = tx_data
    cs_hold_reg = cs_hold
    csn_reg     = 0
    bit_cnt     = 0
    div_cnt     = 0
    sck_reg     = 0
  end

  fsm :spi_state, clock: :clk, reset: :rst, init: :idle do
    defaults do
      tx_ready     = 0
      rx_valid_reg = 0
      div_cnt      = div_cnt + 1
    end

    case spi_state do
      :idle ->
        tx_ready = 1
        div_cnt  = 0
        on tx_valid do
          load_byte()
          next :low
        end

      :low ->
        on half_tick do
          sck_reg  = 1
          rx_shift = {rx_shift[6..0], miso}
          div_cnt  = 0
          next :high
        end

      :high ->
        on half_tick do
          sck_reg = 0
          div_cnt = 0
          on bit_cnt == 7 do
            rx_data_reg  = rx_shift
            rx_valid_reg = 1
            on cs_hold_reg == 0 do
              csn_reg = 1
            end
            next :idle
          end
          on :else do
            tx_shift = {tx_shift[6..0], zero}
            bit_cnt  = bit_cnt + 1
            next :low
          end
        end
    end
  end
end
