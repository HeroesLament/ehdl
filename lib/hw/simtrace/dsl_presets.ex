defmodule Hw.Simtrace.DSL.Presets do
  @moduledoc """
  Ready-made channel maps for `Hw.Simtrace.DSL.export/4`.

  Signal names are the elaborated prefix form as they appear in each entity's
  `reg_state` map — confirmed by inspecting `Hw.Simtrace.Query.timeline/3`.
  Run `hd(Hw.Simtrace.Query.timeline(st, :entity, [])).state |> Map.keys()` to
  find signal names for a new design.
  """

  @doc """
  16-channel map with host-side D+/D- on ch0/ch1 for USB decoder.

  Use this when you want to attach the DSView USB Full Speed decoder
  to decode the host stimulus packets driven by `Hw.Sim.USBHost`.

  Channels 0-1 are `dp_diff`/`dn_raw` — the raw host bus inputs.
  These come from the NIF change log via `Hw.Sim.USBHost.enumerate/1`
  which logs host-side transitions explicitly.

  Channels 2-15 carry PHY/SIE/CDC internal state.
  """
  @spec usb_full_speed_host() :: [map()]
  def usb_full_speed_host do
    [
      # ── Host bus (point USB decoder here) ────────────────────────────────
      %{index: 0,  name: "host_dp",        entity: :phy, signal: :dp_diff,           bit: nil},
      %{index: 1,  name: "host_dn",        entity: :phy, signal: :dn_raw,            bit: nil},
      # ── PHY internals ────────────────────────────────────────────────────
      %{index: 2,  name: "prev_diff",      entity: :phy, signal: :phy_prev_diff,     bit: nil},
      %{index: 3,  name: "rx_active",      entity: :phy, signal: :phy_rx_state,      bit: 0},
      %{index: 4,  name: "tx_dp",          entity: :phy, signal: :phy_tx_dp,         bit: nil},
      %{index: 5,  name: "tx_dn",          entity: :phy, signal: :phy_tx_dn,         bit: nil},
      %{index: 6,  name: "phy_tx_st[0]",   entity: :phy, signal: :phy_tx_state,      bit: 0},
      %{index: 7,  name: "phy_tx_st[1]",   entity: :phy, signal: :phy_tx_state,      bit: 1},
      # ── SIE ──────────────────────────────────────────────────────────────
      %{index: 8,  name: "sie_rx_st[0]",   entity: :sie, signal: :sie_rx_state,      bit: 0},
      %{index: 9,  name: "sie_rx_st[1]",   entity: :sie, signal: :sie_rx_state,      bit: 1},
      %{index: 10, name: "sie_tx_st[0]",   entity: :sie, signal: :sie_tx_state,      bit: 0},
      %{index: 11, name: "sie_tx_st[1]",   entity: :sie, signal: :sie_tx_state,      bit: 1},
      %{index: 12, name: "send_handshake", entity: :sie, signal: :sie_send_handshake,bit: nil},
      %{index: 13, name: "ep_out_valid",   entity: :sie, signal: :sie_ep_out_valid,  bit: nil},
      # ── CDC ──────────────────────────────────────────────────────────────
      %{index: 14, name: "dev_state[0]",   entity: :cdc, signal: :cdc_dev_state,     bit: 0},
      %{index: 15, name: "dev_state[1]",   entity: :cdc, signal: :cdc_dev_state,     bit: 1},
    ]
  end

  @doc """
  8-channel preset matching the J1 header probe outputs on HelloBoard.
  Use this when comparing sim output against live logic analyzer captures.

  ch0 gp0: dp_diff           — USB D+ (J=1, K/SE0=0)
  ch1 gn0: dn_raw            — USB D- (K=1, SE0=0)
  ch2 gp1: phy_tx_valid      — FPGA transmitting
  ch3 gn1: phy_tx_dp         — FPGA TX D+
  ch4 gp2: sie_rx_state[0]   — SIE RX state LSB
  ch5 gn2: sie_rx_state[1]   — SIE RX state MSB
  ch6 gp3: sie_send_handshake — ACK/NAK trigger
  ch7 gn3: cdc_dev_state[0]  — 1=addressed
  """
  @spec hardware_probes() :: [map()]
  def hardware_probes do
    [
      %{index: 0, name: "dp_diff",        entity: :phy, signal: :dp_diff,            bit: nil},
      %{index: 1, name: "dn_raw",         entity: :phy, signal: :dn_raw,             bit: nil},
      %{index: 2, name: "phy_tx_valid",   entity: :phy, signal: :phy_tx_valid,       bit: nil},
      %{index: 3, name: "phy_tx_dp",      entity: :phy, signal: :phy_tx_dp,          bit: nil},
      %{index: 4, name: "sie_rx_st[0]",   entity: :sie, signal: :sie_rx_state,       bit: 0},
      %{index: 5, name: "sie_rx_st[1]",   entity: :sie, signal: :sie_rx_state,       bit: 1},
      %{index: 6, name: "send_handshake", entity: :sie, signal: :sie_send_handshake, bit: nil},
      %{index: 7, name: "dev_state[0]",   entity: :cdc, signal: :cdc_dev_state,      bit: 0},
    ]
  end

  @doc """
  16-channel map for USB Full Speed debugging on HelloBoard.Top.

  Channels 0-1 are D+/D- (tx_dp/tx_dn) — attach the USB Full Speed decoder
  in DSView to these for decoded packet annotations.

  Channels 2-15 carry PHY/SIE/CDC state machine signals.

      channel_map = Hw.Simtrace.DSL.Presets.usb_full_speed()
      Hw.Simtrace.DSL.export(st, "/tmp/usb.dsl", channel_map)
  """
  @spec usb_full_speed() :: [map()]
  def usb_full_speed do
    [
      # ── PHY: bus signals ──────────────────────────────────────────────────
      %{index: 0,  name: "tx_dp",          entity: :phy, signal: :phy_tx_dp,          bit: nil},
      %{index: 1,  name: "tx_dn",          entity: :phy, signal: :phy_tx_dn,          bit: nil},
      %{index: 2,  name: "prev_diff",      entity: :phy, signal: :phy_prev_diff,      bit: nil},
      %{index: 3,  name: "phy_rx_st[0]",   entity: :phy, signal: :phy_rx_state,       bit: 0},
      %{index: 4,  name: "phy_rx_st[1]",   entity: :phy, signal: :phy_rx_state,       bit: 1},
      %{index: 5,  name: "phy_tx_st[0]",   entity: :phy, signal: :phy_tx_state,       bit: 0},
      %{index: 6,  name: "phy_tx_st[1]",   entity: :phy, signal: :phy_tx_state,       bit: 1},
      # ── SIE: protocol engine ──────────────────────────────────────────────
      %{index: 7,  name: "sie_rx_st[0]",   entity: :sie, signal: :sie_rx_state,       bit: 0},
      %{index: 8,  name: "sie_rx_st[1]",   entity: :sie, signal: :sie_rx_state,       bit: 1},
      %{index: 9,  name: "sie_tx_st[0]",   entity: :sie, signal: :sie_tx_state,       bit: 0},
      %{index: 10, name: "sie_tx_st[1]",   entity: :sie, signal: :sie_tx_state,       bit: 1},
      %{index: 11, name: "send_handshake", entity: :sie, signal: :sie_send_handshake, bit: nil},
      %{index: 12, name: "ep_out_valid",   entity: :sie, signal: :sie_ep_out_valid,   bit: nil},
      %{index: 13, name: "ep_in_nak",      entity: :sie, signal: :sie_ep_in_nak,      bit: nil},
      # ── CDC: device state ─────────────────────────────────────────────────
      %{index: 14, name: "dev_state[0]",   entity: :cdc, signal: :cdc_dev_state,      bit: 0},
      %{index: 15, name: "dev_state[1]",   entity: :cdc, signal: :cdc_dev_state,      bit: 1},
    ]
  end
end
