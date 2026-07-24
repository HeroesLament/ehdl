defmodule Mcp2515Bringup.Top do
  @moduledoc """
  MCP2515 bring-up design — silicon oracle for `Hw.CAN.MCP2515`.

  Standalone (no USB, no ESP32): 25 MHz -> PLL -> 48 MHz, a controller resets
  the MCP2515 over SPI, configures it (bit timing, accept-all RX, one-shot,
  clear interrupts), requests **loopback** mode, then continuously reads CANSTAT
  and reports it, so a bare board tells you whether the SPI master + register
  engine + configure/set-mode sequences work against real silicon.

    * US1 FTDI serial (ftdi_rxd, /dev/cu.usbserial-* @ 9600): `Hw.Diag.SerialReport`
      streams six bits per line as ASCII `b0..b5` + CRLF. Mapping:
        b0 b1 b2 = CANSTAT[7] [6] [5]  = OPMOD (operating mode)
        b3       = got_read            = a CANSTAT read has completed
        b4       = mcp_ready           = register engine idle/alive
        b5       = pll_locked          = 48 MHz clock alive
      Reset-only power-on is config mode (0x80 -> OPMOD 100). After the configure
      + set-loopback sequence the chip should report **loopback** mode
      (CANSTAT 0x40 -> OPMOD 010), so lines read `010111`.
    * LEDs mirror the full CANSTAT byte (led = CANSTAT): 0x40 lights only LED6.

  ## Wiring (MCP2515 on the ULX3S GPIO header)

      gn13 (G5) -> SCK      gp13 (H4) -> SI/MOSI
      gn12 (F3) <- SO/MISO  gp12 (G3) -> CS
      + common GND. Power the MCP2515 module at 3.3 V (ULX3S GPIO is 3.3 V).

  Reuses the stock ULX3S board LPF (port names match its COMP names).

  ## Config sequence (8 MHz crystal, 500 kbps — DS20001801K §5)

      step op      reg                 value
      0    WRITE   CNF1  (0x2A)        0x00
      1    WRITE   CNF2  (0x29)        0x90
      2    WRITE   CNF3  (0x28)        0x02
      3    WRITE   RXB0CTRL (0x60)     0x60   accept-all (RXM=11)
      4    BITMOD  CANCTRL  (0x0F)     0x08 / mask 0x08   one-shot mode
      5    WRITE   CANINTF  (0x2C)     0x00   clear flags
      6    BITMOD  CANCTRL  (0x0F)     0x40 / mask 0xE0   REQOP = loopback
  """

  use Hw.Component

  clock :clk_25mhz, freq: 25.0
  clock :clk_48, freq: 48.0, domain: :sys, reset: :rst, reset_style: :sync

  output :ftdi_rxd, 1
  output :led,      8
  output :gn13,     1   # SCK
  output :gp13,     1   # MOSI (SI)
  input  :gn12,     1   # MISO (SO)
  output :gp12,     1   # CS

  # PLL / reset nets
  wire :pll_locked,  1
  wire :clk_48,      1   # PLL output net (also declared as a clock above)
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

  # Config-table decode (indexed by cfg_step) + latched read result + status
  wire :cfg_step,  3, init: 0
  wire :cfg_op,    2
  wire :cfg_addr,  8
  wire :cfg_wdata, 8
  wire :cfg_mask,  8
  wire :canstat,   8, init: 0
  wire :got_read,  1, init: 0
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

    # Config ROM: cfg_step -> {op, addr, wdata, mask}. op 1 = WRITE, 3 = BITMOD.
    hdl_case <<cfg_step::3>> do
      <<4::3>> -> cfg_op = 3
      <<6::3>> -> cfg_op = 3
      <<_::3>> -> cfg_op = 1
    end

    hdl_case <<cfg_step::3>> do
      <<0::3>> -> cfg_addr = 0x2A
      <<1::3>> -> cfg_addr = 0x29
      <<2::3>> -> cfg_addr = 0x28
      <<3::3>> -> cfg_addr = 0x60
      <<4::3>> -> cfg_addr = 0x0F
      <<5::3>> -> cfg_addr = 0x2C
      <<6::3>> -> cfg_addr = 0x0F
      <<_::3>> -> cfg_addr = 0x00
    end

    hdl_case <<cfg_step::3>> do
      <<0::3>> -> cfg_wdata = 0x00
      <<1::3>> -> cfg_wdata = 0x90
      <<2::3>> -> cfg_wdata = 0x02
      <<3::3>> -> cfg_wdata = 0x60
      <<4::3>> -> cfg_wdata = 0x08
      <<5::3>> -> cfg_wdata = 0x00
      <<6::3>> -> cfg_wdata = 0x40
      <<_::3>> -> cfg_wdata = 0x00
    end

    hdl_case <<cfg_step::3>> do
      <<4::3>> -> cfg_mask = 0x08
      <<6::3>> -> cfg_mask = 0xE0
      <<_::3>> -> cfg_mask = 0x00
    end
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

  # Controller: settle -> RESET -> settle -> walk config table -> loop reading
  # CANSTAT. Each MCP op uses a hold-until-busy handshake: assert start until the
  # engine drops ready (accepted), then wait for done.
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
        on wait_cnt == 2_400_000 do
          cfg_step = 0
          next :issue_cfg
        end

      # Walk the config table: issue reg[cfg_step], advance until step 6 done.
      :issue_cfg ->
        mcp_op    = cfg_op
        mcp_addr  = cfg_addr
        mcp_wdata = cfg_wdata
        mcp_mask  = cfg_mask
        mcp_start = 1
        on mcp_ready == 0, next: :wait_cfg

      :wait_cfg ->
        on mcp_done do
          on cfg_step == 6 do
            wait_cnt = 0
            next :issue_read
          end
          on :else do
            cfg_step = cfg_step + 1
            next :issue_cfg
          end
        end

      # Poll CANSTAT forever — should read 0x40 (loopback) after configure.
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
