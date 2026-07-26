defmodule CanControllerBringup.Top do
  @moduledoc """
  Bring-up for the soft CAN controller — `Hw.CAN.Controller` driving a bare
  transceiver, no MCP2515 anywhere in the path.

  25 MHz -> PLL -> 48 MHz. After reset the design transmits a CANopen SYNC frame
  (COB-ID 0x080, DLC 0) about every 100 ms and reports controller status out the
  US1 FTDI serial port. Everything the core can tell you about its own health is
  on those six bits.

  ## Wiring (SN65HVD230 on the ULX3S GPIO header)

      gp13 (H4) -> D  (transceiver driver input, our TX)
      gn12 (F3) <- R  (transceiver receiver output, our RX)
      + common GND, transceiver at 3.3 V
      Rs (pin 8) to GND for high-speed mode
      120 ohm at each END of the bus only

  ## Oracle (silicon, no simulation sign-off)

  Three-way bus: this FPGA's soft core, the MCP2515 path, and a CANable on the
  PC. Green means both independent witnesses see standard ID 0x080, DLC 0, at
  ~10 Hz, and `tx_done` is latching here.

      b0 = pll_locked     expect 1
      b1 = tx_done_seen   expect 1   sticky: a frame was transmitted AND acked
      b2 = rx_valid_seen             sticky: a frame was received and passed CRC
      b3 = err_passive               expect 0 with a healthy bus
      b4 = bus_off                   expect 0
      b5 = tec[0]                    error counter activity

  Alone on the bus with no other node, the expected result inverts and is just
  as informative: nothing acknowledges, so b1 stays 0, TEC climbs by 8 per
  attempt, b3 lights at 128 and b4 at 256. Timing that climb is the cheapest
  proof the fault confinement is real.
  """

  use Hw.Component

  clock :clk_25mhz, freq: 25.0
  clock :clk_48, freq: 48.0, domain: :sys, reset: :rst, reset_style: :sync

  output :ftdi_rxd, 1
  output :led,      8
  output :gp13,     1   # -> transceiver D (CAN TX)
  input  :gn12,     1   # <- transceiver R (CAN RX)

  wire :pll_locked,  1
  wire :clk_48,      1
  wire :_clk_unused, 1
  wire :rst,         1
  wire :zero1,       1
  wire :dummy_pu,    1
  wire :dummy_rc,    4

  # Controller interface
  wire :can_tx,      1
  wire :tx_req,      1, init: 0
  wire :tx_id,      11
  wire :tx_dlc,      4
  wire :tx_data,    64
  wire :tx_busy,     1
  wire :tx_done,     1
  wire :tx_lost,     1
  wire :rx_id,      11
  wire :rx_dlc,      4
  wire :rx_data,    64
  wire :rx_valid,    1
  wire :rx_rtr,      1
  wire :rx_ext,      1
  wire :tec,         9
  wire :rec,         9
  wire :err_passive, 1
  wire :bus_off,     1
  wire :err_pulse,   1

  # Cadence and sticky status
  # NB: named `send_gap`, not `gap_cnt` — a top-level wire whose name matches a
  # sub-instance's internal signal (SerialReport has its own `gap_cnt`) gets
  # merged by the flattener into one double-driven register.
  wire :send_gap,      23, init: 0
  wire :tx_done_seen,   1, init: 0
  wire :rx_valid_seen,  1, init: 0
  wire :frame_cnt,      8, init: 0

  wire :rb0, 1
  wire :rb1, 1
  wire :rb2, 1
  wire :rb3, 1
  wire :rb4, 1
  wire :rb5, 1

  comb do
    zero1 = 0

    # CANopen SYNC: COB-ID 0x080, no data.
    tx_id   = 0x080
    tx_dlc  = 0
    tx_data = 0

    gp13 = can_tx

    rb0 = pll_locked
    rb1 = tx_done_seen
    rb2 = rx_valid_seen
    rb3 = err_passive
    rb4 = bus_off
    rb5 = tec[0..0]

    led = {frame_cnt[3..0], bus_off, err_passive, rx_valid_seen, tx_done_seen}
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

  instance :can, Hw.CAN.Controller,
    clk:         :clk_48,
    rst:         :rst,
    rx:          :gn12,
    tx:          :can_tx,
    tx_req:      :tx_req,
    tx_id:       :tx_id,
    tx_dlc:      :tx_dlc,
    tx_data:     :tx_data,
    tx_busy:     :tx_busy,
    tx_done:     :tx_done,
    tx_lost:     :tx_lost,
    rx_id:       :rx_id,
    rx_dlc:      :rx_dlc,
    rx_data:     :rx_data,
    rx_valid:    :rx_valid,
    rx_rtr:      :rx_rtr,
    rx_ext:      :rx_ext,
    tec:         :tec,
    rec:         :rec,
    err_passive: :err_passive,
    bus_off:     :bus_off,
    err_pulse:   :err_pulse

  instance :report, Hw.Diag.SerialReport,
    BYTE_CYCLES: 60_000,
    clk: :clk_48,
    rst: :rst,
    b0:  :rb0,
    b1:  :rb1,
    b2:  :rb2,
    b3:  :rb3,
    b4:  :rb4,
    b5:  :rb5,
    txd: :ftdi_rxd

  on :clk_48 do
    if rst do
      send_gap      = 0
      tx_req        = 0
      tx_done_seen  = 0
      rx_valid_seen = 0
      frame_cnt     = 0
    else
      # Sticky evidence that each direction actually worked.
      if tx_done do
        tx_done_seen = 1
        frame_cnt    = frame_cnt + 1
      end

      if rx_valid do
        rx_valid_seen = 1
      end

      # Request a frame roughly every 100 ms. Hold the request until the core
      # takes it, then drop it so exactly one frame goes per gap.
      if tx_busy do
        tx_req   = 0
        send_gap = 0
      else
        if send_gap == 4_800_000 do
          tx_req = 1
        else
          send_gap = send_gap + 1
        end
      end
    end
  end
end
