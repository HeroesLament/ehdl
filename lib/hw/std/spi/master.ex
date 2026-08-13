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

  - `MISO_SAMPLE_TRAILING` - Which SCK edge to sample MISO on (default 0)
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

  SCK idles low. MOSI is set up while SCK is low; the slave samples MOSI on the
  SCK rising (leading) edge; MOSI advances on the falling (trailing) edge. The
  first bit (MSB) is set up as CS asserts, before the first rising edge — the
  initial SCK-low half period doubles as CS setup time.

  ## Which edge MISO is sampled on

  "SPI mode 0" pins down when the MASTER drives and samples, but not when the
  slave updates its output, and devices disagree:

  - An MCP2515 drives MISO on the FALLING edge. The bit is stable through the
    whole SCK-low period, so sampling as SCK rises is correct.
  - An AD936x drives SPI_DO on the RISING edge. During SCK-low the line still
    holds the PREVIOUS bit, so sampling as SCK rises reads one bit early.

  Sampling one bit early is not a garbled result — it is a coherent, plausible
  stream shifted by one place, which is why it survives a casual look. Reading
  the AD9363's product ID returned 0x85 where 0x0A was expected, and
  0x85 << 1 == 0x0A: every bit correct, every bit in the wrong place, and the
  LSB of each byte lost off the end.

  `MISO_SAMPLE_TRAILING` selects the edge. 0 (the default) samples as SCK
  rises, preserving the behaviour every existing caller was written against.
  1 samples as SCK falls, half a period later, for slaves that update on the
  rising edge.

  Both shift registers are always clocked and the choice is a mux on a
  compile-time constant, so the unused path folds away in synthesis. Making the
  sampling instant itself conditional would put a parameter in the middle of
  the FSM's control flow for no gain.

  Do not attempt to recover the lost bit by clocking extra cycles. On an
  AD9363, a 32-clock transaction where the device expects 24 desynchronises its
  SPI state machine, and only a RESETB pulse recovers it — the reads after it
  come back as zeros and look like a dead chip.

  ## FSM states

  - `:idle` - CS at rest, `tx_ready` high. On `tx_valid`: latch the byte, assert
              CS, enter `:low`.
  - `:low`  - SCK-low half period. On tick: raise SCK, sample MISO, enter `:high`.
  - `:high` - SCK-high half period. On tick: lower SCK; if this was the 8th bit,
              latch `rx_data`, pulse `rx_valid`, release CS unless `cs_hold`, and
              return to `:idle`; otherwise advance MOSI and enter `:low`.
  """

  use Hw.Component

  # 0: sample MISO as SCK rises (slave updates on the falling edge, e.g. MCP2515)
  # 1: sample MISO as SCK falls (slave updates on the rising edge, e.g. AD936x)
  param :MISO_SAMPLE_TRAILING, default: 0
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
  wire :rx_shift_t,   8, init: 0
  wire :sck_reg,      1, init: 0
  wire :csn_reg,      1, init: 1
  wire :rx_data_reg,  8, init: 0
  wire :rx_valid_reg, 1, init: 0
  wire :cs_hold_reg,  1, init: 0
  wire :half_tick,    1
  wire :zero,         1
  wire :rx_trailing,  8
  wire :rx_final,     8

  comb do
    half_tick = (div_cnt == CLK_FREQ / SCK_FREQ / 2 - 1)
    zero      = 0
    sck       = sck_reg
    mosi      = tx_shift[7..7]
    cs_n      = csn_reg
    rx_data   = rx_data_reg
    rx_valid  = rx_valid_reg

    # The trailing-edge path samples its eighth bit in the same cycle the byte
    # is latched, so the final value has to include the bit arriving now rather
    # than the register's pre-edge contents.
    rx_trailing = {rx_shift_t[6..0], miso}
    rx_final = if MISO_SAMPLE_TRAILING == 1, do: rx_trailing, else: rx_shift
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
        # `fsm` outputs are registered: `tx_ready` is low on the first cycle of
        # :idle and would remain high into :low. Test both halves and clear it
        # on the transition, so a byte cannot be consumed without a handshake
        # the producer actually observed.
        on tx_ready and tx_valid do
          tx_ready = 0
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
          rx_shift_t = rx_trailing
          on bit_cnt == 7 do
            rx_data_reg  = rx_final
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
