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
  memory :desc_rom, width: 8, depth: 128, init: [
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
  wire :desc_byte,      8

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

    desc_byte = desc_rom[desc_addr]

    dtr = dtr_reg
    rts = rts_reg

    rx_data  = out_byte
    rx_valid = out_valid
    tx_ready = bnot(ep1_in_busy)
  end

  # ---------------------------------------------------------------------------
  # Sequential
  # ---------------------------------------------------------------------------

  on :clk_48mhz do
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
            # EP0: toggle PID, return to idle
            ep0_toggle = bnot(ep0_toggle)
            ep0_state  = 0

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
            ep_in_data  = desc_byte
            ep_in_valid = 1
            desc_addr   = desc_addr_next
            desc_remain = desc_remain_next
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
      # EP OUT packet end — process completed SETUP requests
      # -------------------------------------------------------
      if ep_out_pkt_end do

        if ep_out_setup do
          setup_cnt  = 0
          setup_full = 0
        end

        # Dispatch on SETUP {bmRequestType, bRequest}
        if ep_out_ep == 0 and ep_out_setup do
          hdl_case <<req_type::8, req_code::8>> do

            <<0x80::8, 0x06::8>> ->
              # GET_DESCRIPTOR — stream descriptor bytes to host
              start_descriptor(desc_start, req_len_lo7, if(ep0_toggle, do: pid_data1, else: pid_data0))

            <<0x00::8, 0x05::8>> ->
              # SET_ADDRESS — ZLP STATUS, apply addr on ep_in_done.
              # INLINE send_zlp_status() body: a defhw CALL inside this nested hdl_case
              # only partially commits (ep0_state set, but ep_in_loaded dropped) — same
              # framework class as the on-in-defaults bug. Direct assigns in this clause
              # DO commit (addr_pending did), so inline them.
              pending_addr = setup_b2[6..0]
              addr_pending = 1
              ep_in_ep     = 0
              ep_in_pid    = pid_data1
              ep_in_valid  = 0
              ep_in_loaded = 1
              ep0_state    = 2

            <<0x00::8, 0x09::8>> ->
              # SET_CONFIGURATION — mark configured, ZLP STATUS
              dev_state = 2
              send_zlp_status()

            <<0x21::8, 0x22::8>> ->
              # SET_CONTROL_LINE_STATE — capture DTR/RTS, ZLP STATUS
              dtr_reg = setup_b2[0..0]
              rts_reg = setup_b2[1..1]
              send_zlp_status()

            <<0x21::8, 0x20::8>> ->
              # SET_LINE_CODING — accept 7 data bytes, then ZLP STATUS
              lc_cnt    = 0
              ep0_state = 3

            <<0xA1::8, 0x21::8>> ->
              # GET_LINE_CODING — send 7 zero bytes (line coding not stored)
              start_descriptor(0x7F, 7, pid_data1)

            <<_::8, _::8>> ->
              # Unknown request — ignore, SIE will NAK next IN
              nil

          end
        end

        # SET_LINE_CODING data phase complete (7 bytes received)
        if ep_out_ep == 0 and bnot(ep_out_setup) and ep0_state == 3 do
          lc_cnt = 0
          send_zlp_status()
        end
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
