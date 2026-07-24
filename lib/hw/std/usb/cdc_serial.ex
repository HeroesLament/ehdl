defmodule Hw.USB.CDCSerial do
  @moduledoc """
  USB CDC-ACM Serial Device.

  Implements USB CDC-ACM enumeration and data transfer using the
  endpoint buffer model exposed by `Hw.USB.SIE`.

  CDC never sees raw USB tokens. It only:
  - Receives byte streams from `USBEndpointOut` (OUT/SETUP packets)
  - Loads byte buffers into `USBEndpointIn` (IN responses)
  - Drives `dev_addr` into the SIE after SET_ADDRESS completes

  ## Enumeration flow

  1. Host sends SETUP GET_DESCRIPTOR → CDC receives bytes via ep_out,
     loads descriptor into EP0 IN buffer, waits for ep_in_done.
  2. Host sends SETUP SET_ADDRESS → CDC receives bytes, sends zero-length
     STATUS IN, on ep_in_done updates dev_addr.
  3. Host sends SETUP SET_CONFIGURATION → CDC marks dev_state = configured.
  4. Host sends CDC class requests (SET_LINE_CODING etc.) → handled.

  ## Data flow

  - EP1 OUT bytes → UART TX (rx_data/rx_valid)
  - UART RX bytes (tx_data/tx_valid) → EP1 IN buffer (when host polls)

  ## Request decode

  SETUP requests are dispatched by binary pattern matching on
  {bmRequestType, bRequest} — the first two bytes of the SETUP packet.
  This maps directly to the USB spec request table with no intermediate
  decode signals needed.
  """

  use Hw.Component

  consumes Hw.Interface.USBEndpointOut, as: :ep_out
  consumes Hw.Interface.USBEndpointIn,  as: :ep_in

  clock :clk_48mhz
  input  :rst, 1
  # USB BUS RESET (distinct from the power-on `rst`). The host drives SE0 for
  # ~10 us mid-enumeration (after GET_DESCRIPTOR, before/around SET_ADDRESS) to
  # command every device back to the DEFAULT state: address 0, unconfigured. A
  # device that ignores this keeps its old address while the host re-addresses
  # from scratch -> they disagree and enumeration stalls (silicon: stuck at DEV1,
  # A07, after a 478-cycle SE0 run was seen). This is a level input, held high for
  # the duration of the host's SE0; we clear ONLY the enumeration registers on it
  # (addr/state/ep0/setup), NOT the whole CDC, so the device keeps clocking and
  # immediately answers the post-reset traffic at address 0.
  input  :usb_reset, 1

  # SIE endpoint out interface (SIE → CDC)
  input  :ep_out_data,    8
  input  :ep_out_valid,   1
  input  :ep_out_ep,      4
  input  :ep_out_setup,   1
  input  :ep_out_pkt_end, 1

  # SIE endpoint in interface (CDC → SIE)
  output :ep_in_ep,       4, init: 0
  output :ep_in_pid,      8, init: 0
  output :ep_in_data,     8, init: 0
  output :ep_in_valid,    1, init: 0
  output :ep_in_loaded,   1, init: 0
  input  :ep_in_ready,    1
  input  :ep_in_done,     1
  input  :ep_in_nak,      1

  output :dev_addr,       7, init: 0

  output :rx_data,        8
  output :rx_valid,       1
  input  :rx_ready,       1
  input  :tx_data,        8
  input  :tx_valid,       1
  output :tx_ready,       1

  output :dtr,            1
  output :rts,            1

  # --- Descriptor ROM ---
  # sync_read: true -> registered read -> maps to an ECP5 EBR block RAM, which
  # DOES load its init from the bitstream. An async (combinational) read maps to
  # distributed LUT RAM, which CANNOT be initialized on ECP5 -> the ROM read all
  # zeros on silicon, so every descriptor was blank and enumeration never got
  # past the device descriptor. (Adds 1-cycle read latency; handled below.)
  memory :desc_rom, width: 8, depth: 128, sync_read: true, init: [
    # Device Descriptor (18 bytes)
    0x12, 0x01,           # bLength=18, bDescriptorType=DEVICE
    0x00, 0x02,           # bcdUSB = 2.00
    0x02, 0x00, 0x00,     # bDeviceClass=CDC, bDeviceSubClass=0, bDeviceProtocol=0
    0x40,                 # bMaxPacketSize0 = 64
    0x09, 0x12,           # idVendor = 0x1209 (pid.codes)
    0x01, 0x00,           # idProduct = 0x0001
    0x00, 0x01,           # bcdDevice = 1.00
    0x00, 0x00, 0x00,     # iManufacturer=0, iProduct=0, iSerialNumber=0
    0x01,                 # bNumConfigurations = 1

    # Configuration Descriptor (9 bytes)
    # wTotalLength = 9+9+5+5+4+5+7+9+7+7 = 67 = 0x43
    0x09, 0x02, 0x43, 0x00, 0x02, 0x01, 0x00, 0x80, 0x32,

    # Interface 0 — Communications Class (9 bytes)
    0x09, 0x04, 0x00, 0x00, 0x01, 0x02, 0x02, 0x01, 0x00,

    # Header Functional Descriptor (5 bytes)
    0x05, 0x24, 0x00, 0x10, 0x01,

    # Call Management Functional Descriptor (5 bytes)
    0x05, 0x24, 0x01, 0x00, 0x01,

    # Abstract Control Management Functional Descriptor (4 bytes)
    0x04, 0x24, 0x02, 0x02,

    # Union Functional Descriptor (5 bytes)
    0x05, 0x24, 0x06, 0x00, 0x01,

    # Notification Endpoint — EP2 IN, Interrupt, MPS=8, interval=255ms (7 bytes)
    0x07, 0x05, 0x82, 0x03, 0x08, 0x00, 0xFF,

    # Interface 1 — CDC Data Class (9 bytes)
    0x09, 0x04, 0x01, 0x00, 0x02, 0x0A, 0x00, 0x00, 0x00,

    # EP1 IN — Bulk, MPS=64 (7 bytes)
    0x07, 0x05, 0x81, 0x02, 0x40, 0x00, 0x00,

    # EP1 OUT — Bulk, MPS=64 (7 bytes)
    0x07, 0x05, 0x01, 0x02, 0x40, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
  ]

  # --- Device state ---
  # default(0) addressed(1) configured(2)
  output :dev_state,    2, init: 0
  wire   :pending_addr, 7, init: 0
  wire   :addr_pending, 1, init: 0

  # Diagnostic: expose the decoded request bytes so the health dashboard can show
  # what the CDC actually latched from the SETUP packet (bmRequestType, bRequest).
  output :dbg_req_type, 8, init: 0
  output :dbg_req_code, 8, init: 0
  output :dbg_setup_full, 1, init: 0   # setup_full: all 8 SETUP bytes accumulated
  output :dbg_setup_cnt,  3, init: 0   # live SETUP byte counter
  output :dbg_dispatch_hit, 1, init: 0 # pulses when the SETUP dispatch guard (ep==0 & setup) is true at pkt_end
  output :dbg_live_b0,    8, init: 0   # setup_b0 registered value AT the dispatch cycle
  output :dbg_live_b1,    8, init: 0   # setup_b1 registered value AT the dispatch cycle
  # Competing ep0_state-writer branch activity (for the coincidence gauges):
  output :dbg_descr_active, 1, init: 0 # descriptor-stream branch active (ep_in_loaded & ep_in_ep==0 & ep0_state==1)
  output :dbg_indone,       1, init: 0 # ep_in_done seen (EP-IN-done branch, resets ep0_state->0)
  # --- INSIDE-the-CDC probes (registered in the CDC's OWN clk_48mhz domain) ---
  # dbg_heartbeat: a free-running counter clocked by the CDC's clock, reset by the
  #   CDC's reset. If it never advances on hardware, the CDC is dead-clocked or
  #   held in reset AT ITS OWN PINS (top-level clk/rst binding fault) — which would
  #   freeze every CDC register at once. This is the one thing top-level gauges
  #   (which read output wires) structurally cannot see.
  output :dbg_heartbeat, 8, init: 0
  # dbg_ep0_mirror: a SECOND register set to the same value as ep0_state right
  #   next to the dispatch write, driven out on a DIFFERENT output pin. If the
  #   mirror moves to 2 while the ep0_state output stays 0, the internal write
  #   landed but the ep0_state output net is aliased/duplicate-driven (wiring),
  #   not a lost write.
  output :dbg_ep0_mirror, 2, init: 0
  # GET_DESCRIPTOR request shape, for the completion oracle: which descriptor
  # TYPE (wValue high byte) and how many bytes the host asked for (wLength low 7).
  output :dbg_req_valhi, 8, init: 0
  output :dbg_req_len7,  7, init: 0
  # First two descriptor bytes the CDC actually loads onto the EP0 IN bus, to
  # catch a desc_byte/desc_addr off-by-one (expected device desc = 0x12,0x01).
  output :dbg_fb0, 8, init: 0
  output :dbg_fb1, 8, init: 0
  wire   :dbg_fb_cnt, 2, init: 0

  # --- EP0 state machine ---
  # idle(0) loading_in(1) waiting_done(2) data_out(3)
  output :ep0_state,    2, init: 0
  wire   :ep0_toggle,   1, init: 0

  # SETUP packet buffer — 8 bytes
  wire :setup_b0,       8, init: 0
  wire :setup_b1,       8, init: 0
  wire :setup_b2,       8, init: 0
  wire :setup_b3,       8, init: 0
  wire :setup_b4,       8, init: 0
  wire :setup_b5,       8, init: 0
  wire :setup_b6,       8, init: 0
  wire :setup_b7,       8, init: 0
  wire :setup_cnt,      3, init: 0
  wire :setup_full,     1, init: 0

  # Descriptor streaming
  wire :desc_addr,      7, init: 0
  wire :desc_remain,    7, init: 0
  # MPS-64 packetization: the SIE emits ONE continuous packet for as long as the
  # CDC keeps ep_in_valid high (pull model — see SIE :tx_data). A USB FS control
  # transfer must be chopped into <=64-byte packets. pkt_cnt counts bytes placed
  # in the CURRENT packet (byte0 included, so it starts at 1 at dispatch/re-arm);
  # when it reaches 64 with more data pending we drop ep_in_valid to close the
  # packet and set ep0_more so ep_in_done re-arms the next packet (with the DATA
  # toggle flipped) instead of terminating the transfer. The config descriptor
  # (67 B) thus goes out as 64 B (DATA1) + 3 B (DATA0); the 3-byte short packet
  # naturally terminates the data stage (67 is not a multiple of 64, so no ZLP).
  wire :pkt_cnt,        7, init: 0
  wire :ep0_more,       1, init: 0
  wire :desc_byte,      8
  # Read-ahead ROM ports: the byte at the address we are ABOUT TO commit this
  # cycle. `desc_byte = desc_rom[desc_addr]` reads the OLD (registered) desc_addr,
  # so loading ep_in_data from it on the same cycle desc_addr is written yields
  # the previous transfer's stale byte (0x00 from ROM padding after the first
  # descriptor) — the host saw bLength=0 and refused to configure. These read the
  # NEW address so each loaded byte is correct.
  wire :desc_byte_start, 8   # desc_rom[desc_start]     (first byte of a request)
  wire :desc_byte_next,  8   # desc_rom[desc_addr_next] (next streamed byte)
  wire :desc_rom0,       8   # desc_rom[0] literal probe (expect 0x12 if init live)
  wire :desc_rom1,       8   # desc_rom[1] literal probe (expect 0x01 if init live)

  # EP1 IN state
  wire :ep1_toggle,     1, init: 0
  wire :ep1_in_busy,    1, init: 0

  # OUT path (EP1 → UART)
  wire :out_byte,       8, init: 0
  wire :out_valid,      1, init: 0

  # Line state
  wire :dtr_reg,        1, init: 0
  wire :rts_reg,        1, init: 0

  # SET_LINE_CODING byte counter
  wire :lc_cnt,         3, init: 0

  wire :setup_cnt_next,   3
  wire :desc_addr_next,   7
  wire :desc_remain_next, 7
  wire :lc_cnt_next,      3

  # Decoded request fields — combinational from SETUP buffer
  wire :req_type,     8
  wire :req_code,     8
  wire :req_val_hi,   8
  wire :req_len_lo7,  7
  wire :desc_start,   7
  wire :desc_cap,     7
  wire :send_len,     7
  wire :send_len_m1,  7

  # Typed PID constants — width must be declared explicitly so the elaborator
  # produces correctly-sized mux arms when these are passed through defhw args.
  wire :pid_data0,    8
  wire :pid_data1,    8

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Send a zero-length STATUS response on EP0 and return to idle.
  # Used for: SET_ADDRESS, SET_CONFIGURATION, SET_CONTROL_LINE_STATE,
  # SET_LINE_CODING data-phase completion.
  defhw send_zlp_status() do
    ep_in_ep     = 0
    ep_in_pid    = pid_data1
    ep_in_valid  = 0
    ep_in_loaded = 1
    ep0_state    = 2
  end

  # Begin streaming a descriptor: set start address, byte count, arm EP0 IN.
  # pid_val is the DATA0/DATA1 PID to use for the first packet.
  defhw start_descriptor(addr, len, pid_val) do
    desc_addr    = addr
    desc_remain  = len
    ep0_state    = 1
    ep_in_ep     = 0
    ep_in_pid    = pid_val
    ep_in_data   = desc_byte
    ep_in_valid  = 1
    ep_in_loaded = 1
  end

  # Load a bulk byte into the EP1 IN buffer for the host to read.
  defhw load_ep1_in(pid_val, data_val) do
    ep1_in_busy  = 1
    ep_in_ep     = 1
    ep_in_pid    = pid_val
    ep_in_data   = data_val
    ep_in_valid  = 1
    ep_in_loaded = 1
  end

  # Clear the EP IN bus — called at ep_in_done and on rst.
  defhw clear_ep_in() do
    ep_in_loaded = 0
    ep_in_valid  = 0
  end

  # ---------------------------------------------------------------------------
  # Combinational
  # ---------------------------------------------------------------------------

  comb do
    pid_data0 = 0xC3
    pid_data1 = 0x4B

    setup_cnt_next   = setup_cnt + 1
    desc_addr_next   = desc_addr + 1
    desc_remain_next = desc_remain - 1
    lc_cnt_next      = lc_cnt + 1

    req_type    = setup_b0
    req_code    = setup_b1
    req_val_hi  = setup_b3
    req_len_lo7 = setup_b6[6..0]
    desc_start  = if req_val_hi == 0x01, do: 0, else: 0x12
    # Cap the returned length at the descriptor's own size so a device-descriptor
    # request (host asks for 64 to learn bMaxPacketSize0) returns just 18 bytes —
    # a SHORT packet that terminates the data stage. Returning a full 64 never
    # signals completion, so the host never issues the status stage.
    # Cap at each descriptor's TRUE length: device=18, config=67 (0x43). The host
    # often over-asks (wLength=64 or 255) to "read as much as exists"; returning
    # more than the descriptor holds would stream ROM padding (zeros) as if it were
    # descriptor data. 67 < 128 so it fits the 7-bit send_len; the resulting 3-byte
    # tail packet is a natural short-packet terminator.
    desc_cap    = if req_val_hi == 0x01, do: 18, else: 67
    send_len    = if req_len_lo7 < desc_cap, do: req_len_lo7, else: desc_cap
    # -1: byte0 is loaded at dispatch and NOT counted in desc_remain, so the
    # stream must send (send_len - 1) MORE bytes for send_len total.
    send_len_m1 = send_len - 1

    # Combinational LOGIC ROM. The `memory :desc_rom` read lowers to an async
    # (combinational) memory, which maps to ECP5 distributed LUT-RAM that CANNOT
    # be initialized from the bitstream -> it read all zeros on silicon, so every
    # descriptor was blank and the host never configured us. A case baked into
    # LUTs carries its constants inherently, so it is always correct with no init.
    # desc_byte_next = rom[addr] for the address we advance TO (avoids the
    # same-cycle desc_addr write/read hazard); desc_byte_start = first byte.
    desc_byte       = 0
    desc_rom0       = 0
    desc_rom1       = 0
    desc_byte_start = if desc_start == 0, do: 0x12, else: 0x09
    hdl_case <<desc_addr_next::7>> do
      <<0::7>>  -> desc_byte_next = 0x12
      <<1::7>>  -> desc_byte_next = 0x01
      <<3::7>>  -> desc_byte_next = 0x02
      <<4::7>>  -> desc_byte_next = 0x02
      <<7::7>>  -> desc_byte_next = 0x40
      <<8::7>>  -> desc_byte_next = 0x09
      <<9::7>>  -> desc_byte_next = 0x12
      <<10::7>> -> desc_byte_next = 0x01
      <<13::7>> -> desc_byte_next = 0x01
      <<17::7>> -> desc_byte_next = 0x01
      <<18::7>> -> desc_byte_next = 0x09
      <<19::7>> -> desc_byte_next = 0x02
      <<20::7>> -> desc_byte_next = 0x43
      <<22::7>> -> desc_byte_next = 0x02
      <<23::7>> -> desc_byte_next = 0x01
      <<25::7>> -> desc_byte_next = 0x80
      <<26::7>> -> desc_byte_next = 0x32
      <<27::7>> -> desc_byte_next = 0x09
      <<28::7>> -> desc_byte_next = 0x04
      <<31::7>> -> desc_byte_next = 0x01
      <<32::7>> -> desc_byte_next = 0x02
      <<33::7>> -> desc_byte_next = 0x02
      <<34::7>> -> desc_byte_next = 0x01
      <<36::7>> -> desc_byte_next = 0x05
      <<37::7>> -> desc_byte_next = 0x24
      <<39::7>> -> desc_byte_next = 0x10
      <<40::7>> -> desc_byte_next = 0x01
      <<41::7>> -> desc_byte_next = 0x05
      <<42::7>> -> desc_byte_next = 0x24
      <<43::7>> -> desc_byte_next = 0x01
      <<45::7>> -> desc_byte_next = 0x01
      <<46::7>> -> desc_byte_next = 0x04
      <<47::7>> -> desc_byte_next = 0x24
      <<48::7>> -> desc_byte_next = 0x02
      <<49::7>> -> desc_byte_next = 0x02
      <<50::7>> -> desc_byte_next = 0x05
      <<51::7>> -> desc_byte_next = 0x24
      <<52::7>> -> desc_byte_next = 0x06
      <<54::7>> -> desc_byte_next = 0x01
      <<55::7>> -> desc_byte_next = 0x07
      <<56::7>> -> desc_byte_next = 0x05
      <<57::7>> -> desc_byte_next = 0x82
      <<58::7>> -> desc_byte_next = 0x03
      <<59::7>> -> desc_byte_next = 0x08
      <<61::7>> -> desc_byte_next = 0xFF
      <<62::7>> -> desc_byte_next = 0x09
      <<63::7>> -> desc_byte_next = 0x04
      <<64::7>> -> desc_byte_next = 0x01
      <<66::7>> -> desc_byte_next = 0x02
      <<67::7>> -> desc_byte_next = 0x0A
      <<71::7>> -> desc_byte_next = 0x07
      <<72::7>> -> desc_byte_next = 0x05
      <<73::7>> -> desc_byte_next = 0x81
      <<74::7>> -> desc_byte_next = 0x02
      <<75::7>> -> desc_byte_next = 0x40
      <<78::7>> -> desc_byte_next = 0x07
      <<79::7>> -> desc_byte_next = 0x05
      <<80::7>> -> desc_byte_next = 0x01
      <<81::7>> -> desc_byte_next = 0x02
      <<82::7>> -> desc_byte_next = 0x40
      <<_::7>>  -> desc_byte_next = 0x00
    end

    dtr = dtr_reg
    rts = rts_reg

    rx_data  = out_byte
    rx_valid = out_valid
    tx_ready = bnot(ep1_in_busy)

    dbg_req_type = req_type
    dbg_req_code = req_code
    dbg_setup_full = setup_full
    dbg_setup_cnt  = setup_cnt
    # The two OTHER branches that write ep0_state, exposed live so the top-level
    # coincidence gauges can test whether either fires the same cycle as dispatch.
    dbg_descr_active = ep_in_loaded and ep_in_ep == 0 and ep0_state == 1
    dbg_indone       = ep_in_done
    dbg_req_valhi    = req_val_hi
    dbg_req_len7     = req_len_lo7
  end

  # ---------------------------------------------------------------------------
  # Sequential
  # ---------------------------------------------------------------------------

  on :clk_48mhz do
    # --- Heartbeat: free-running in the CDC's own clock/reset. Placed FIRST so
    # nothing gates it. If this is frozen on hardware, the CDC isn't clocking. ---
    if rst do
      dbg_heartbeat = 0
    else
      dbg_heartbeat = dbg_heartbeat + 1
    end

    if rst do
      dev_state    = 0
      dev_addr     = 0
      pending_addr = 0
      addr_pending = 0
      ep0_state    = 0
      ep0_toggle   = 0
      setup_cnt    = 0
      setup_full   = 0
      setup_b0     = 0
      setup_b1     = 0
      setup_b2     = 0
      setup_b3     = 0
      setup_b4     = 0
      setup_b5     = 0
      setup_b6     = 0
      setup_b7     = 0
      desc_addr    = 0
      desc_remain  = 0
      pkt_cnt      = 0
      ep0_more     = 0
      dbg_fb0      = 0
      dbg_fb1      = 0
      dbg_fb_cnt   = 0
      ep1_toggle   = 0
      ep1_in_busy  = 0
      out_byte     = 0
      out_valid    = 0
      dtr_reg      = 0
      rts_reg      = 0
      lc_cnt       = 0
      ep_in_ep     = 0
      ep_in_pid    = 0
      ep_in_data   = 0
      clear_ep_in()
    else

      out_valid = 0

      # -------------------------------------------------------
      # USB BUS RESET — host drove SE0 to command us back to DEFAULT state.
      # Clear ONLY the enumeration registers (address 0, unconfigured, EP0 idle,
      # SETUP buffer empty). The CDC keeps clocking; everything else (UART bridge,
      # heartbeat) is untouched. This makes the device present a fresh address-0
      # device to the SET_ADDRESS that follows the host's reset, instead of
      # stalling at its stale post-GET_DESCRIPTOR address. Placed FIRST in the
      # else-branch so it takes priority over same-cycle protocol handling.
      # -------------------------------------------------------
      if usb_reset do
        dev_addr     = 0
        dev_state    = 0
        pending_addr = 0
        addr_pending = 0
        ep0_state    = 0
        ep0_toggle   = 0
        setup_cnt    = 0
        setup_full   = 0
        desc_remain  = 0
        pkt_cnt      = 0
        ep0_more     = 0
        clear_ep_in()
      end

      # -------------------------------------------------------
      # EP IN done — host ACKed our IN packet
      # -------------------------------------------------------
      if ep_in_done do
        clear_ep_in()

        # Apply pending address after STATUS ZLP for SET_ADDRESS
        if addr_pending do
          dev_addr     = pending_addr
          addr_pending = 0
          dev_state    = 1
        end

        hdl_case <<ep_in_ep::4>> do
          <<0::4>> ->
            # EP0: the host ACKed this IN data packet. Flip the DATA toggle for the
            # next packet either way. If ep0_more is set we are MID-transfer (a
            # 64-byte packet just closed with bytes still pending) — re-arm the next
            # packet's first byte with the flipped toggle rather than going idle.
            # bnot(ep0_toggle) is the NEW (post-flip) toggle: 0 -> DATA0, 1 -> DATA1.
            ep0_toggle = bnot(ep0_toggle)
            if ep0_more do
              # Re-arm continuation packet. desc_addr still points at the last byte
              # of the packet we just sent, so desc_byte_next = rom[desc_addr+1] is
              # this packet's first byte; commit desc_addr/desc_remain to it too.
              ep0_more     = 0
              pkt_cnt      = 1
              desc_addr    = desc_addr_next
              desc_remain  = desc_remain_next
              ep0_state    = 1
              ep_in_ep     = 0
              ep_in_pid    = if bnot(ep0_toggle), do: pid_data1, else: pid_data0
              ep_in_data   = desc_byte_next
              ep_in_valid  = 1
              ep_in_loaded = 1
            else
              ep0_state  = 0
            end

          <<1::4>> ->
            # EP1: bulk IN sent
            ep1_in_busy = 0
            ep1_toggle  = bnot(ep1_toggle)
        end
      end

      # -------------------------------------------------------
      # EP0 IN streaming — feed descriptor bytes while loading
      # -------------------------------------------------------
      if ep_in_loaded and ep_in_ep == 0 and ep0_state == 1 do
        if ep_in_ready do
          if desc_remain > 0 do
            if pkt_cnt == 64 do
              # Current packet already holds 64 bytes (byte0 + 63 streamed) but the
              # transfer is not done. Close THIS packet by dropping ep_in_valid so
              # the SIE appends CRC+EOP, and flag ep0_more so the ep_in_done handler
              # re-arms the next packet (flipped toggle). Do NOT advance
              # desc_addr/desc_remain: desc_addr must stay on the last sent byte so
              # the re-arm's desc_byte_next = rom[desc_addr+1] is the next byte.
              ep_in_valid = 0
              ep0_more    = 1
              ep0_state   = 2
            else
              ep_in_data  = desc_byte_next   # rom[desc_addr+1], the byte we advance TO
              ep_in_valid = 1
              desc_addr   = desc_addr_next
              desc_remain = desc_remain_next
              pkt_cnt     = pkt_cnt + 1
              if dbg_fb_cnt == 1 do
                dbg_fb1    = desc_byte_next   # 2nd byte we stream (should be 0x01 for device desc)
                dbg_fb_cnt = 2
              end
            end
          else
            ep_in_valid = 0
            ep0_state   = 2
          end
        end
      end

      # -------------------------------------------------------
      # EP OUT byte received
      # -------------------------------------------------------
      if ep_out_valid do
        # SETUP byte accumulation — pack into 8-byte buffer
        if ep_out_ep == 0 and ep_out_setup and bnot(setup_full) do
          case setup_cnt do
            0 -> setup_b0 = ep_out_data
            1 -> setup_b1 = ep_out_data
            2 -> setup_b2 = ep_out_data
            3 -> setup_b3 = ep_out_data
            4 -> setup_b4 = ep_out_data
            5 -> setup_b5 = ep_out_data
            6 -> setup_b6 = ep_out_data
            7 -> setup_b7 = ep_out_data
          end
          if setup_cnt < 7 do
            setup_cnt = setup_cnt_next
          else
            setup_full = 1
          end
        end

        # SET_LINE_CODING data bytes — count and discard
        if ep_out_ep == 0 and bnot(ep_out_setup) and ep0_state == 3 do
          lc_cnt = lc_cnt_next
        end

        # EP1 bulk OUT → UART bridge
        if ep_out_ep == 1 and dev_state == 2 do
          out_byte  = ep_out_data
          out_valid = 1
        end
      end

      # -------------------------------------------------------
      # EP OUT packet end — reset the SETUP byte counter
      # -------------------------------------------------------
      if ep_out_pkt_end and ep_out_setup do
        setup_cnt  = 0
        setup_full = 0
      end

      # -------------------------------------------------------
      # SETUP dispatch on {bmRequestType, bRequest}
      #
      # FLATTENED to a SINGLE top-level guard (was nested `if ep_out_pkt_end do
      # if ep_out_ep==0 and ep_out_setup do hdl_case`). At if>if>case-arm depth
      # the elaborator DROPPED the arms' writes to the EP-IN bus
      # (ep_in_loaded/ep_in_valid/ep_in_ep/pid/data) from those signals' mux
      # trees while keeping ep0_state — proven on silicon (DS1/L0005 yet MV0/EPL0)
      # and in the netlist (ep_in_loaded cone had ZERO dispatch-match nodes).
      # This single-if form is one level shallower and the writes commit.
      # -------------------------------------------------------
      dbg_dispatch_hit = ep_out_pkt_end and ep_out_ep == 0 and ep_out_setup
      if ep_out_pkt_end and ep_out_ep == 0 and ep_out_setup do
        dbg_live_b0 = setup_b0
        dbg_live_b1 = setup_b1
        hdl_case <<req_type::8, req_code::8>> do

          <<0x80::8, 0x06::8>> ->
            # GET_DESCRIPTOR — stream descriptor bytes to host (INLINED start_descriptor)
            # The DATA stage of a control READ ALWAYS starts with DATA1 (the SETUP
            # was DATA0). The old `if(ep0_toggle, ...)` used whatever parity the
            # toggle had left over from prior transfers, so the device-descriptor's
            # first packet came out DATA1 or DATA0 depending on history; whenever it
            # landed on DATA0 the host rejected the data stage (wrong toggle), never
            # sent the STATUS OUT, and enumeration stalled (oracle: out_ep0=0, host
            # retries). Force DATA1 and seed ep0_toggle=1 so a hypothetical next
            # packet would correctly be DATA0.
            desc_addr    = desc_start
            desc_remain  = send_len_m1
            pkt_cnt      = 1              # byte0 is loaded here; counts toward the 64-byte packet cap
            ep0_more     = 0
            ep0_state    = 1
            ep0_toggle   = 1
            ep_in_ep     = 0
            ep_in_pid    = pid_data1
            ep_in_data   = desc_byte_start   # rom[desc_start], correct first byte
            ep_in_valid  = 1
            ep_in_loaded = 1
            dbg_fb0      = desc_byte_start   # 1st byte we load (should be 0x12 for device desc)
            dbg_fb_cnt   = 1

          <<0x00::8, 0x05::8>> ->
            # SET_ADDRESS — ZLP STATUS, apply addr on ep_in_done.
            pending_addr = setup_b2[6..0]
            addr_pending = 1
            ep_in_ep     = 0
            ep_in_pid    = pid_data1
            ep_in_valid  = 0
            ep_in_loaded = 1
            ep0_state    = 2
            dbg_ep0_mirror = 2   # mirror the intended write on a separate pin

          <<0x00::8, 0x09::8>> ->
            # SET_CONFIGURATION — mark configured, ZLP STATUS (INLINED send_zlp_status)
            dev_state    = 2
            ep_in_ep     = 0
            ep_in_pid    = pid_data1
            ep_in_valid  = 0
            ep_in_loaded = 1
            ep0_state    = 2

          <<0x21::8, 0x22::8>> ->
            # SET_CONTROL_LINE_STATE — capture DTR/RTS, ZLP STATUS (INLINED)
            dtr_reg      = setup_b2[0..0]
            rts_reg      = setup_b2[1..1]
            ep_in_ep     = 0
            ep_in_pid    = pid_data1
            ep_in_valid  = 0
            ep_in_loaded = 1
            ep0_state    = 2

          <<0x21::8, 0x20::8>> ->
            # SET_LINE_CODING — accept 7 data bytes, then ZLP STATUS
            lc_cnt    = 0
            ep0_state = 3

          <<0xA1::8, 0x21::8>> ->
            # GET_LINE_CODING — send 7 zero bytes (INLINED start_descriptor)
            desc_addr    = 0x7F
            desc_remain  = 7
            pkt_cnt      = 1     # 7 bytes < 64, single packet; init the packet counter
            ep0_more     = 0
            ep0_state    = 1
            ep_in_ep     = 0
            ep_in_pid    = pid_data1
            ep_in_data   = desc_byte
            ep_in_valid  = 1
            ep_in_loaded = 1

          <<_::8, _::8>> ->
            # Unknown request — ignore, SIE will NAK next IN. This catch-all is now
            # correctly lowered as the case DEFAULT (lowest priority), so it no
            # longer clobbers the specific arms above. (See the wildcard-clobber
            # hardening in Sequential.build_mux_from_statements.)
            nil

        end
      end

      # SET_LINE_CODING data phase complete (7 non-setup bytes received on EP0)
      if ep_out_pkt_end and ep_out_ep == 0 and bnot(ep_out_setup) and ep0_state == 3 do
        lc_cnt = 0
        send_zlp_status()
      end

      # -------------------------------------------------------
      # EP1 IN — load UART TX data when available and not busy
      # -------------------------------------------------------
      if tx_valid and bnot(ep1_in_busy) and dev_state == 2 do
        load_ep1_in(if(ep1_toggle, do: pid_data1, else: pid_data0), tx_data)
      end

    end
  end

end
