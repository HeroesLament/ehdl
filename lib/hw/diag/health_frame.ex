defmodule Hw.Diag.HealthFrame do
  @moduledoc """
  The canonical field schema for the `Hw.Diag.HealthReport` US1 telemetry line.

  This is the single source of truth that pairs the on-wire ASCII frame produced
  by `Hw.Diag.HealthReport` with a host-side parser. It exists so the RX/TX/EP
  label collisions in the frame can no longer lose information: each field has a
  **unique key** even where two fields share a display label, and parsing is
  positional (see `Hw.Diag.FrameSchema`), so `:lat_rx_active` and `:rx_state`
  resolve distinctly despite both printing "RX".

  The field order below MUST match the byte template in `HealthReport.char_at`
  exactly — it is the same left-to-right sequence of value-bearing tokens. If a
  column is added/removed/reordered in the HDL template, update this list to
  match; the positional parser depends on the correspondence.

  ## Example

      schema = Hw.Diag.HealthFrame.schema()
      {:ok, m} = Hw.Diag.FrameSchema.parse(schema, line)
      m.getdesc     # 0/1 — GET_DESCRIPTOR ever dispatched
      m.rx_state    # 0..3 — live SIE RX FSM (distinct from m.lat_rx_active)
  """

  alias Hw.Diag.FrameSchema

  # {key, wire_label, value_width, base, kind}. Order = wire order.
  @fields [
    {:pll_locked,    "PLL",  1, 10, :live},
    {:rst,           "RST",  1, 10, :live},
    {:lat_dn_high,   "DNH",  1, 10, :sticky},
    {:lat_raw_k,     "RAWK", 1, 10, :sticky},
    {:lat_rx_active, "RX",   1, 10, :sticky},   # sticky "RX"  (PHY ever declared a packet)
    {:lat_pkt_end,   "PKT",  1, 10, :sticky},
    {:lat_accept,    "ACC",  1, 10, :sticky},
    {:lat_tx_ran,    "TX",   1, 10, :sticky},   # sticky "TX"  (device TX FSM ever ran)
    {:rx_state,      "RX",   1, 10, :live},     # live "RX"    (SIE RX FSM state) — same label, unique key
    {:tx_state,      "TX",   1, 10, :live},     # live "TX"    (SIE TX FSM state) — same label, unique key
    {:dev_state,     "DEV",  1, 10, :live},
    {:ep0_state,     "EP",   1, 10, :live},     # live "EP"    (CDC EP0 FSM) — first EP
    {:dev_addr,      "A",    2, 16, :live},
    {:ep_in_done,    "D",    1, 10, :live},
    {:ep_in_nak,     "N",    1, 10, :live},
    {:lat_hsk,       "HSK",  1, 10, :sticky},
    {:lat_txreq,     "REQ",  1, 10, :sticky},
    {:lat_epload,    "EPL",  1, 10, :sticky},
    {:lat_epout,     "OUT",  1, 10, :sticky},
    {:lat_setup,     "STP",  1, 10, :sticky},
    {:req,           "Q",    4, 16, :live},     # decoded {bmRequestType,bRequest}
    {:lat_ep0moved,  "MV",   1, 10, :sticky},
    {:lat_setupfull, "SF",   1, 10, :sticky},
    {:lat_setupcnt,  "C",    1, 10, :sticky},
    {:lat_epout_ep,  "EP",   1, 16, :sticky},   # second "EP"  (ep_out_ep) — same label, unique key
    {:lat_dispatch,  "DS",   1, 10, :sticky},
    {:live_setup,    "L",    4, 16, :sticky},   # {setup_b0,setup_b1} the dispatch matched
    {:lat_coin_disp, "CD",   1, 10, :sticky},
    {:lat_coin_clob, "CL",   1, 10, :sticky},
    {:lat_ep0_after, "E0A",  1, 10, :sticky},
    {:lat_coindescr, "CS",   1, 10, :sticky},
    {:lat_shadowset, "SH",   1, 10, :sticky},
    {:lat_hbmoved,   "HB",   1, 10, :sticky},
    {:lat_mirror,    "MR",   1, 10, :sticky},
    {:getdesc,       "GD",   1, 10, :sticky},
    {:descrun,       "DR",   1, 10, :sticky},
    {:setcfg,        "CF",   1, 10, :sticky},
    {:saw_b0_80,     "80",   1, 10, :sticky},
    {:last_b0,       "LB",   2, 16, :sticky},
    {:us1_rx,        "U1",   1, 10, :sticky},   # US1 command UART ever received a byte
    {:cmd_reset,     "CR",   1, 10, :sticky},   # a 'R' re-enum command was ever decoded
    {:reenum_count,  "RC",   1, 16, :sticky},   # reset-survivable count of re-enum windows started (hex)
    {:us1_valid,     "UV",   1, 10, :live},     # us1_rx_valid live now
    {:us1_rx_edges,  "RN",   1, 16, :sticky},   # us1_rx_valid rising-edge count (1 hex)
    {:sie_txpeak,    "TP",   1, 10, :sticky},   # peak SIE TX FSM state reached (0..5)
    {:phy_txvalid,   "PV",   1, 10, :sticky},   # SIE->PHY bit handoff ever fired
    {:phy_txactive,  "PA",   1, 10, :sticky},   # PHY TX FSM ever left idle
    {:phy_txen,      "PE",   1, 10, :sticky},   # PHY pad output-enable ever asserted
    {:pad_toggle,    "PD",   1, 10, :sticky},   # pads ever left J-idle (real drive)
    {:tx_cap,        "TC",  12, 16, :sticky},   # first TX packet symbols, 48-bit hex (24 x {dp,dn})
    {:tx_cap_cnt,    "N",    1, 16, :sticky},   # capture count low nibble
    {:tx_cap_done,   "",     1, 10, :sticky},   # done bit (immediately follows N's nibble)
    {:turn_val,      "TA",   4, 16, :sticky},   # EOP->TX-start latency in cycles (4 hex)
    {:turn_done,     "",     1, 10, :sticky}    # turnaround-measured bit (follows TA's 4 hex)
  ]

  @doc "The validated `Hw.Diag.FrameSchema` for the health line."
  def schema, do: FrameSchema.build(@fields)

  @doc "Ordered field keys."
  def keys, do: FrameSchema.keys(schema())

  @doc "Parse a health line into `%{key => integer}` (or `:error`)."
  def parse(line), do: FrameSchema.parse(schema(), line)
end
