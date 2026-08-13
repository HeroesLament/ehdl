defmodule Hw.Diag.Display do
  @moduledoc """
  LED diagnostic sequencer for USB enumeration debugging.

  Activated by btn[2] (FIRE2, active high). When inactive, passes
  through the normal LED value from the `normal_led` input.

  ## Frame sequence (~0.5s per frame, ~5s full cycle)

  D7 is solid in frame 0 (SYNC marker). D7 blinks (heartbeat) in all
  other frames so you can count them.

  ```
  Frame 0:  SYNC        D7=solid  D6-D0=0000000
  Frame 1:  dev_state   D7=~  D1-D0 = dev_state (0=default 1=addressed 2=configured)
  Frame 2:  ep0_state   D7=~  D1-D0 = ep0_state (0=idle 1=loading 2=waiting 3=data_out)
  Frame 3:  ep_in flags D7=~  D3=ep0_loaded D2=ep1_loaded D1=done_latch D0=nak_latch
  Frame 4:  pkt count   D7=~  D3-D0 = good RX packets received (wraps at 16)
  Frame 5:  sie_rx_state D7=~ D1-D0 = SIE rx_state when last sampled
  Frame 6:  phy activity D7=~ D3=rx_active D2=rx_valid D1=rx_se0 D0=tx_valid (sticky)
  Frame 7:  ep_out sigs  D7=~ D3=pkt_end D2=ep_out_valid D1=ep_out_setup D0=ep_in_ready (sticky)
  Frame 8:  ep_in loads  D7=~ D3-D0 = ep_in_loaded_count low 4 bits (how many times CDC armed SIE)
  Frame 9:  normal LED   D7-D0 = normal_led value (reference)
  ```

  All latches (sticky signals) are cleared at frame 0 (SYNC).

  ## Reading

  1. Hold btn[2]
  2. Wait for D7 solid with D6-D0 dark → Frame 0 (SYNC)
  3. Count frames after SYNC. D7 blinks as heartbeat to help count.
  4. Release btn[2] to return to normal mode.

  ## Clock domain note

  This module runs on clk_48. PHY signals and SIE ep_out signals are in
  clk_fast domain. Single-cycle pulses may be missed. The sticky latches
  help — any pulse that's caught gets held for the full frame display.
  """

  use Hw.Component

  clock :clk, freq: 48.0
  input  :rst, 1

  # Mode select
  input :btn_diag,   1   # active high — enter diagnostic mode

  # Normal LED passthrough
  input :normal_led, 8

  # CDC state (clk_48)
  input :dev_state,  2
  input :ep0_state,  2
  input :ep0_loaded, 1
  input :ep1_loaded, 1
  input :ep_in_done, 1   # pulse
  input :ep_in_nak,  1   # pulse

  # SIE endpoint out signals (clk_fast — may be 1-cycle pulses, use sticky latches)
  input :ep_out_pkt_end, 1
  input :ep_out_valid,   1
  input :ep_out_setup,   1
  input :ep_in_ready,    1   # SIE consumed a byte

  # PHY raw signals (clk_48 domain, pre-sync)
  input :phy_rx_active,  1
  input :phy_rx_valid,   1
  input :phy_rx_se0,     1
  input :phy_tx_valid,   1

  # SIE rx_state (synchronized to clk_48 in top)
  input :sie_rx_state,   2

  # SIE TX state for diagnosing handshake/data TX
  input :sie_tx_state,      3
  input :sie_send_handshake, 1

  # LED output
  output :led, 8

  # --- Timer: 4_000_000 cycles = 83ms at 48MHz ---
  wire :frame_timer,   22, init: 0
  wire :frame_idx,      4, init: 0   # 0-9
  wire :frame_tick,     1
  wire :heartbeat,      1

  # --- Sticky latches (cleared at SYNC frame 0) ---
  wire :done_latch,          1, init: 0
  wire :nak_latch,           1, init: 0
  wire :pkt_end_latch,       1, init: 0
  wire :ep_out_valid_latch,  1, init: 0
  wire :ep_out_setup_latch,  1, init: 0
  wire :ep_in_ready_latch,   1, init: 0
  wire :phy_rx_active_latch, 1, init: 0
  wire :phy_rx_valid_latch,  1, init: 0
  wire :phy_rx_se0_latch,    1, init: 0
  wire :phy_tx_valid_latch,  1, init: 0
  wire :send_handshake_latch, 1, init: 0  # did SIE ever arm a handshake?
  wire :sie_tx_ran_latch,     1, init: 0  # did SIE TX state machine ever run?

  # --- Counters ---
  wire :pkt_end_count,      4, init: 0   # good RX packets
  wire :ep_in_loaded_count, 4, init: 0   # times CDC armed SIE

  # --- Diag LED value ---
  wire :diag_led, 8

  # --- Padding wires ---
  wire :pad2, 2
  wire :pad3, 3
  wire :pad4, 4
  wire :pad5, 5
  wire :pad6, 6

  # --- Constants ---
  wire :zero,   1
  wire :one,    1
  wire :w4_0,   4
  wire :w4_9,   4
  wire :w22_0, 22

  wire :frame_timer_next,      22
  wire :frame_idx_next,         4
  wire :pkt_end_count_next,     4
  wire :ep_in_loaded_count_next, 4

  comb do
    zero   = 0
    one    = 1
    w4_0   = 0
    w4_9   = 9
    w22_0  = 0
    pad2   = 0
    pad3   = 0
    pad4   = 0
    pad5   = 0
    pad6   = 0

    frame_timer_next       = frame_timer + 1
    frame_idx_next         = frame_idx + 1
    pkt_end_count_next     = pkt_end_count + 1
    ep_in_loaded_count_next = ep_in_loaded_count + 1

    frame_tick = (frame_timer == 4_000_000)
    heartbeat  = frame_timer[21..21]

    hdl_case frame_idx do
      0 -> diag_led = 0b10000000
      1 -> diag_led = {heartbeat, pad5, dev_state}
      2 -> diag_led = {heartbeat, pad5, ep0_state}
      3 -> diag_led = {heartbeat, pad3, ep0_loaded, ep1_loaded, done_latch, nak_latch}
      4 -> diag_led = {heartbeat, pad3, pkt_end_count}
      5 -> diag_led = {heartbeat, pad4, sie_tx_state}
      6 -> diag_led = {heartbeat, pad3, phy_rx_active_latch, phy_rx_valid_latch, phy_rx_se0_latch, phy_tx_valid_latch}
      7 -> diag_led = {heartbeat, pad3, pkt_end_latch, ep_out_valid_latch, ep_out_setup_latch, ep_in_ready_latch}
      8 -> diag_led = {heartbeat, pad5, send_handshake_latch, sie_tx_ran_latch}
      _ -> diag_led = normal_led
    end

    led = if btn_diag, do: diag_led, else: normal_led
  end

  on :clk do
    if rst do
      frame_timer            = w22_0
      frame_idx              = w4_0
      done_latch             = zero
      nak_latch              = zero
      pkt_end_latch          = zero
      ep_out_valid_latch     = zero
      ep_out_setup_latch     = zero
      ep_in_ready_latch      = zero
      phy_rx_active_latch    = zero
      phy_rx_valid_latch     = zero
      phy_rx_se0_latch       = zero
      phy_tx_valid_latch     = zero
      send_handshake_latch   = zero
      sie_tx_ran_latch       = zero
      pkt_end_count          = 0
      ep_in_loaded_count     = 0
    else

      # Capture sticky events every cycle
      if ep_in_done,       do: done_latch             = one
      if ep_in_nak,        do: nak_latch              = one
      if ep_out_pkt_end,   do: pkt_end_latch          = one
      if ep_out_valid,     do: ep_out_valid_latch     = one
      if ep_out_setup,     do: ep_out_setup_latch     = one
      if ep_in_ready,      do: ep_in_ready_latch      = one
      if phy_rx_active,    do: phy_rx_active_latch    = one
      if phy_rx_valid,     do: phy_rx_valid_latch     = one
      if phy_rx_se0,       do: phy_rx_se0_latch       = one
      if phy_tx_valid,     do: phy_tx_valid_latch     = one
      if sie_send_handshake, do: send_handshake_latch = one
      if sie_tx_state != 0,  do: sie_tx_ran_latch     = one

      # Counters
      if ep_out_pkt_end,   do: pkt_end_count        = pkt_end_count_next
      if ep0_loaded,       do: ep_in_loaded_count   = ep_in_loaded_count_next

      # Advance frame timer
      if frame_tick do
        frame_timer = w22_0
        if frame_idx == w4_9 do
          frame_idx = w4_0
          # Clear all latches at SYNC
          done_latch           = zero
          nak_latch            = zero
          pkt_end_latch        = zero
          ep_out_valid_latch   = zero
          ep_out_setup_latch   = zero
          ep_in_ready_latch    = zero
          phy_rx_active_latch  = zero
          phy_rx_valid_latch   = zero
          phy_rx_se0_latch     = zero
          phy_tx_valid_latch   = zero
          send_handshake_latch = zero
          sie_tx_ran_latch     = zero
        else
          frame_idx = frame_idx_next
        end
      else
        frame_timer = frame_timer_next
      end

    end
  end

end
