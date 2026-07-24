defmodule Hw.Diag.HealthReport do
  @moduledoc """
  Streams a full, self-documenting "health SDO" line of the USB enumeration
  pipeline out a UART, so the host reads the entire device state as one labeled
  ASCII line over the US1 FTDI serial port — no logic analyzer required.

  ## Frame

  A fixed-length template, one field per instrumentation point, terminated by
  CR LF. Sticky latches (did this stage EVER fire) and live state (where are we
  RIGHT NOW) in one glance:

      PLLp RSTr | DNHa RAWKk RXx PKTe ACCc TXt | RXs TXu DEVd EP0 e0 ADDRhh DONEn NAKm

  where each single lowercase letter above is a substituted ASCII value:

    p  pll_locked            (0/1)   board clock alive
    r  rst                   (0/1)   in reset
    a  lat_dn_high  (sticky)  raw D- was EVER high        (PHY input present)
    k  lat_raw_k    (sticky)  a raw K symbol EVER seen     <- KEY PHY QUESTION
    x  lat_rx_active (sticky) PHY EVER declared a packet
    e  lat_pkt_end  (sticky)  a packet EVER passed CRC16
    c  lat_accept   (sticky)  a token EVER accepted (CRC5+addr)
    t  lat_tx_ran   (sticky)  device TX FSM EVER ran
    s  rx_state     (live, 0..3)   SIE RX FSM
    u  tx_state     (live, 0..7)   SIE TX FSM
    d  dev_state    (live, 0/1/2)  0=default 1=addressed 2=configured
    0  ep0_state    (live, 0..3)   CDC EP0 control FSM
    hh dev_addr     (live, 2 hex)  assigned USB address
    n  ep_in_done   (live, 0/1)
    m  ep_in_nak    (live, 0/1)

  ## Design

  A byte index walks 0..LEN-1. `char_at` (comb) returns the template byte for
  each index — mostly constant label characters, with value substitution at the
  digit slots via `nib` (a 0..15 -> ASCII hex helper). Byte cadence is purely
  timer-based (BYTE_CYCLES per slot) so it never depends on the UART's cross-
  instance `ready` latency. Inner UART fixed at 9600 8N1 (the rate the FTDI/USB
  path drains without RX-FIFO overrun).

  Pure passive observer — only READS its inputs and drives its own UART.
  """

  use Hw.Component

  # Byte-slot cadence (cycles per byte). 9600 baud = 5000 cyc/bit; a 10-bit frame
  # is 50000 cyc, so 60000 leaves margin. Idle gap between lines afterward.
  param :BYTE_CYCLES, default: 60_000
  param :GAP_CYCLES,  default: 480_000
  # Template length in bytes (see char_at). Keep in sync with the case below.
  param :LEN, default: 244

  clock :clk, freq: 48.0
  input  :rst, 1

  # --- Instrumentation inputs ---
  input :pll_locked, 1
  input :in_rst,     1   # a captured/registered copy of rst for display
  input :dn_high,    1   # lat_dn_high
  input :raw_k,      1   # lat_raw_k
  input :rx_active,  1   # lat_rx_active
  input :pkt_end,    1   # lat_pkt_end
  input :accept,     1   # lat_accept
  input :tx_ran,     1   # lat_tx_ran
  input :rx_state,   2
  input :tx_state,   3
  input :dev_state,  2
  input :ep0_state,  2
  input :dev_addr,   7
  input :ep_in_done, 1
  input :ep_in_nak,  1
  input :hsk,        1   # lat_hsk: send_handshake EVER armed (accept->TX handoff)
  input :txreq,      1   # lat_txreq: IN token EVER armed a DATA transmit
  input :epload,     1   # lat_epload: CDC EVER loaded an EP IN buffer
  input :epout,      1   # lat_epout: SIE EVER delivered an ep_out byte to CDC
  input :setup,      1   # lat_setup: an ep_out packet-end was EVER flagged SETUP
  input :reqtype,    8   # lat_reqtype: CDC-decoded bmRequestType at last SETUP
  input :reqcode,    8   # lat_reqcode: CDC-decoded bRequest at last SETUP
  input :ep0moved,   1   # lat_ep0moved: CDC ep0_state EVER left idle
  input :setupfull,  1   # lat_setupfull: CDC EVER got all 8 SETUP bytes
  input :setupcnt,   3   # lat_setupcnt: peak SETUP byte count
  input :epoutep,    4   # lat_epout_ep: ep_out_ep value at the setup packet-end
  input :dispatch,   1   # lat_dispatch: CDC dispatch guard EVER true at pkt_end
  input :liveb0,     8   # lat_liveb0: setup_b0 the dispatch case actually saw
  input :liveb1,     8   # lat_liveb1: setup_b1 the dispatch case actually saw
  input :coin_disp,  1   # lat_coin_dispatch: guard & req==0005 in the SAME cycle
  input :coin_clob,  1   # lat_coin_clobber: ep_in_done & dispatch guard SAME cycle
  input :ep0after,   2   # lat_ep0_after: ep0_state sampled the cycle after a coincidence
  input :coindescr,  1   # lat_coin_descr: descriptor-stream writer same cycle as dispatch
  input :shadowset,  1   # lat_shadow_set: shadow intent said ep0_state should be 2
  input :hbmoved,    1   # lat_hb_moved: CDC heartbeat ever advanced -> CDC IS clocking
  input :mirror,     2   # lat_mirror: CDC-internal ep0_state mirror (vs the output pin)
  input :getdesc,    1   # lat_getdesc: GET_DESCRIPTOR ever dispatched
  input :descrun,    1   # lat_descrun: descriptor-stream branch ever ran
  input :setcfg,     1   # lat_setcfg: SET_CONFIGURATION ever dispatched
  input :sawb080,    1   # lat_saw_b0_80: a device-to-host (b0=0x80) SETUP ever dispatched
  input :lastb0,     8   # lat_last_b0: last setup_b0 the dispatch saw
  input :us1rx,      1   # lat_us1_rx: a byte was EVER received on the US1 command UART
  input :cmdrst,     1   # lat_cmd_reset: a 'R' re-enum command was EVER decoded
  input :reactive,   4   # reenum_count: reset-survivable count of re-enum windows started (hex)
  input :uvlive,     1   # us1_valid_live: us1_rx_valid RIGHT NOW (live)
  input :rxedges,    4   # us1_rx_edges: saturating count of us1_rx_valid rising edges
  # --- TX-chain localizers ---
  input :txpeak,     3   # lat_sie_txpeak: peak SIE TX FSM state reached (0 idle..5 eop)
  input :txvalid,    1   # lat_phy_txvalid: SIE->PHY bit handoff ever fired
  input :txactive,   1   # lat_phy_txactive: PHY TX FSM ever left idle
  input :txen,       1   # lat_phy_txen: PHY pad output-enable ever asserted
  input :padtog,     1   # lat_pad_toggle: pads ever LEFT J-idle (real drive)
  input :txcap,      48  # tx_cap: first transmitted packet's symbols (24 x {dp,dn})
  input :txcapcnt,   5   # tx_cap_cnt: symbols captured (0..24)
  input :txcapdone,  1   # tx_cap_done: a full first-packet capture is frozen
  input :turnval,    14  # turn_val: EOP->TX-start latency in cycles (4 hex)
  input :turndone,   1   # turn_done: a turnaround was measured

  output :txd, 1

  # --- Inner UART @ 9600 8N1 ---
  wire :uart_data,  8
  wire :uart_valid, 1, init: 0
  wire :uart_ready, 1

  instance :uart, Hw.UART.TX,
    CLK_FREQ:  48_000_000,
    BAUD_RATE: 9_600,
    clk:   :clk,
    rst:   :rst,
    data:  :uart_data,
    valid: :uart_valid,
    ready: :uart_ready,
    txd:   :txd

  # --- Sender state (timer-based cadence) ---
  wire :idx,      8, init: 0    # byte index into the template, 0..LEN
  wire :slot_cnt, 24, init: 0
  wire :gap_cnt,  23, init: 0
  wire :sending,   1, init: 1
  wire :ch,        8            # comb: template byte at idx

  # --- Value helpers (comb) ---
  wire :addr_hi, 4
  wire :addr_lo, 4
  wire :nib_hi,  8   # ASCII of addr high nibble
  wire :nib_lo,  8   # ASCII of addr low nibble
  # ASCII hex nibbles for the two decoded SETUP request bytes.
  wire :rt_hi, 8
  wire :rt_lo, 8
  wire :rc_hi, 8
  wire :rc_lo, 8
  wire :ee_lo, 8   # ASCII hex of ep_out_ep (single nibble)
  wire :lb0_hi, 8
  wire :lb0_lo, 8
  wire :lb1_hi, 8
  wire :lb1_lo, 8
  wire :b0_hi, 8
  wire :b0_lo, 8
  wire :rxe_lo, 8   # ASCII hex of rxedges (single nibble)
  wire :rc_x,   8   # ASCII hex of reactive/reenum_count (single nibble)
  # TX-capture nibble ASCII (12 nibbles of the 48-bit tx_cap, MSB-first) + count.
  wire :tc0, 8
  wire :tc1, 8
  wire :tc2, 8
  wire :tc3, 8
  wire :tc4, 8
  wire :tc5, 8
  wire :tc6, 8
  wire :tc7, 8
  wire :tc8, 8
  wire :tc9, 8
  wire :tc10, 8
  wire :tc11, 8
  wire :tcn, 8   # ASCII hex of tx_cap_cnt (single nibble; 24 max fits? no -> see below)
  wire :ta0, 8   # turnaround hex nibbles (turn_val, 14-bit -> 4 nibbles)
  wire :ta1, 8
  wire :ta2, 8
  wire :ta3, 8

  comb do
    # dev_addr is 7 bits; high nibble is only bits 6..4 (3 bits). Zero-extend to
    # 4 so the hex math is uniform.
    addr_hi = {0[0..0], dev_addr[6..4]}
    addr_lo = dev_addr[3..0]
    # 0..9 -> '0'..'9' (0x30+n); a..f -> 'a'..'f' (0x57 + n, since 0x57+10=0x61).
    nib_hi = if addr_hi < 10, do: 0x30 + addr_hi, else: 0x57 + addr_hi
    nib_lo = if addr_lo < 10, do: 0x30 + addr_lo, else: 0x57 + addr_lo
    # reqtype/reqcode as 2 hex chars each.
    rt_hi = if reqtype[7..4] < 10, do: 0x30 + reqtype[7..4], else: 0x57 + reqtype[7..4]
    rt_lo = if reqtype[3..0] < 10, do: 0x30 + reqtype[3..0], else: 0x57 + reqtype[3..0]
    rc_hi = if reqcode[7..4] < 10, do: 0x30 + reqcode[7..4], else: 0x57 + reqcode[7..4]
    rc_lo = if reqcode[3..0] < 10, do: 0x30 + reqcode[3..0], else: 0x57 + reqcode[3..0]
    ee_lo = if epoutep < 10, do: 0x30 + epoutep, else: 0x57 + epoutep
    lb0_hi = if liveb0[7..4] < 10, do: 0x30 + liveb0[7..4], else: 0x57 + liveb0[7..4]
    lb0_lo = if liveb0[3..0] < 10, do: 0x30 + liveb0[3..0], else: 0x57 + liveb0[3..0]
    lb1_hi = if liveb1[7..4] < 10, do: 0x30 + liveb1[7..4], else: 0x57 + liveb1[7..4]
    lb1_lo = if liveb1[3..0] < 10, do: 0x30 + liveb1[3..0], else: 0x57 + liveb1[3..0]
    b0_hi = if lastb0[7..4] < 10, do: 0x30 + lastb0[7..4], else: 0x57 + lastb0[7..4]
    b0_lo = if lastb0[3..0] < 10, do: 0x30 + lastb0[3..0], else: 0x57 + lastb0[3..0]
    rxe_lo = if rxedges < 10, do: 0x30 + rxedges, else: 0x57 + rxedges
    rc_x   = if reactive < 10, do: 0x30 + reactive, else: 0x57 + reactive
    # 12 hex nibbles of tx_cap, MSB (oldest symbol) first.
    tc0  = if txcap[47..44] < 10, do: 0x30 + txcap[47..44], else: 0x57 + txcap[47..44]
    tc1  = if txcap[43..40] < 10, do: 0x30 + txcap[43..40], else: 0x57 + txcap[43..40]
    tc2  = if txcap[39..36] < 10, do: 0x30 + txcap[39..36], else: 0x57 + txcap[39..36]
    tc3  = if txcap[35..32] < 10, do: 0x30 + txcap[35..32], else: 0x57 + txcap[35..32]
    tc4  = if txcap[31..28] < 10, do: 0x30 + txcap[31..28], else: 0x57 + txcap[31..28]
    tc5  = if txcap[27..24] < 10, do: 0x30 + txcap[27..24], else: 0x57 + txcap[27..24]
    tc6  = if txcap[23..20] < 10, do: 0x30 + txcap[23..20], else: 0x57 + txcap[23..20]
    tc7  = if txcap[19..16] < 10, do: 0x30 + txcap[19..16], else: 0x57 + txcap[19..16]
    tc8  = if txcap[15..12] < 10, do: 0x30 + txcap[15..12], else: 0x57 + txcap[15..12]
    tc9  = if txcap[11..8]  < 10, do: 0x30 + txcap[11..8],  else: 0x57 + txcap[11..8]
    tc10 = if txcap[7..4]   < 10, do: 0x30 + txcap[7..4],   else: 0x57 + txcap[7..4]
    tc11 = if txcap[3..0]   < 10, do: 0x30 + txcap[3..0],   else: 0x57 + txcap[3..0]
    # count is 0..24; render low nibble as hex (host reads full value from cnt if
    # needed, but 24 = 0x18 doesn't fit 1 nibble -> show cnt[3..0], plus done bit).
    tcn  = if txcapcnt[3..0] < 10, do: 0x30 + txcapcnt[3..0], else: 0x57 + txcapcnt[3..0]
    ta0  = 0x30 + turnval[13..12]   # top nibble is only 2 bits (0..3) -> always a digit
    ta1  = if turnval[11..8] < 10, do: 0x30 + turnval[11..8], else: 0x57 + turnval[11..8]
    ta2  = if turnval[7..4] < 10, do: 0x30 + turnval[7..4], else: 0x57 + turnval[7..4]
    ta3  = if turnval[3..0] < 10, do: 0x30 + turnval[3..0], else: 0x57 + turnval[3..0]

    # Template. Constant label bytes plus value substitutions. Values are single
    # ASCII digits: 0x30 + bit, or hex for multi-bit small fields.
    # Layout (indices):
    #  0:P 1:L 2:L 3:<p> 4:sp 5:R 6:S 7:T 8:<r> 9:sp 10:| 11:sp
    # 12:D 13:N 14:H 15:<a> 16:sp 17:R 18:A 19:W 20:K 21:<k> 22:sp
    # 23:R 24:X 25:<x> 26:sp 27:P 28:K 29:T 30:<e> 31:sp
    # 32:A 33:C 34:C 35:<c> 36:sp 37:T 38:X 39:<t> 40:sp 41:| 42:sp
    # 43:R 44:X 45:<s> 46:sp 47:T 48:X 49:<u> 50:sp
    # 51:D 52:E 53:V 54:<d> 55:sp 56:E 57:P 58:<e0> 59:sp
    # 60:A 61:<hh hi> 62:<hh lo> 63:sp 64:D 65:<done> 66:sp 67:N 68:<nak> 69:CR 70:LF
    hdl_case <<idx::8>> do
      <<0::8>>  -> ch = 0x50   # P
      <<1::8>>  -> ch = 0x4C   # L
      <<2::8>>  -> ch = 0x4C   # L
      <<3::8>>  -> ch = 0x30 + pll_locked
      <<4::8>>  -> ch = 0x20   # space
      <<5::8>>  -> ch = 0x52   # R
      <<6::8>>  -> ch = 0x53   # S
      <<7::8>>  -> ch = 0x54   # T
      <<8::8>>  -> ch = 0x30 + in_rst
      <<9::8>>  -> ch = 0x20
      <<10::8>> -> ch = 0x7C   # |
      <<11::8>> -> ch = 0x20
      <<12::8>> -> ch = 0x44   # D
      <<13::8>> -> ch = 0x4E   # N
      <<14::8>> -> ch = 0x48   # H
      <<15::8>> -> ch = 0x30 + dn_high
      <<16::8>> -> ch = 0x20
      <<17::8>> -> ch = 0x52   # R
      <<18::8>> -> ch = 0x41   # A
      <<19::8>> -> ch = 0x57   # W
      <<20::8>> -> ch = 0x4B   # K
      <<21::8>> -> ch = 0x30 + raw_k
      <<22::8>> -> ch = 0x20
      <<23::8>> -> ch = 0x52   # R
      <<24::8>> -> ch = 0x58   # X
      <<25::8>> -> ch = 0x30 + rx_active
      <<26::8>> -> ch = 0x20
      <<27::8>> -> ch = 0x50   # P
      <<28::8>> -> ch = 0x4B   # K
      <<29::8>> -> ch = 0x54   # T
      <<30::8>> -> ch = 0x30 + pkt_end
      <<31::8>> -> ch = 0x20
      <<32::8>> -> ch = 0x41   # A
      <<33::8>> -> ch = 0x43   # C
      <<34::8>> -> ch = 0x43   # C
      <<35::8>> -> ch = 0x30 + accept
      <<36::8>> -> ch = 0x20
      <<37::8>> -> ch = 0x54   # T
      <<38::8>> -> ch = 0x58   # X
      <<39::8>> -> ch = 0x30 + tx_ran
      <<40::8>> -> ch = 0x20
      <<41::8>> -> ch = 0x7C   # |
      <<42::8>> -> ch = 0x20
      <<43::8>> -> ch = 0x52   # R
      <<44::8>> -> ch = 0x58   # X
      <<45::8>> -> ch = 0x30 + rx_state   # rx_state 0..3 as digit
      <<46::8>> -> ch = 0x20
      <<47::8>> -> ch = 0x54   # T
      <<48::8>> -> ch = 0x58   # X
      <<49::8>> -> ch = 0x30 + tx_state   # tx_state 0..7 as digit
      <<50::8>> -> ch = 0x20
      <<51::8>> -> ch = 0x44   # D
      <<52::8>> -> ch = 0x45   # E
      <<53::8>> -> ch = 0x56   # V
      <<54::8>> -> ch = 0x30 + dev_state  # dev_state 0..2 as digit
      <<55::8>> -> ch = 0x20
      <<56::8>> -> ch = 0x45   # E
      <<57::8>> -> ch = 0x50   # P
      <<58::8>> -> ch = 0x30 + ep0_state  # ep0_state 0..3 as digit
      <<59::8>> -> ch = 0x20
      <<60::8>> -> ch = 0x41   # A  (ADDR marker)
      <<61::8>> -> ch = nib_hi
      <<62::8>> -> ch = nib_lo
      <<63::8>> -> ch = 0x20
      <<64::8>> -> ch = 0x44   # D  (DONE marker)
      <<65::8>> -> ch = 0x30 + ep_in_done
      <<66::8>> -> ch = 0x20
      <<67::8>> -> ch = 0x4E   # N  (NAK marker)
      <<68::8>> -> ch = 0x30 + ep_in_nak
      <<69::8>> -> ch = 0x48   # H  (HSK marker: send_handshake ever armed)
      <<70::8>> -> ch = 0x53   # S
      <<71::8>> -> ch = 0x4B   # K
      <<72::8>> -> ch = 0x30 + hsk
      <<73::8>> -> ch = 0x20
      <<74::8>> -> ch = 0x52   # R  (REQ marker: IN-data TX ever armed)
      <<75::8>> -> ch = 0x45   # E
      <<76::8>> -> ch = 0x51   # Q
      <<77::8>> -> ch = 0x30 + txreq
      <<78::8>> -> ch = 0x20
      <<79::8>> -> ch = 0x45   # E  (EPL marker: CDC ever loaded an EP IN buffer)
      <<80::8>> -> ch = 0x50   # P
      <<81::8>> -> ch = 0x4C   # L
      <<82::8>> -> ch = 0x30 + epload
      <<83::8>> -> ch = 0x20
      <<84::8>> -> ch = 0x4F   # O  (OUT marker: SIE ever delivered an ep_out byte)
      <<85::8>> -> ch = 0x55   # U
      <<86::8>> -> ch = 0x54   # T
      <<87::8>> -> ch = 0x30 + epout
      <<88::8>> -> ch = 0x20
      <<89::8>> -> ch = 0x53   # S  (STP marker: an ep_out pkt-end was ever SETUP)
      <<90::8>> -> ch = 0x54   # T
      <<91::8>> -> ch = 0x50   # P
      <<92::8>> -> ch = 0x30 + setup
      <<93::8>> -> ch = 0x20
      <<94::8>> -> ch = 0x51   # Q  (request marker: decoded bmRequestType,bRequest)
      <<95::8>> -> ch = 0x3D   # =
      <<96::8>>  -> ch = rt_hi
      <<97::8>>  -> ch = rt_lo
      <<98::8>>  -> ch = rc_hi
      <<99::8>>  -> ch = rc_lo
      <<100::8>> -> ch = 0x20
      <<101::8>> -> ch = 0x4D   # M  (MOV marker: ep0_state ever left idle)
      <<102::8>> -> ch = 0x56   # V
      <<103::8>> -> ch = 0x30 + ep0moved
      <<104::8>> -> ch = 0x20
      <<105::8>> -> ch = 0x53   # S  (SF marker: setup_full ever reached)
      <<106::8>> -> ch = 0x46   # F
      <<107::8>> -> ch = 0x30 + setupfull
      <<108::8>> -> ch = 0x20
      <<109::8>> -> ch = 0x43   # C  (SC marker: peak setup byte count)
      <<110::8>> -> ch = 0x30 + setupcnt
      <<111::8>> -> ch = 0x20
      <<112::8>> -> ch = 0x45   # E  (EEP marker: ep_out_ep at setup pkt-end)
      <<113::8>> -> ch = 0x50   # P
      <<114::8>> -> ch = ee_lo
      <<115::8>> -> ch = 0x20
      <<116::8>> -> ch = 0x44   # D  (DSP marker: dispatch guard ever true)
      <<117::8>> -> ch = 0x53   # S
      <<118::8>> -> ch = 0x30 + dispatch
      <<119::8>> -> ch = 0x20
      <<120::8>> -> ch = 0x4C   # L  (live setup bytes the dispatch case matched)
      <<121::8>> -> ch = lb0_hi
      <<122::8>> -> ch = lb0_lo
      <<123::8>> -> ch = lb1_hi
      <<124::8>> -> ch = lb1_lo
      <<125::8>> -> ch = 0x20
      <<126::8>> -> ch = 0x43   # C  (CD marker: dispatch coincidence)
      <<127::8>> -> ch = 0x44   # D
      <<128::8>> -> ch = 0x30 + coin_disp
      <<129::8>> -> ch = 0x20
      <<130::8>> -> ch = 0x43   # C  (CL marker: clobber coincidence)
      <<131::8>> -> ch = 0x4C   # L
      <<132::8>> -> ch = 0x30 + coin_clob
      <<133::8>> -> ch = 0x20
      <<134::8>> -> ch = 0x45   # E  (E0A marker: ep0_state one cycle after coincidence)
      <<135::8>> -> ch = 0x30   # 0
      <<136::8>> -> ch = 0x41   # A
      <<137::8>> -> ch = 0x30 + ep0after   # 0..3 digit
      <<138::8>> -> ch = 0x20
      <<139::8>> -> ch = 0x43   # C  (CDS marker: descriptor-writer coincidence)
      <<140::8>> -> ch = 0x53   # S
      <<141::8>> -> ch = 0x30 + coindescr
      <<142::8>> -> ch = 0x20
      <<143::8>> -> ch = 0x53   # S  (SH marker: shadow intent set)
      <<144::8>> -> ch = 0x48   # H
      <<145::8>> -> ch = 0x30 + shadowset
      <<146::8>> -> ch = 0x20
      <<147::8>> -> ch = 0x48   # H  (HB marker: CDC heartbeat ever advanced)
      <<148::8>> -> ch = 0x42   # B
      <<149::8>> -> ch = 0x30 + hbmoved
      <<150::8>> -> ch = 0x20
      <<151::8>> -> ch = 0x4D   # M  (MR marker: CDC-internal ep0_state mirror)
      <<152::8>> -> ch = 0x52   # R
      <<153::8>> -> ch = 0x30 + mirror
      <<154::8>> -> ch = 0x20
      <<155::8>> -> ch = 0x47   # G  (GD marker: GET_DESCRIPTOR ever dispatched)
      <<156::8>> -> ch = 0x44   # D
      <<157::8>> -> ch = 0x30 + getdesc
      <<158::8>> -> ch = 0x20
      <<159::8>> -> ch = 0x44   # D  (DR marker: descriptor-stream ran)
      <<160::8>> -> ch = 0x52   # R
      <<161::8>> -> ch = 0x30 + descrun
      <<162::8>> -> ch = 0x20
      <<163::8>> -> ch = 0x43   # C  (CF marker: SET_CONFIGURATION dispatched)
      <<164::8>> -> ch = 0x46   # F
      <<165::8>> -> ch = 0x30 + setcfg
      <<166::8>> -> ch = 0x20
      <<167::8>> -> ch = 0x38   # 8  (80 marker: device-to-host SETUP ever seen)
      <<168::8>> -> ch = 0x30   # 0
      <<169::8>> -> ch = 0x30 + sawb080
      <<170::8>> -> ch = 0x20
      <<171::8>> -> ch = 0x4C   # L  (LB marker: last setup_b0 seen, 2 hex)
      <<172::8>> -> ch = 0x42   # B
      <<173::8>> -> ch = b0_hi
      <<174::8>> -> ch = b0_lo
      <<175::8>> -> ch = 0x20
      <<176::8>> -> ch = 0x55   # U  (U1 marker: a US1 command byte was EVER received)
      <<177::8>> -> ch = 0x31   # 1
      <<178::8>> -> ch = 0x30 + us1rx
      <<179::8>> -> ch = 0x20
      <<180::8>> -> ch = 0x43   # C  (CR marker: a 'R' re-enum command was EVER decoded)
      <<181::8>> -> ch = 0x52   # R
      <<182::8>> -> ch = 0x30 + cmdrst
      <<183::8>> -> ch = 0x20
      <<184::8>> -> ch = 0x52   # R  (RC marker: reset-survivable re-enum window count, 1 hex)
      <<185::8>> -> ch = 0x43   # C
      <<186::8>> -> ch = rc_x
      <<187::8>> -> ch = 0x20
      <<188::8>> -> ch = 0x55   # U  (UV marker: us1_rx_valid live NOW)
      <<189::8>> -> ch = 0x56   # V
      <<190::8>> -> ch = 0x30 + uvlive
      <<191::8>> -> ch = 0x20
      <<192::8>> -> ch = 0x52   # R  (RN marker: us1_rx_valid rising-edge count, 1 hex)
      <<193::8>> -> ch = 0x4E   # N
      <<194::8>> -> ch = rxe_lo
      <<195::8>> -> ch = 0x20
      # --- TX-chain localizer block: TP PV PA PE PD ---
      <<196::8>> -> ch = 0x54   # T  (TP marker: SIE TX FSM peak state, 1 digit)
      <<197::8>> -> ch = 0x50   # P
      <<198::8>> -> ch = 0x30 + txpeak
      <<199::8>> -> ch = 0x20
      <<200::8>> -> ch = 0x50   # P  (PV marker: phy_tx_valid ever)
      <<201::8>> -> ch = 0x56   # V
      <<202::8>> -> ch = 0x30 + txvalid
      <<203::8>> -> ch = 0x20
      <<204::8>> -> ch = 0x50   # P  (PA marker: phy tx_active ever)
      <<205::8>> -> ch = 0x41   # A
      <<206::8>> -> ch = 0x30 + txactive
      <<207::8>> -> ch = 0x20
      <<208::8>> -> ch = 0x50   # P  (PE marker: phy tx_en ever)
      <<209::8>> -> ch = 0x45   # E
      <<210::8>> -> ch = 0x30 + txen
      <<211::8>> -> ch = 0x20
      <<212::8>> -> ch = 0x50   # P  (PD marker: pad toggle ever)
      <<213::8>> -> ch = 0x44   # D
      <<214::8>> -> ch = 0x30 + padtog
      <<215::8>> -> ch = 0x20
      # --- TX-waveform capture: TC{12 hex} then N{cnt hex}{done} ---
      <<216::8>> -> ch = 0x54   # T  (TC marker: first-packet TX symbols, 48-bit hex)
      <<217::8>> -> ch = 0x43   # C
      <<218::8>> -> ch = tc0
      <<219::8>> -> ch = tc1
      <<220::8>> -> ch = tc2
      <<221::8>> -> ch = tc3
      <<222::8>> -> ch = tc4
      <<223::8>> -> ch = tc5
      <<224::8>> -> ch = tc6
      <<225::8>> -> ch = tc7
      <<226::8>> -> ch = tc8
      <<227::8>> -> ch = tc9
      <<228::8>> -> ch = tc10
      <<229::8>> -> ch = tc11
      <<230::8>> -> ch = 0x20
      <<231::8>> -> ch = 0x4E   # N  (N marker: capture count low nibble + done bit)
      <<232::8>> -> ch = tcn
      <<233::8>> -> ch = 0x30 + txcapdone
      <<234::8>> -> ch = 0x20
      # --- TURNAROUND latency: TA{4 hex cycles}{done} ---
      <<235::8>> -> ch = 0x54   # T  (TA marker: EOP->TX-start latency, cycles, 4 hex)
      <<236::8>> -> ch = 0x41   # A
      <<237::8>> -> ch = ta0
      <<238::8>> -> ch = ta1
      <<239::8>> -> ch = ta2
      <<240::8>> -> ch = ta3
      <<241::8>> -> ch = 0x30 + turndone
      <<242::8>> -> ch = 0x0D   # CR
      # LF must be an EXPLICIT index, NOT a `<<_::8>>` wildcard: a wildcard arm
      # matches EVERY index and (last-arm-wins in the generated if-chain) would
      # clobber all the specific arms above, making every byte 0x0A. The case
      # default (unmatched idx) is 0x00, which never occurs since idx only walks
      # 0..LEN-1 and every value in that range has an explicit arm.
      <<243::8>> -> ch = 0x0A   # LF
    end
  end

  on :clk do
    if rst do
      idx        = 0
      slot_cnt   = 0
      gap_cnt    = 0
      sending    = 1
      uart_valid = 0
    else
      uart_data = ch
      if sending do
        # Pulse valid at slot start; hold the slot for BYTE_CYCLES; then advance.
        if slot_cnt == 0 do
          uart_valid = 1
        else
          uart_valid = 0
        end

        if slot_cnt == BYTE_CYCLES do
          slot_cnt = 0
          if idx == LEN - 1 do
            idx     = 0
            gap_cnt = 0
            sending = 0
          else
            idx = idx + 1
          end
        else
          slot_cnt = slot_cnt + 1
        end
      else
        uart_valid = 0
        if gap_cnt == GAP_CYCLES do
          sending  = 1
          gap_cnt  = 0
          slot_cnt = 0
        else
          gap_cnt = gap_cnt + 1
        end
      end
    end
  end
end
