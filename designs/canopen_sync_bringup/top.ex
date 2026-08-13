defmodule CanopenSyncBringup.Top do
  @moduledoc """
  CANopen SYNC bring-up — first silicon slice of the CANopen cyclic engine.

  Standalone (no USB, no ESP32): 25 MHz -> PLL -> 48 MHz, a controller resets the
  MCP2515, configures it for **NORMAL mode, 500 kbps** (8 MHz crystal), then
  transmits a CANopen **SYNC frame** (COB-ID 0x080, DLC 0) on the real bus at a
  visible ~10 Hz cadence. This proves the layer *above* `Hw.CAN.MCP2515` —
  configure(NORMAL) + send_frame — against real silicon, on the way to the full
  cyclic engine (SYNC + RPDO setpoints down / TPDO actuals up).

  It is a deliberate extension of `Mcp2515Bringup.Top`: same PLL/reset/report
  scaffold and the same register-engine handshake. The config ROM is identical
  except the final `CANCTRL` step selects REQOP=000 (NORMAL) instead of 0x40
  (loopback), so the frames go out on the wire, not into an internal loopback.

  ## Oracle (no sim sign-off — silicon only)

    * 3-way bus: this FPGA's MCP2515, a CANable on the PC (`can_ex`, independent
      3rd-party observer + ACK node), and the drive(s). Green = the CANable sees
      standard ID `0x080`, DLC 0, arriving at ~10 Hz. The CANable ACKing also
      keeps this transmitter out of error-passive before a drive is present.
    * US1 FTDI serial (`/dev/cu.usbserial-*` @ 9600): `Hw.Diag.SerialReport`
      streams six bits per line:
        b0 = pll_locked        b3 = sync_count[0]  (SYNC heartbeat, toggles/frame)
        b1 = mcp_ready         b4 = sync_count[1]
        b2 = config_done       b5 = sync_count[2]
      After configure, b2 latches 1 and b3..b5 count up as SYNCs are emitted.
    * LEDs mirror the low byte of the SYNC counter (visible cadence).

  ## Wiring (MCP2515 on the ULX3S GPIO header — same as mcp2515_bringup)

      gn13 (G5) -> SCK      gp13 (H4) -> SI/MOSI
      gn12 (F3) <- SO/MISO  gp12 (G3) -> CS
      + common GND. Power the MCP2515 module at 3.3 V.

  ## Config sequence (8 MHz crystal, 500 kbps — DS20001801K §5)

      step op      reg                 value
      0    WRITE   CNF1  (0x2A)        0x00
      1    WRITE   CNF2  (0x29)        0x90
      2    WRITE   CNF3  (0x28)        0x02
      3    WRITE   RXB0CTRL (0x60)     0x60   accept-all (RXM=11)
      4    BITMOD  CANCTRL  (0x0F)     0x08 / mask 0x08   one-shot mode
      5    WRITE   CANINTF  (0x2C)     0x00   clear flags
      6    BITMOD  CANCTRL  (0x0F)     0x00 / mask 0xE0   REQOP = NORMAL

  ## SYNC frame (COB-ID 0x080, DLC 0 — CiA 301)

  Standard 11-bit ID 0x080 -> TXB0SIDH = ID[10:3] = 0x10, TXB0SIDL = ID[2:0]<<5 = 0x00.

      step op      reg                 value
      0    WRITE   TXB0SIDH (0x31)     0x10
      1    WRITE   TXB0SIDL (0x32)     0x00
      2    WRITE   TXB0DLC  (0x35)     0x00   DLC = 0
      3    BITMOD  TXB0CTRL (0x30)     0x08 / mask 0x08   TXREQ -> request send
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

  # Config-table decode (indexed by cfg_step)
  wire :cfg_step,  3, init: 0
  wire :cfg_op,    2
  wire :cfg_addr,  8
  wire :cfg_wdata, 8
  wire :cfg_mask,  8

  # SYNC-frame-table decode (indexed by send_step)
  wire :send_step,  2, init: 0
  wire :send_op,    2
  wire :send_addr,  8
  wire :send_wdata, 8
  wire :send_mask,  8

  # Status / cadence
  wire :config_done, 1, init: 0
  wire :sync_count,  8, init: 0
  wire :wait_cnt,   24, init: 0

  # SerialReport bits
  wire :rb0, 1
  wire :rb1, 1
  wire :rb2, 1
  wire :rb3, 1
  wire :rb4, 1
  wire :rb5, 1

  comb do
    zero1 = 0
    led   = sync_count

    rb0 = pll_locked
    rb1 = mcp_ready
    rb2 = config_done
    rb3 = sync_count[0..0]
    rb4 = sync_count[1..1]
    rb5 = sync_count[2..2]

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
      <<6::3>> -> cfg_wdata = 0x00   # REQOP = 000 (NORMAL) — the only change vs loopback
      <<_::3>> -> cfg_wdata = 0x00
    end

    hdl_case <<cfg_step::3>> do
      <<4::3>> -> cfg_mask = 0x08
      <<6::3>> -> cfg_mask = 0xE0
      <<_::3>> -> cfg_mask = 0x00
    end

    # SYNC frame ROM: send_step -> {op, addr, wdata, mask}.
    hdl_case <<send_step::2>> do
      <<3::2>> -> send_op = 3   # BITMOD (TXREQ)
      <<_::2>> -> send_op = 1   # WRITE
    end

    hdl_case <<send_step::2>> do
      <<0::2>> -> send_addr = 0x31   # TXB0SIDH
      <<1::2>> -> send_addr = 0x32   # TXB0SIDL
      <<2::2>> -> send_addr = 0x35   # TXB0DLC
      <<_::2>> -> send_addr = 0x30   # TXB0CTRL
    end

    hdl_case <<send_step::2>> do
      <<0::2>> -> send_wdata = 0x10   # ID[10:3] of 0x080
      <<3::2>> -> send_wdata = 0x08   # TXREQ bit
      <<_::2>> -> send_wdata = 0x00   # SIDL / DLC
    end

    hdl_case <<send_step::2>> do
      <<3::2>> -> send_mask = 0x08    # TXREQ mask
      <<_::2>> -> send_mask = 0x00
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
    BYTE_CYCLES: 60_000,   # one 9600-baud frame @48MHz
    clk: :clk_48,
    rst: :rst,
    b0:  :rb0,
    b1:  :rb1,
    b2:  :rb2,
    b3:  :rb3,
    b4:  :rb4,
    b5:  :rb5,
    txd: :ftdi_rxd

  # Controller: settle -> RESET -> settle -> walk config -> then loop forever
  # emitting a SYNC frame every ~100 ms. Each MCP op uses the hold-until-busy
  # handshake: assert start until the engine drops ready (accepted), await done.
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
            config_done = 1
            wait_cnt    = 0
            next :sync_gap
          end
          on :else do
            cfg_step = cfg_step + 1
            next :issue_cfg
          end
        end

      # Cadence gap (~100 ms @ 48 MHz), then emit one SYNC frame.
      :sync_gap ->
        wait_cnt = wait_cnt + 1
        on wait_cnt == 4_800_000 do
          send_step = 0
          next :issue_send
        end

      :issue_send ->
        mcp_op    = send_op
        mcp_addr  = send_addr
        mcp_wdata = send_wdata
        mcp_mask  = send_mask
        mcp_start = 1
        on mcp_ready == 0, next: :wait_send

      :wait_send ->
        on mcp_done do
          on send_step == 3 do
            sync_count = sync_count + 1
            wait_cnt   = 0
            next :sync_gap
          end
          on :else do
            send_step = send_step + 1
            next :issue_send
          end
        end
    end
  end
end
