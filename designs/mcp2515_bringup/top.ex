defmodule Mcp2515Bringup.Top do
  @moduledoc """
  MCP2515 bring-up design — the first silicon oracle for `Hw.CAN.MCP2515`.

  Standalone (no USB, no ESP32): the 25 MHz board clock is PLL'd to 48 MHz, a
  small controller resets the MCP2515 over SPI and then continuously reads
  CANSTAT (0x0E), and the result is surfaced two ways so a bare board tells you
  whether the SPI master + register engine actually work against real silicon:

    * US1 FTDI serial (ftdi_rxd, /dev/cu.usbserial-*): `Hw.Diag.SerialReport`
      streams six bits per line as ASCII `b0..b5` + CRLF. Mapping:
        b0 b1 b2 = CANSTAT[7] [6] [5]  = OPMOD (operating mode)
        b3       = got_read            = a CANSTAT read has completed
        b4       = mcp_ready           = register engine idle/alive
        b5       = pll_locked          = 48 MHz clock alive
      A healthy post-reset chip in **configuration mode** reads CANSTAT = 0x80,
      i.e. OPMOD = 0b100, so the line begins `100...`. Expected: `100111`.
    * LEDs mirror the full CANSTAT byte (led = CANSTAT): 0x80 lights only LED7.

  ## Wiring (MCP2515 moved from the CH347 to the ULX3S GPIO header)

      gn13 (G5) -> SCK      gp13 (H4) -> SI/MOSI
      gn12 (F3) <- SO/MISO  gp12 (G3) -> CS
      + common GND. Power the MCP2515 module at 3.3 V (ULX3S GPIO is 3.3 V —
      a 5 V module's SO would over-drive gp2).

  Reuses the stock ULX3S board LPF: port names match its COMP names
  (clk_25mhz, ftdi_rxd, led, gp0..gp3), so no design-specific pin file.
  """

  use Hw.Component

  clock :clk_25mhz, freq: 25.0
  clock :clk_48, freq: 48.0, domain: :sys, reset: :rst, reset_style: :sync

  output :ftdi_rxd, 1
  output :led,      8
  output :gn13,      1   # SCK
  output :gp13,      1   # MOSI (SI)
  input  :gn12,      1   # MISO (SO)
  output :gp12,      1   # CS

  # PLL / reset nets
  wire :pll_locked,  1
  wire :clk_48,      1   # PLL output net (also declared as a clock above); the wire makes it internal, not a port
  wire :_clk_unused, 1
  wire :rst,         1
  wire :zero1,       1
  wire :dummy_pu,    1
  wire :dummy_rc,    4

  # MCP2515 register-engine command interface
  wire :mcp_op,    2, init: 0
  wire :mcp_addr,  8, init: 0
  wire :mcp_wdata, 8, init: 0
  wire :mcp_mask,  8, init: 0
  wire :mcp_start, 1, init: 0
  wire :mcp_ready, 1
  wire :mcp_done,  1
  wire :mcp_rdata, 8

  # Latched read result + status, and a shared delay counter
  wire :canstat,  8, init: 0
  wire :got_read, 1, init: 0
  wire :wait_cnt, 24, init: 0

  # CANSTAT mode bits broken out for the serial reporter
  wire :cs7, 1
  wire :cs6, 1
  wire :cs5, 1

  comb do
    zero1 = 0
    led   = canstat
    cs7   = canstat[7..7]
    cs6   = canstat[6..6]
    cs5   = canstat[5..5]
  end

  instance :pll, ULX3S.PLL,
    CLKOP_DIV:    9,
    CLKOS_DIV:    2,
    CLKOP_CPHASE: 8,
    CLKOS_CPHASE: 1,
    clk_in:    :clk_25mhz,
    clk_out0:  :clk_48,
    clk_out1:  :_clk_unused,
    locked:    :pll_locked,
    phase_dir: 0,
    phase_step: 0

  # Power-on reset generator (USB re-enum inputs tied off — we only want rst).
  instance :reset_gen, Hw.ReEnum,
    HOLD_CYCLES:  2_400_000,
    clk:          :clk_48,
    pll_locked:   :pll_locked,
    btn:          :zero1,
    cmd_pulse:    :zero1,
    rst:          :rst,
    pu_drop:      :dummy_pu,
    reenum_count: :dummy_rc

  instance :mcp, Hw.CAN.MCP2515,
    CLK_FREQ: 48_000_000,
    SCK_FREQ: 4_000_000,
    clk:   :clk_48,
    rst:   :rst,
    op:    :mcp_op,
    addr:  :mcp_addr,
    wdata: :mcp_wdata,
    mask:  :mcp_mask,
    start: :mcp_start,
    ready: :mcp_ready,
    done:  :mcp_done,
    rdata: :mcp_rdata,
    sck:   :gn13,
    mosi:  :gp13,
    miso:  :gn12,
    cs_n:  :gp12

  instance :report, Hw.Diag.SerialReport,
    BYTE_CYCLES: 60_000,   # one 9600-baud frame @48MHz (default 6000 is for a faster baud)
    clk: :clk_48,
    rst: :rst,
    b0:  :cs7,
    b1:  :cs6,
    b2:  :cs5,
    b3:  :got_read,
    b4:  :mcp_ready,
    b5:  :pll_locked,
    txd: :ftdi_rxd

  # Controller: settle -> RESET the MCP2515 -> settle -> loop reading CANSTAT.
  # Each command uses a hold-until-busy handshake: assert start until the engine
  # drops ready (accepted), then wait for done. start defaults to 0 elsewhere so
  # the engine never re-triggers on a completed transaction.
  fsm :ctrl, clock: :clk_48, reset: :rst, init: :settle do
    defaults do
      mcp_start = 0
    end

    case ctrl do
      :settle ->
        wait_cnt = wait_cnt + 1
        on wait_cnt == 2_400_000, next: :issue_reset

      :issue_reset ->
        mcp_op    = 0
        mcp_start = 1
        on mcp_ready == 0 do
          wait_cnt = 0
          next :wait_reset
        end

      :wait_reset ->
        on mcp_done, next: :post_reset

      :post_reset ->
        wait_cnt = wait_cnt + 1
        on wait_cnt == 2_400_000, next: :issue_read

      :issue_read ->
        mcp_op   = 2
        mcp_addr = 0x0E
        mcp_start = 1
        on mcp_ready == 0, next: :wait_read

      :wait_read ->
        on mcp_done do
          canstat  = mcp_rdata
          got_read = 1
          wait_cnt = 0
          next :gap
        end

      :gap ->
        wait_cnt = wait_cnt + 1
        on wait_cnt == 4_800_000, next: :issue_read
    end
  end
end
