defmodule HelloBoard.Top do
  @moduledoc """
  HelloBoard — USB2 to ESP32 serial bridge on ULX3S 85F.

  Single clock domain: clk_48 (48 MHz exact via PLL).
  PHY, SIE, CDCSerial, UART, ESP32 ProgCtrl, DiagDisplay all run on clk_48.
  No CDC crossings — matches every reference USB FS implementation.

  ## Reset architecture

  pll_locked → Hw.ResetSync (reset_style: :none, 1024-cycle hold) → rst

  ResetSync runs ungated by design — it IS the reset generator. Its clock
  domain declares reset_style: :none so the elaborator emits a bare
  always @(posedge clk_48) block for it, immune to the rst signal it produces.

  ## USB pad architecture

  E16/F16 — usb_fpga_dp/dn — LVCMOS33D differential input.
  D15/E15 — usb_fpga_bd_dp/dn — bidirectional BB tristates.
  B12/C12 — usb_fpga_pu_dp/dn — D+ pullup / D- pulldown control.
  """

  use Hw.Component

  clock :clk_25mhz, freq: 25.0
  clock :clk_48,    freq: 48.0, domain: :usb, reset: :rst, reset_style: :sync

  inout  :usb_fpga_bd_dp, 1
  inout  :usb_fpga_bd_dn, 1
  output :usb_fpga_pu_dp, 1
  output :usb_fpga_pu_dn, 1

  # ESP32 UART bridge
  output :wifi_rxd,   1
  input  :wifi_txd,   1
  output :wifi_en,    1
  output :wifi_gpio0, 1

  output :led,  8
  output :gn12, 1

  input  :btn1, 1
  input  :btn2, 1

  # Logic analyzer probe outputs — J1 header
  # RAW-BUS K-DETECT ORACLE: rx_active never rises on HW though gp0/gn0 (raw bus)
  # toggle. A K symbol (the PHY's idle->detect trigger) needs D+ low AND D- high.
  # Computed at top level from the raw bus — does NOT touch the PHY, so it cannot
  # affect enumeration. The two sticky pins (gp2/gn2) are the answer at a glance.
  # gp0 = dp_diff       (host D+ raw bus, straight off pad — trigger)
  # gn0 = dn_raw        (host D- raw bus, straight off pad)
  # gp1 = raw_dn_high   (live: raw D- high)
  # gn1 = raw_k         (live: raw K symbol = D+ low & D- high)
  # gp2 = lat_dn_high   (sticky: raw D- was EVER high)   <-- KEY: is D- even wired?
  # gn2 = lat_raw_k     (sticky: a raw K was EVER seen)   <-- KEY: does a K ever form?
  # gp3 = phy_rx_active (live: PHY declared a packet — should follow a K)
  # gn3 = usb_rx_state[0] (live: PHY RX state LSB, context)
  # GND = J1 pin 1 or 2.
  output :gp0, 1
  output :gn0, 1
  output :gp1, 1
  output :gn1, 1
  output :gp2, 1
  output :gn2, 1
  output :gp3, 1
  output :gn3, 1

  # Internal clocks and reset
  wire :clk_48,     1
  wire :pll_locked, 1
  wire :rst,        1

  # USB pad wiring
  wire :dp_diff,      1
  wire :phy_dp_tx,    1
  wire :phy_dn_tx,    1
  wire :phy_tx_en,    1
  wire :dn_raw,       1
  wire :dp_raw,       1
  wire :dp_diff_n,    1

  # PHY ↔ SIE signals — all clk_48, no CDC
  wire :phy_rx_valid,  1
  wire :phy_rx_data,   1
  wire :phy_rx_se0,    1
  wire :phy_rx_active, 1
  wire :phy_rx_bit0,   1   # PID bit-0 alignment strobe (PHY -> SIE)
  wire :phy_rx_pid_done, 1 # PID last-bit strobe (PHY -> SIE)
  wire :phy_tx_valid,  1
  wire :phy_tx_data,   1
  wire :phy_tx_se0,    1
  wire :phy_tx_ready,  1

  # SIE endpoint out → CDCSerial
  wire :sie_ep_out_data,    8
  wire :sie_ep_out_valid,   1
  wire :sie_ep_out_ep,      4
  wire :sie_ep_out_setup,   1
  wire :sie_ep_out_pkt_end, 1

  # CDCSerial → SIE endpoint in
  wire :sie_ep_in_ep,       4
  wire :sie_ep_in_pid,      8
  wire :sie_ep_in_data,     8
  wire :sie_ep_in_valid,    1
  wire :sie_ep_in_loaded,   1
  wire :sie_ep_in_ready,    1
  wire :sie_ep_in_done,     1
  wire :sie_ep_in_nak,      1

  # USB device address — set by CDCSerial on SET_ADDRESS, used by SIE
  # persist: :power_on_only — must survive USB bus resets, only clear at power-on
  wire :dev_addr,   7, init: 0

  # PLL second output — unused in single-domain design
  wire :_clk_unused,    1
  wire :_phy_tx_active, 1

  # UART bridge signals
  wire :cdc_rx_data,  8
  wire :cdc_rx_valid, 1
  wire :cdc_rx_ready, 1
  wire :cdc_tx_data,  8
  wire :cdc_tx_valid, 1
  wire :cdc_tx_ready, 1
  wire :dtr,          1
  wire :rts,          1

  # CDC state for diagnostics
  wire :cdc_dev_state,  2
  wire :cdc_ep0_state,  2
  wire :cdc_ep0_loaded, 1
  wire :cdc_ep1_loaded, 1
  wire :normal_led,     8

  # SIE internal state for diagnostics
  wire :usb_rx_state,        2
  wire :usb_tx_state,        3
  wire :usb_send_handshake,  1
  wire :usb_dbg_accept,      1

  # --- Hardware TX-arm oracle: sticky latches on the SETUP -> TX-arm chain ---
  # phy_dp_tx is FLAT on real hardware (device never transmits), while the host
  # sends SETUP+DATA0 forever. These latches capture how far ONE packet gets
  # before the transmit chain fails to arm. Routed to analyzer probe pins below.
  # Latched high on first occurrence, held forever (no clear) so a single capture
  # shows the deepest stage reached.
  wire :lat_rx_active,  1, init: 0   # PHY saw a packet
  wire :lat_pkt_end,    1, init: 0   # a SETUP/OUT DATA passed CRC16 (ACK precondition)
  wire :lat_accept,     1, init: 0   # a token passed CRC5 + addr-match
  wire :lat_tx_ran,     1, init: 0   # TX FSM left idle (device tried to transmit)

  # --- PHY front-end diagnostics (computed at TOP LEVEL from the raw bus) ---
  # rx_active never rises on HW though gp0/gn0 (raw dp_diff/dn_raw) toggle. A K symbol
  # (the idle->detect trigger inside the PHY) needs D+ low AND D- high. Rather than
  # instrument the PHY's internal filtered signals (which perturbs its timing), we
  # compute the same K test here from the already-exposed raw dp_diff/dn_raw. This is
  # a pure passive top-level observer — it cannot affect the PHY or enumeration.
  wire :raw_k,          1   # live: raw K symbol (dp_diff==0 and dn_raw==1)
  wire :raw_dn_high,    1   # live: raw D- high (dn_raw==1)
  wire :lat_raw_k,      1, init: 0   # sticky: a raw K was EVER seen
  wire :lat_dn_high,    1, init: 0   # sticky: raw D- was EVER high

  # D+ tristate — TX drive + RX readback via dp_diff
  # Using single-ended D15 readback for dp_diff (not LVCMOS33D E16):
  # During SE0, LVCMOS33D sees D+=D-=0V (differential=0) → undefined output.
  # Single-ended D15 readback sees 0V → reliably 0. SE0 detection requires this.
  tristate :dp_buf,
    io:     :usb_fpga_bd_dp,
    output: :phy_dp_tx,
    enable: :phy_tx_en,
    input:  :dp_diff

  # D- tristate — TX drive + SE0 detection via dn_raw readback
  tristate :dn_buf,
    io:     :usb_fpga_bd_dn,
    output: :phy_dn_tx,
    enable: :phy_tx_en,
    input:  :dn_raw

  # PLL — 48 MHz primary, second output unused
  instance :pll, ULX3S.PLL,
    CLKOP_DIV:    9,
    CLKOS_DIV:    2,
    CLKOP_CPHASE: 8,
    CLKOS_CPHASE: 1,
    clk_in:       :clk_25mhz,
    clk_out0:     :clk_48,
    clk_out1:     :_clk_unused,
    locked:       :pll_locked,
    phase_dir:    0,
    phase_step:   0

  # Reset synchronizer — holds rst high for 1024 cycles (~21µs) after PLL locks.
  # Uses reset_style: :none internally so it can't be gated by its own output.
  instance :rst_sync, Hw.ResetSync,
    HOLD_CYCLES: 1024,
    clk:         :clk_48,
    rst_in:      :pll_locked,
    rst_out:     :rst

  comb do
    gn12           = 0
    usb_fpga_pu_dn = 0

    cdc_ep0_loaded = sie_ep_in_loaded and sie_ep_in_ep == 0
    cdc_ep1_loaded = sie_ep_in_loaded and sie_ep_in_ep == 1

    # Raw K-symbol detection (top-level, from the raw bus — does NOT touch the PHY):
    # a K is D+ low AND D- high. If the host is signalling, raw_k must pulse; if
    # raw D- never goes high, no K exists and the PHY can never leave idle.
    raw_dn_high = (dn_raw == 1)
    raw_k       = (dp_diff == 0) and (dn_raw == 1)

    # Logic analyzer probes — raw-bus K-detect oracle (see header comment for mapping)
    gp0 = dp_diff                  # host D+ raw bus (trigger)
    gn0 = dn_raw                   # host D- raw bus
    gp1 = raw_dn_high              # live: raw D- high
    gn1 = raw_k                    # live: raw K symbol (D+ low & D- high)
    gp2 = lat_dn_high              # sticky: raw D- was EVER high  <-- KEY
    gn2 = lat_raw_k                # sticky: a raw K was EVER seen  <-- KEY
    gp3 = phy_rx_active            # live: PHY declared a packet (should follow K)
    gn3 = usb_rx_state[0..0]       # live: PHY RX state LSB (context)

    normal_led = {
      pll_locked,
      sie_ep_out_pkt_end,
      sie_ep_out_valid,
      sie_ep_out_setup,
      cdc_rx_valid,
      cdc_tx_valid,
      cdc_dev_state[1..1],
      cdc_dev_state[0..0]
    }
  end

  # --- Hardware TX-arm oracle: sticky-latch capture ---
  # Each latch goes high the first time its stage fires and is held forever (no
  # clear), so a single analyzer capture shows the deepest stage the SETUP->TX-arm
  # chain reached. Cleared only by rst (power-up / bus reset hold).
  on :clk_48 do
    if rst do
      lat_rx_active = 0
      lat_pkt_end   = 0
      lat_accept    = 0
      lat_tx_ran    = 0
      lat_raw_k     = 0
      lat_dn_high   = 0
    else
      if phy_rx_active,      do: lat_rx_active = 1
      if sie_ep_out_pkt_end, do: lat_pkt_end   = 1
      if usb_dbg_accept,     do: lat_accept    = 1
      if usb_tx_state != 0,  do: lat_tx_ran    = 1
      # Raw-bus K-detect (computed from dp_diff/dn_raw, does not touch the PHY):
      if raw_k,              do: lat_raw_k     = 1
      if raw_dn_high,        do: lat_dn_high   = 1
    end
  end

  instance :phy, Hw.USB.FSPhy,
    clk_48mhz:   :clk_48,
    rst:         :rst,
    dp_diff:     :dp_diff,
    dn_raw:      :dn_raw,
    dp_tx:       :phy_dp_tx,
    dn_tx:       :phy_dn_tx,
    tx_en:       :phy_tx_en,
    pu:          :usb_fpga_pu_dp,
    rx_valid:    :phy_rx_valid,
    rx_data:     :phy_rx_data,
    rx_se0:      :phy_rx_se0,
    rx_active:   :phy_rx_active,
    rx_bit0:     :phy_rx_bit0,
    rx_pid_done: :phy_rx_pid_done,
    tx_valid:    :phy_tx_valid,
    tx_data:     :phy_tx_data,
    tx_se0:      :phy_tx_se0,
    tx_ready:    :phy_tx_ready,
    tx_active:   :_phy_tx_active

  instance :sie, Hw.USB.SIE,
    clk_48mhz:       :clk_48,
    rst:             :rst,
    dev_addr:        :dev_addr,
    phy_rx_valid:    :phy_rx_valid,
    phy_rx_data:     :phy_rx_data,
    phy_rx_se0:      :phy_rx_se0,
    phy_rx_active:   :phy_rx_active,
    phy_rx_bit0:     :phy_rx_bit0,
    phy_tx_valid:    :phy_tx_valid,
    phy_tx_data:     :phy_tx_data,
    phy_tx_se0:      :phy_tx_se0,
    phy_tx_ready:    :phy_tx_ready,
    ep_out_data:     :sie_ep_out_data,
    ep_out_valid:    :sie_ep_out_valid,
    ep_out_ep:       :sie_ep_out_ep,
    ep_out_setup:    :sie_ep_out_setup,
    ep_out_pkt_end:  :sie_ep_out_pkt_end,
    ep_in_ep:        :sie_ep_in_ep,
    ep_in_pid:       :sie_ep_in_pid,
    ep_in_data:      :sie_ep_in_data,
    ep_in_valid:     :sie_ep_in_valid,
    ep_in_loaded:    :sie_ep_in_loaded,
    ep_in_ready:     :sie_ep_in_ready,
    ep_in_done:      :sie_ep_in_done,
    ep_in_nak:       :sie_ep_in_nak,
    rx_state_out:       :usb_rx_state,
    tx_state_out:       :usb_tx_state,
    send_handshake_out: :usb_send_handshake,
    dbg_accept_out:     :usb_dbg_accept

  instance :cdc, Hw.USB.CDCSerial,
    clk_48mhz:       :clk_48,
    rst:             :rst,
    ep_out_data:     :sie_ep_out_data,
    ep_out_valid:    :sie_ep_out_valid,
    ep_out_ep:       :sie_ep_out_ep,
    ep_out_setup:    :sie_ep_out_setup,
    ep_out_pkt_end:  :sie_ep_out_pkt_end,
    ep_in_ep:        :sie_ep_in_ep,
    ep_in_pid:       :sie_ep_in_pid,
    ep_in_data:      :sie_ep_in_data,
    ep_in_valid:     :sie_ep_in_valid,
    ep_in_loaded:    :sie_ep_in_loaded,
    ep_in_ready:     :sie_ep_in_ready,
    ep_in_done:      :sie_ep_in_done,
    ep_in_nak:       :sie_ep_in_nak,
    dev_addr:        :dev_addr,
    rx_data:         :cdc_rx_data,
    rx_valid:        :cdc_rx_valid,
    rx_ready:        :cdc_rx_ready,
    tx_data:         :cdc_tx_data,
    tx_valid:        :cdc_tx_valid,
    tx_ready:        :cdc_tx_ready,
    dtr:             :dtr,
    rts:             :rts,
    dev_state:       :cdc_dev_state,
    ep0_state:       :cdc_ep0_state

  instance :uart_tx, Hw.UART.TX,
    CLK_FREQ:  48_000_000,
    BAUD_RATE: 115_200,
    clk:       :clk_48,
    rst:       :rst,
    data:      :cdc_rx_data,
    valid:     :cdc_rx_valid,
    ready:     :cdc_rx_ready,
    txd:       :wifi_rxd

  instance :uart_rx, Hw.UART.RX,
    CLK_FREQ:  48_000_000,
    BAUD_RATE: 115_200,
    clk:       :clk_48,
    rst:       :rst,
    rxd:       :wifi_txd,
    data:      :cdc_tx_data,
    valid:     :cdc_tx_valid,
    ready:     :cdc_tx_ready

  instance :prog, Hw.ESP32.ProgCtrl,
    CLK_FREQ:      48_000_000,
    RESET_HOLD_US: 100,
    clk:           :clk_48,
    rst:           :rst,
    dtr:           :dtr,
    rts:           :rts,
    esp_en:        :wifi_en,
    esp_gpio0:     :wifi_gpio0

  instance :diag, Hw.Diag.Display,
    clk:             :clk_48,
    rst:             :rst,
    btn_diag:        :btn2,
    normal_led:      :normal_led,
    dev_state:       :cdc_dev_state,
    ep0_state:       :cdc_ep0_state,
    ep0_loaded:      :cdc_ep0_loaded,
    ep1_loaded:      :cdc_ep1_loaded,
    ep_in_done:      :sie_ep_in_done,
    ep_in_nak:       :sie_ep_in_nak,
    ep_out_pkt_end:  :sie_ep_out_pkt_end,
    ep_out_valid:    :sie_ep_out_valid,
    ep_out_setup:    :sie_ep_out_setup,
    ep_in_ready:     :sie_ep_in_ready,
    phy_rx_active:   :phy_rx_active,
    phy_rx_valid:    :phy_rx_valid,
    phy_rx_se0:      :phy_rx_se0,
    phy_tx_valid:    :phy_tx_valid,
    sie_rx_state:      :usb_rx_state,
    sie_tx_state:      :usb_tx_state,
    sie_send_handshake: :usb_send_handshake,
    led:               :led
end
