defmodule Hw.CAN.MCP2515 do
  @moduledoc """
  MCP2515 register-access engine — the hardware equivalent of `Ch347.Bus`.

  Drives an internal `Hw.SPI.Master` to issue the four MCP2515 SPI transactions
  and hands the result back over a simple command/done handshake. This is the
  *base layer*: it knows the register-access grammar but nothing about bit
  timing, modes, or CAN frames. The higher-level sequences (`configure`,
  `send_frame`, `receive_frame`) compose these ops and live above this block —
  ultimately driven by the setpoint/interpolation engine.

  It is deliberately much simpler than `Ch347.Bus`: every workaround in that
  file (first-MISO-byte glitch, 0xC2 MOSI corruption, lead-read throwaways) is a
  CH347 USB-bridge bug. `Hw.SPI.Master` does clean full-duplex, so a READ is
  literally `0x03, addr, 0x00` with the value in the third MISO byte — no tricks.

  ## Command interface

  Assert `start` for one cycle with `op`/`addr`/`wdata`/`mask` stable. `ready`
  is high when idle. `done` pulses for one cycle when the transaction completes;
  for a READ, `rdata` then holds the register value.

      op  transaction                     bytes on the wire
      0   RESET                           0xC0
      1   WRITE  reg[addr] = wdata        0x02, addr, wdata
      2   READ   rdata = reg[addr]        0x03, addr, 0x00   (value = 3rd MISO)
      3   BITMOD reg[addr] {mask}= wdata  0x05, addr, mask, wdata

  ## SPI mode caveat

  This runs the SPI master in Mode 0 (CPOL=0, CPHA=0), which the MCP2515
  supports (DS20001801K: modes 0,0 and 1,1 both sample on the rising edge; the
  part infers the mode from SCK's idle level at CS assertion). The `can_ex`/CH347
  stack uses Mode 3, but that choice is entangled with CH347 behaviour. If the
  first silicon oracle (CANSTAT != 0x80 after reset) disagrees, SPI mode is the
  first suspect — switch `Hw.SPI.Master` to idle-high SCK.

  ## Ports

  - `clk`, `rst`            - clock, synchronous active-high reset
  - `op` [2]  in            - transaction selector (see table)
  - `addr` [8] in           - register address
  - `wdata` [8] in          - write / bit-modify data byte
  - `mask` [8] in           - bit-modify mask
  - `start` [1] in          - pulse to begin (accepted only while `ready`)
  - `ready` [1] out         - high when idle
  - `done` [1] out          - one-cycle pulse when the transaction completes
  - `rdata` [8] out         - last READ result
  - `sck`/`mosi`/`cs_n` out, `miso` in - SPI bus to the MCP2515
  """

  use Hw.Component

  param :CLK_FREQ, default: 48_000_000
  param :SCK_FREQ, default: 4_000_000

  clock :clk, freq: 48.0
  input  :rst,   1
  input  :op,    2
  input  :addr,  8
  input  :wdata, 8
  input  :mask,  8
  input  :start, 1
  output :ready, 1
  output :done,  1
  output :rdata, 8
  output :sck,   1
  output :mosi,  1
  input  :miso,  1
  output :cs_n,  1

  # Internal SPI-master nets
  wire :spi_tx_data,  8, init: 0
  wire :spi_tx_valid, 1, init: 0
  wire :spi_cs_hold,  1, init: 0
  wire :spi_tx_ready, 1
  wire :spi_rx_data,  8
  wire :spi_rx_valid, 1

  # Latched command operands + read result + byte-handshake phase
  wire :addr_reg,  8, init: 0
  wire :wdata_reg, 8, init: 0
  wire :mask_reg,  8, init: 0
  wire :rdata_reg, 8, init: 0
  wire :phase,     1, init: 0

  instance :spi, Hw.SPI.Master,
    CLK_FREQ: 48_000_000,
    SCK_FREQ: 4_000_000,
    clk:      :clk,
    rst:      :rst,
    tx_data:  :spi_tx_data,
    tx_valid: :spi_tx_valid,
    cs_hold:  :spi_cs_hold,
    tx_ready: :spi_tx_ready,
    rx_data:  :spi_rx_data,
    rx_valid: :spi_rx_valid,
    sck:      :sck,
    mosi:     :mosi,
    miso:     :miso,
    cs_n:     :cs_n

  comb do
    rdata = rdata_reg
  end

  # Each send-state presents one byte and runs a two-phase handshake with the
  # SPI master: phase 0 asserts tx_valid until the byte is accepted (tx_ready),
  # phase 1 waits for completion (rx_valid) before advancing. cs_hold is 1 for
  # every byte except the last of a transaction, so CS stays low across it.
  fsm :reg_state, clock: :clk, reset: :rst, init: :cmd_idle do
    defaults do
      spi_tx_valid = 0
      ready        = 0
      done         = 0
    end

    case reg_state do
      :cmd_idle ->
        ready = 1
        phase = 0
        on start do
          addr_reg  = addr
          wdata_reg = wdata
          mask_reg  = mask
          on op == 0, next: :reset_b0
          on op == 1, next: :wr_b0
          on op == 2, next: :rd_b0
          on op == 3, next: :bm_b0
        end

      # --- RESET: 0xC0 ---
      :reset_b0 ->
        spi_tx_data = 0xC0
        spi_cs_hold = 0
        on phase == 0 do
          spi_tx_valid = 1
          on spi_tx_ready do
            phase = 1
          end
        end
        on phase == 1 do
          on spi_rx_valid do
            phase = 0
            done  = 1
            next :cmd_idle
          end
        end

      # --- WRITE: 0x02, addr, wdata ---
      :wr_b0 ->
        spi_tx_data = 0x02
        spi_cs_hold = 1
        on phase == 0 do
          spi_tx_valid = 1
          on spi_tx_ready do
            phase = 1
          end
        end
        on phase == 1 do
          on spi_rx_valid do
            phase = 0
            next :wr_b1
          end
        end

      :wr_b1 ->
        spi_tx_data = addr_reg
        spi_cs_hold = 1
        on phase == 0 do
          spi_tx_valid = 1
          on spi_tx_ready do
            phase = 1
          end
        end
        on phase == 1 do
          on spi_rx_valid do
            phase = 0
            next :wr_b2
          end
        end

      :wr_b2 ->
        spi_tx_data = wdata_reg
        spi_cs_hold = 0
        on phase == 0 do
          spi_tx_valid = 1
          on spi_tx_ready do
            phase = 1
          end
        end
        on phase == 1 do
          on spi_rx_valid do
            phase = 0
            done  = 1
            next :cmd_idle
          end
        end

      # --- READ: 0x03, addr, 0x00 (value = 3rd MISO byte) ---
      :rd_b0 ->
        spi_tx_data = 0x03
        spi_cs_hold = 1
        on phase == 0 do
          spi_tx_valid = 1
          on spi_tx_ready do
            phase = 1
          end
        end
        on phase == 1 do
          on spi_rx_valid do
            phase = 0
            next :rd_b1
          end
        end

      :rd_b1 ->
        spi_tx_data = addr_reg
        spi_cs_hold = 1
        on phase == 0 do
          spi_tx_valid = 1
          on spi_tx_ready do
            phase = 1
          end
        end
        on phase == 1 do
          on spi_rx_valid do
            phase = 0
            next :rd_b2
          end
        end

      :rd_b2 ->
        spi_tx_data = 0x00
        spi_cs_hold = 0
        on phase == 0 do
          spi_tx_valid = 1
          on spi_tx_ready do
            phase = 1
          end
        end
        on phase == 1 do
          on spi_rx_valid do
            rdata_reg = spi_rx_data
            phase     = 0
            done      = 1
            next :cmd_idle
          end
        end

      # --- BIT MODIFY: 0x05, addr, mask, wdata ---
      :bm_b0 ->
        spi_tx_data = 0x05
        spi_cs_hold = 1
        on phase == 0 do
          spi_tx_valid = 1
          on spi_tx_ready do
            phase = 1
          end
        end
        on phase == 1 do
          on spi_rx_valid do
            phase = 0
            next :bm_b1
          end
        end

      :bm_b1 ->
        spi_tx_data = addr_reg
        spi_cs_hold = 1
        on phase == 0 do
          spi_tx_valid = 1
          on spi_tx_ready do
            phase = 1
          end
        end
        on phase == 1 do
          on spi_rx_valid do
            phase = 0
            next :bm_b2
          end
        end

      :bm_b2 ->
        spi_tx_data = mask_reg
        spi_cs_hold = 1
        on phase == 0 do
          spi_tx_valid = 1
          on spi_tx_ready do
            phase = 1
          end
        end
        on phase == 1 do
          on spi_rx_valid do
            phase = 0
            next :bm_b3
          end
        end

      :bm_b3 ->
        spi_tx_data = wdata_reg
        spi_cs_hold = 0
        on phase == 0 do
          spi_tx_valid = 1
          on spi_tx_ready do
            phase = 1
          end
        end
        on phase == 1 do
          on spi_rx_valid do
            phase = 0
            done  = 1
            next :cmd_idle
          end
        end
    end
  end
end
