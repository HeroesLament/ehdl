defmodule Hw.USB.SIE do
  @moduledoc """
  USB Serial Interface Engine — RX and TX FSMs with strict signal ownership.

  ## Signal ownership

  RX FSM owns: rx_state, all RX datapath, token latches, ep0/1 buffers,
               send_handshake, handshake_pid, tx_req/ep/pid,
               ep_in_done, ep_in_nak, ep_out_* pulses, rx_crc16_reg, crc5_reg

  TX FSM owns: tx_state, all TX datapath, tx_is_handshake, tx_crc16_reg,
               ep_in_ready

  CRC16 hardware: comb mux selects tx_crc16_reg when sending, rx_crc16_reg otherwise.
  TX requests: RX FSM sets sticky tx_req=1; TX FSM pulses tx_data_ack=1 to clear it.
  Handshake:   RX FSM sets sticky send_handshake=1; TX FSM pulses tx_hs_ack=1 to clear it.

  ## RX states:  idle, recv_pid, recv_data, recv_token
  ## TX states:  idle, tx_sync, tx_pid, tx_data, tx_crc, tx_eop

  ## PID values (USB 2.0 spec)

  Token:     OUT=0xE1  IN=0x69  SOF=0xA5  SETUP=0x2D
  Data:      DATA0=0xC3  DATA1=0x4B
  Handshake: ACK=0xD2  NAK=0x5A  STALL=0x1E
  """

  use Hw.Component

  provides Hw.Interface.USBEndpointOut, as: :ep_out
  provides Hw.Interface.USBEndpointIn,  as: :ep_in

  clock :clk_48mhz
  input  :rst,        1

  input  :dev_addr,   7

  # PHY interface
  input  :phy_rx_valid,   1
  input  :phy_rx_data,    1
  input  :phy_rx_se0,     1
  input  :phy_rx_active,  1
  input  :phy_rx_bit0,    1   # PID bit-0 alignment strobe from PHY
  input  :phy_rx_pid_done, 1  # PID last-bit strobe from PHY
  output :phy_tx_valid,   1
  output :phy_tx_data,    1
  output :phy_tx_se0,     1
  input  :phy_tx_ready,   1

  # Diagnostic outputs
  output :rx_state_out,       2
  output :tx_state_out,       3
  output :send_handshake_out, 1
  output :dbg_accept_out,     1   # pulses when a token passes CRC5+addr-match (TX-arm precondition)

  # USBEndpointOut (SIE → CDC)
  output :ep_out_data,    8, init: 0
  output :ep_out_valid,   1, init: 0
  output :ep_out_ep,      4, init: 0
  output :ep_out_setup,   1, init: 0
  output :ep_out_pkt_end, 1, init: 0

  # USBEndpointIn (CDC → SIE)
  input  :ep_in_ep,       4
  input  :ep_in_pid,      8
  input  :ep_in_data,     8
  input  :ep_in_valid,    1
  input  :ep_in_loaded,   1
  output :ep_in_ready,    1, init: 0
  output :ep_in_done,     1, init: 0
  output :ep_in_nak,      1, init: 0

  # CRC16 shared hardware — comb-muxed from RX or TX register
  wire   :crc16_reg,   16
  instance :crc16, Hw.USB.CRC16,
    crc_in:  :crc16_reg,
    bit_in:  :crc16_bit_in,
    crc_out: :crc16_next,
    valid:   :crc16_valid

  instance :crc5, Hw.USB.CRC5,
    crc_in:  :crc5_reg,
    bit_in:  :crc5_bit_in,
    crc_out: :crc5_next,
    valid:   :crc5_valid

  # ---------------------------------------------------------------------------
  # RX datapath registers (RX FSM owned)
  # ---------------------------------------------------------------------------
  wire :bit_cnt,       4, init: 0   # widened 3->4: recv_pid completion needs bit_cnt==8 (oracle-derived)
  wire :byte_shift,    8, init: 0
  wire :rx_pid,        8, init: 0
  wire :rx_addr,       7, init: 0
  wire :rx_ep,         4, init: 0
  wire :token_bits,    4, init: 0
  wire :rx_crc16_reg, 16, init: 0xFFFF
  wire :crc5_reg,      5, init: 0x1F
  wire :token_addr_match_reg, 1, init: 0
  wire :token_is_in_reg,      1, init: 0
  wire :token_is_out_reg,     1, init: 0
  wire :token_is_setup_reg,   1, init: 0
  wire :token_ep_reg,         4, init: 0

  # Debug instrumentation — the SIE narrates its own decisions so we read them
  # directly instead of reconstructing from byte_shift offline.
  wire :dbg_last_pid,   8, init: 0   # rx_pid latched at recv_pid classification
  wire :dbg_route,      2, init: 0   # 0=idle 1=token 2=data (recv_pid decision)
  wire :dbg_tok_fail,   2, init: 0   # token accept: 0=ok 1=crc5-fail 2=addr-mismatch
  wire :dbg_pid_raw,    8, init: 0   # raw bits shifted in during recv_pid, in ARRIVAL order (bit0 first)
  wire :dbg_pid_bc,     4, init: 0   # count of bits shifted this recv_pid

  # --- Full white-box receive-FSM instrumentation ---------------------------
  wire :dbg_pkt_num,    8, init: 0   # increments every time we ENTER recv_pid (packet index)
  wire :dbg_entry_bit,  1, init: 0   # the FIRST phy_rx_data bit captured at idle->recv_pid entry
  wire :dbg_entry_via,  2, init: 0   # how recv_pid was entered: 1=idle-entry, 2=token-loopback, 3=data-loopback
  wire :dbg_pid_done,   8, init: 0   # the fully-assembled PID at completion (arrival-order raw)
  wire :dbg_pid_bits,   8, init: 0   # per-packet arrival bits, latched at completion (freezes dbg_pid_raw)
  wire :dbg_crc5_at,    5, init: 0   # crc5 residual latched at token completion
  wire :dbg_rxaddr_at,  7, init: 0   # rx_addr latched at token completion
  wire :dbg_devaddr_at, 7, init: 0   # dev_addr seen at token completion (for match compare)
  # Blocker-1 accept-path probes
  wire :dbg_rxpid_at,   8, init: 0   # rx_pid value AT the token_bits==15 accept point
  wire :dbg_accept,     1, init: 0   # pulses 1 on the cycle a token is accepted
  wire :dbg_setup_at,   1, init: 0   # token_is_setup_reg value set at accept
  wire :dbg_class_bits, 2, init: 0   # the {pid[1],pid[0]} type bits used for classification
  wire :dbg_last_state, 3, init: 0   # rx_state on the previous cycle (see transitions)
  wire :dbg_active_cnt, 8, init: 0   # count of phy_rx_valid pulses seen while in recv_pid this packet

  # --- Layer 1: completion-decision shadow (latched INSIDE if bit_cnt==7) -----
  wire :dbg_bc_old,   3, init: 0     # bit_cnt the `if` actually read (old/registered)
  wire :dbg_bc_next,  3, init: 0     # bit_cnt_next (comb old+1)
  wire :dbg_bs_pre,   8, init: 0     # byte_shift, registered pre-shift
  wire :dbg_bs_post,  8, init: 0     # {phy_rx_data, byte_shift[7:1]} — comb value committing
  wire :dbg_rxdata_at,1, init: 0     # phy_rx_data at completion
  wire :dbg_bitidx_at,4, init: 0     # dbg_bit_idx at completion (bits since entry)

  # --- Layer 2: per-cycle trajectory (updated every recv_pid rx_valid) --------
  wire :dbg_bit_idx,  4, init: 0     # monotonic bits-since-entry this packet
  wire :dbg_bc_reg,   3, init: 0     # bit_cnt registered value this cycle
  wire :dbg_bcn_comb, 3, init: 0     # bit_cnt_next comb value this cycle
  wire :dbg_bs_reg,   8, init: 0     # byte_shift registered this cycle
  wire :dbg_bs_cmb,   8, init: 0     # post-shift comb value this cycle
  wire :dbg_rxd_stream, 8, init: 0   # phy_rx_data captured on each rx_valid, EXACTLY as SIE consumes it

  # --- 5-item probe set (Zabbix-style calculated items) -----------------------
  # Item 2: bits.per_entry — highest dbg_bit_idx reached before leaving recv_pid.
  #   Peak-holds within an entry; item 1 (dbg_pkt_num) marks entry boundaries.
  wire :dbg_bit_ceiling, 4, init: 0
  # Item 5: reset.residue — byte_shift / bit_cnt as READ at the idle->recv_pid
  #   entry cycle (old registered values, before the reset assignment commits).
  #   If reset-on-entry is defeated by old-value-read semantics, these are nonzero.
  wire :dbg_entry_bs,  8, init: 0    # byte_shift value observed at entry (pre-clear)
  wire :dbg_entry_bc,  4, init: 0    # bit_cnt   value observed at entry (pre-clear)

  wire :ep0_in_loaded, 1, init: 0
  wire :ep0_in_pid,    8, init: 0
  wire :ep1_in_loaded, 1, init: 0
  wire :ep1_in_pid,    8, init: 0

  # RX→TX handshake trigger (RX sets sticky, TX acknowledges via tx_hs_ack)
  wire :send_handshake, 1, init: 0
  wire :handshake_pid,  8, init: 0


  # RX→TX data request (RX sets sticky, TX acknowledges via tx_data_ack)
  wire :tx_req,     1, init: 0
  wire :tx_req_ep,  4, init: 0
  wire :tx_req_pid, 8, init: 0

  # TX→RX acknowledgments (TX-owned pulses, RX clears the request on ack)
  wire :tx_data_ack, 1, init: 0
  wire :tx_hs_ack,   1, init: 0

  # ---------------------------------------------------------------------------
  # TX datapath registers (TX FSM owned)
  # ---------------------------------------------------------------------------
  wire :tx_shift,        8, init: 0
  wire :tx_bit_cnt,      3, init: 0
  wire :tx_crc_cnt,      4, init: 0
  wire :tx_crc_buf,     16, init: 0
  wire :tx_pid_reg,      8, init: 0
  wire :tx_ep_reg,       4, init: 0
  wire :tx_is_handshake, 1, init: 0
  wire :tx_crc16_reg,   16, init: 0xFFFF

  # ---------------------------------------------------------------------------
  # CRC wires
  # ---------------------------------------------------------------------------
  wire :crc16_bit_in, 1
  wire :crc5_bit_in,  1
  wire :crc16_next,  16
  wire :crc5_next,    5
  wire :crc16_valid,  1
  wire :crc5_valid,   1

  # ---------------------------------------------------------------------------
  # Combinational helpers
  # ---------------------------------------------------------------------------
  wire :byte_done,       1
  wire :assembled,       8
  wire :assembled_pid,   8
  wire :tx_sending,      1
  wire :tx_cur_bit,      1
  wire :bit_cnt_next,    4
  wire :token_bits_next, 4
  wire :tx_bit_cnt_next, 3
  wire :tx_crc_cnt_next, 4
  wire :one,             1

  comb do
    one             = 1
    bit_cnt_next    = bit_cnt + 1
    token_bits_next = token_bits + 1
    tx_bit_cnt_next = tx_bit_cnt + 1
    tx_crc_cnt_next = tx_crc_cnt + 1
    byte_done = (bit_cnt == 7 and phy_rx_valid)
    assembled = byte_shift
    # Correctly-endian PID at the byte_done moment: byte_shift holds the 7 bits seen
    # so far MSB-first and phy_rx_data is the 8th (final) bit. USB is LSB-first, so
    # the true PID is the bit-reversal of {byte_shift[6:0], phy_rx_data} — the same
    # rev8 expression recv_pid uses for rx_pid. A received ACK (0xD2 on the wire)
    # lands in byte_shift as 0x4B, so the old `assembled == 0xD2` never matched.
    assembled_pid = {phy_rx_data, byte_shift[0..0], byte_shift[1..1], byte_shift[2..2], byte_shift[3..3], byte_shift[4..4], byte_shift[5..5], byte_shift[6..6]}

    tx_sending  = (tx_state != 0)
    tx_cur_bit  = tx_shift[0..0]

    # Mux CRC16 register: TX path while sending, RX path otherwise
    crc16_reg    = if tx_sending, do: tx_crc16_reg, else: rx_crc16_reg
    crc16_bit_in = if tx_sending, do: tx_cur_bit,   else: phy_rx_data
    crc5_bit_in  = phy_rx_data

    phy_tx_valid = tx_sending
    phy_tx_data  = tx_cur_bit
    phy_tx_se0   = (tx_state == 5)  # :tx_eop index

    rx_state_out       = rx_state
    tx_state_out       = tx_state
    send_handshake_out = send_handshake
    dbg_accept_out     = dbg_accept
  end

  # ---------------------------------------------------------------------------
  # Hardware helpers
  # ---------------------------------------------------------------------------

  defhw clear_rx() do
    bit_cnt      = 0
    byte_shift   = 0
    rx_pid       = 0
    rx_crc16_reg = 0
    crc5_reg     = 0
    token_bits   = 0
  end

  defhw arm_handshake(pid) do
    send_handshake = 1
    handshake_pid  = pid
  end


  defhw arm_tx(ep, pid) do
    tx_req     = 1
    tx_req_ep  = ep
    tx_req_pid = pid
  end

  defhw clear_token_regs() do
    token_addr_match_reg = 0
    token_is_in_reg      = 0
    token_is_out_reg     = 0
    token_is_setup_reg   = 0
  end

  defhw start_tx(ep, pid) do
    tx_state   = 1   # :tx_sync
    tx_shift   = 0x80
    tx_bit_cnt = 0
    tx_ep_reg  = ep
    tx_pid_reg = pid
  end

  defhw tx_shift_bit() do
    tx_shift   = {one, tx_shift[7..1]}
    tx_bit_cnt = tx_bit_cnt_next
  end

  # ---------------------------------------------------------------------------
  # RX state machine
  # ---------------------------------------------------------------------------

  fsm :rx_state, clock: :clk_48mhz, reset: :rst, init: :idle do

    defaults do
      ep_in_done     = 0
      ep_in_nak      = 0
      ep_out_valid   = 0
      ep_out_pkt_end = 0   # default low; the pulse is emitted in the recv_data arm's
                           # on-phy_rx_se0 (where assignments commit), 1-cycle strobe.

      # Clear sticky request flags when TX FSM acknowledges
      if tx_data_ack do tx_req         = 0 end
      if tx_hs_ack   do send_handshake = 0 end

      # EP IN buffer load from CDC
      if ep_in_loaded do
        if ep_in_ep == 0 do
          ep0_in_loaded = 1
          ep0_in_pid    = ep_in_pid
        end
        if ep_in_ep == 1 do
          ep1_in_loaded = 1
          ep1_in_pid    = ep_in_pid
        end
      end

      # Host ACK: host ACKed our IN data packet
      if rx_state == 1 and byte_done and
         assembled_pid == 0xD2 and tx_state == 0 and
         bnot(send_handshake) do
        if tx_ep_reg == 0 do ep0_in_loaded = 0 end
        if tx_ep_reg == 1 do ep1_in_loaded = 0 end
        ep_in_done = 1
      end

      # EOP: optionally ACK good OUT/SETUP, then reset RX
      on phy_rx_se0 do
        if rx_state == 2 and token_addr_match_reg and
           (token_is_out_reg or token_is_setup_reg) and
           bxor(rx_crc16_reg[15..0], 0xB001) == 0 do
          arm_handshake(0xD2)
          # ep_out_pkt_end is emitted from the recv_data case arm's on-phy_rx_se0
          # (assignments there commit; here in defaults they were dropped).
        end
        clear_rx()
        next :idle
      end
    end

    case rx_state do

      :idle ->
        on phy_rx_bit0 do
          # BIT-0 ALIGNED ENTRY. Enter recv_pid ONLY on the PHY's rx_bit0 strobe (the
          # rx_valid carrying PID bit 0), not on active&valid which could lead by 1-2
          # sample phases and shift leading zeros (the variable-offset bug that
          # scrambled decodes). Now every packet starts assembly at bit 0 uniformly.
          # Rebuild: recv_pid owns ALL 8 shifts. Entry does NOT shift — it only
          # arms the counter AND clears byte_shift (reset-on-entry). Without the
          # clear, recv_pid started from the PREVIOUS packet's residue (measured
          # byte_shift=0x29 at bc=0) and never assembled correctly.
          # (init=0, complete at bit_cnt==8; oracle-derived.)
          # Item 5: capture residue BEFORE the clear. These RHS reads see the
          # OLD registered values (cycle-start), so they reveal whatever
          # byte_shift/bit_cnt actually held when recv_pid was (re)armed.
          dbg_entry_bs = byte_shift
          dbg_entry_bc = bit_cnt
          # LSB-FIRST ENTRY. USB is LSB-first: the first received bit is the LEAST
          # significant. Entry shifts bit 0 into LSB (position 0) and enters recv_pid
          # with bit_cnt=1. recv_pid then shifts bits 1..7 LEFT (new bit -> LSB), and
          # the bit_cnt_next==8 latch fires with the correctly-ordered PID.
          # MUST be explicitly 8-bit: a bare 1-bit RHS collapses the FSM mux width to
          # 1 and truncates every byte_shift assignment (IR: _mux width=1). LSB-first
          # seed = {7 zero bits, bit0} so bit 0 lands in the LSB, register stays 8-bit.
          byte_shift = {0[6..0], phy_rx_data}   # bit 0 into LSB, 8-bit
          bit_cnt    = 1                         # entry consumed bit 0
          dbg_rxd_stream = {0[6..0], phy_rx_data}
          # DEBUG
          dbg_pkt_num   = dbg_pkt_num + 1
          dbg_entry_bit = phy_rx_data
          dbg_entry_via = 1
          dbg_active_cnt = 1
          dbg_bit_idx    = 1
          dbg_bit_ceiling = 1   # Item 2: reset peak-hold at each entry
          next :recv_pid
        end

      :recv_pid ->
        on phy_rx_valid do
          byte_shift = {byte_shift[6..0], phy_rx_data}
          bit_cnt    = bit_cnt_next
          dbg_active_cnt = dbg_active_cnt + 1
          dbg_bit_idx    = dbg_bit_idx + 1
          dbg_bit_ceiling = dbg_bit_idx + 1
          dbg_rxd_stream = {dbg_rxd_stream[6..0], phy_rx_data}
          if bit_cnt_next == 8 do
            # Latch the COMB PID, not registered byte_shift. Strobe-alignment oracle:
            # at this cycle (old bit_cnt==7) registered byte_shift is 1 shift behind
            # (0x52), while {byte_shift[6:0], phy_rx_data} = the true LSB-first PID
            # ENDIANNESS FIX (oracle-proven): assembly is MSB-first, USB is LSB-first.
            # rev8-check showed uniform rev8 maps ALL 32 packets to valid PIDs (32/32
            # vs 18/32 identity). The comb {byte_shift[6:0], rxd} has bit order
            # bs6..bs0,rxd (MSB..LSB); the true PID is its bit-reversal =
            # {rxd, bs0, bs1, bs2, bs3, bs4, bs5, bs6}. Latch that.
            rx_pid  = {phy_rx_data, byte_shift[0..0], byte_shift[1..1], byte_shift[2..2], byte_shift[3..3], byte_shift[4..4], byte_shift[5..5], byte_shift[6..6]}
            dbg_last_pid = {phy_rx_data, byte_shift[0..0], byte_shift[1..1], byte_shift[2..2], byte_shift[3..3], byte_shift[4..4], byte_shift[5..5], byte_shift[6..6]}
            dbg_pid_bits = {phy_rx_data, byte_shift[0..0], byte_shift[1..1], byte_shift[2..2], byte_shift[3..3], byte_shift[4..4], byte_shift[5..5], byte_shift[6..6]}
            dbg_bitidx_at = dbg_bit_idx
            # Route on the REVERSED PID inline (rx_pid is registered -> reads old value
            # same-cycle, so cannot be used in these conditions).
            if {phy_rx_data, byte_shift[0..0], byte_shift[1..1], byte_shift[2..2], byte_shift[3..3], byte_shift[4..4], byte_shift[5..5], byte_shift[6..6]} == 0x2D or
               {phy_rx_data, byte_shift[0..0], byte_shift[1..1], byte_shift[2..2], byte_shift[3..3], byte_shift[4..4], byte_shift[5..5], byte_shift[6..6]} == 0x69 or
               {phy_rx_data, byte_shift[0..0], byte_shift[1..1], byte_shift[2..2], byte_shift[3..3], byte_shift[4..4], byte_shift[5..5], byte_shift[6..6]} == 0xE1 do
              crc5_reg = 0x1F
              bit_cnt  = 0   # FRAMING: reset so recv_token/data byte counting starts
              dbg_route = 1   # token (SETUP/IN/OUT)
              next :recv_token
            else
              if {phy_rx_data, byte_shift[0..0], byte_shift[1..1], byte_shift[2..2], byte_shift[3..3], byte_shift[4..4], byte_shift[5..5], byte_shift[6..6]} == 0xC3 or
                 {phy_rx_data, byte_shift[0..0], byte_shift[1..1], byte_shift[2..2], byte_shift[3..3], byte_shift[4..4], byte_shift[5..5], byte_shift[6..6]} == 0x4B do
                rx_crc16_reg = 0xFFFF
                bit_cnt  = 0   # FRAMING: recv_data inherited bit_cnt=8 -> first payload
                               # byte mis-framed. Reset so byte 0 frames at bit_cnt 0..7.
                dbg_route = 2   # data
                next :recv_data
              else
                dbg_route = 0   # SOF/handshake/unrecognized -> idle
                next :idle
              end
            end
          end
        end

      :recv_data ->
        # EOP exit MUST be inside this arm: the second `case rx_state` block commits
        # rx_state AFTER the first block's global `on phy_rx_se0 -> next :idle`, so the
        # implicit state-retain here clobbered that transition and recv_data got stuck
        # forever (54301 cycles, missing 28/32 packet strobes). Handle EOP locally.
        on phy_rx_se0 do
          # Emit the ep_out packet-end pulse HERE (in the recv_data case arm, whose
          # on-phy_rx_se0 assignments ARE honored by the elaborator) instead of the
          # first-block on-phy_rx_se0-in-defaults (whose assignments were dropped, so
          # the pulse never reached the CDC). Same accept gate: addr match + OUT/SETUP
          # token + CRC16 residue valid.
          if token_addr_match_reg and
             (token_is_out_reg or token_is_setup_reg) and
             bxor(rx_crc16_reg[15..0], 0xB001) == 0 do
            ep_out_pkt_end = 1
            ep_out_setup   = token_is_setup_reg
            ep_out_ep      = token_ep_reg
          end
          next :idle
        end
        on phy_rx_valid do
          # LSB-first: shift left, new bit into LSB (sweep-confirmed decode order).
          byte_shift   = {byte_shift[6..0], phy_rx_data}
          bit_cnt      = bit_cnt_next
          rx_crc16_reg = crc16_next
          if bit_cnt == 7 do
            bit_cnt = 0
            if token_addr_match_reg do
              ep_out_valid = 1
              # ENDIANNESS: data payload is LSB-first on the wire, same as the PID.
              # The PID assembly got the rev8 fix; the DATA path was MISSED and
              # delivered scrambled bytes to the CDC (SET_ADDRESS payload came out as
              # garbage -> addr never parsed). Bit-reverse the assembled byte, exactly
              # like the recv_pid latch.
              ep_out_data  = {phy_rx_data, byte_shift[0..0], byte_shift[1..1], byte_shift[2..2], byte_shift[3..3], byte_shift[4..4], byte_shift[5..5], byte_shift[6..6]}
              ep_out_ep    = token_ep_reg
              ep_out_setup = token_is_setup_reg
            end
          end
        end

      :recv_token ->
        on phy_rx_valid do
          if token_bits < 7 do
            rx_addr = {phy_rx_data, rx_addr[6..1]}   # LSB-first: shift RIGHT (new bit -> MSB)
          else
            if token_bits < 11 do
              rx_ep = {phy_rx_data, rx_ep[3..1]}     # LSB-first: shift RIGHT (new bit -> MSB)
            end
          end
          crc5_reg   = crc5_next
          token_bits = token_bits_next

          if token_bits == 15 do
            token_bits = 0
            dbg_crc5_at    = crc5_next          # debug: crc5 residual at token complete
            dbg_rxaddr_at  = rx_addr            # debug: received address
            dbg_devaddr_at = dev_addr[6..0]     # debug: device address to match against
            dbg_rxpid_at   = rx_pid             # Blocker-1: rx_pid AT accept point
            if crc5_next == 0x0C do
              dbg_tok_fail = 2   # debug: reached addr check (crc5 ok); assume mismatch unless matched below
              if rx_addr == dev_addr[6..0] and rx_pid != 0xA5 do
                dbg_tok_fail = 0   # debug: accepted
                dbg_accept   = 1   # Blocker-1: token accepted this cycle
                dbg_setup_at = (rx_pid == 0x2D)  # Blocker-1: setup flag at accept
                token_addr_match_reg = 1
                token_ep_reg         = rx_ep
                token_is_in_reg      = (rx_pid == 0x69)
                token_is_out_reg     = (rx_pid == 0xE1)
                token_is_setup_reg   = (rx_pid == 0x2D)

                if rx_pid == 0x69 do
                  if (rx_ep == 0 and ep0_in_loaded) or
                     (rx_ep == 1 and ep1_in_loaded) do
                    arm_tx(rx_ep, if(rx_ep == 0, do: ep0_in_pid, else: ep1_in_pid))
                  else
                    arm_handshake(0x5A)
                    ep_in_nak = 1
                  end
                end

                if rx_pid == 0x2D do
                  ep0_in_loaded = 0
                end

              else
                clear_token_regs()
              end
            else
              dbg_tok_fail = 1   # debug: crc5 check failed
            end
            next :idle
          end
        end

    end
  end

  # ---------------------------------------------------------------------------
  # TX state machine
  # ---------------------------------------------------------------------------

  fsm :tx_state, clock: :clk_48mhz, reset: :rst, init: :idle do

    defaults do
      ep_in_ready = 0
      tx_data_ack = 0
      tx_hs_ack   = 0
    end

    case tx_state do

      :idle ->
        on tx_req do
          tx_data_ack     = 1
          tx_is_handshake = 0
          start_tx(tx_req_ep, tx_req_pid)
        end
        on send_handshake and bnot(tx_req) do
          tx_hs_ack       = 1
          tx_is_handshake = 1
          start_tx(0, handshake_pid)
        end

      :tx_sync ->
        on phy_tx_ready do
          tx_shift_bit()
          if tx_bit_cnt == 7 do
            tx_shift   = tx_pid_reg
            tx_bit_cnt = 0
            next :tx_pid
          end
        end

      :tx_pid ->
        on phy_tx_ready do
          tx_shift_bit()
          if tx_bit_cnt == 7 do
            tx_bit_cnt   = 0
            tx_crc16_reg = 0xFFFF
            if tx_is_handshake do
              tx_is_handshake = 0
              next :tx_eop
            else
              if ep_in_valid do
                tx_shift    = ep_in_data
                ep_in_ready = 1
                next :tx_data
              else
                next :tx_eop
              end
            end
          end
        end

      :tx_data ->
        on phy_tx_ready do
          tx_shift_bit()
          tx_crc16_reg = crc16_next
          if tx_bit_cnt == 7 do
            tx_bit_cnt = 0
            if ep_in_valid do
              tx_shift    = ep_in_data
              ep_in_ready = 1
            else
              tx_crc_buf = bxor(crc16_next, 0xFFFF)
              tx_crc_cnt = 0
              next :tx_crc
            end
          end
        end

      :tx_crc ->
        on phy_tx_ready do
          tx_crc_buf = {one, tx_crc_buf[15..1]}
          tx_crc_cnt = tx_crc_cnt_next
          on tx_crc_cnt == 15, next: :tx_eop
        end

      :tx_eop ->
        on phy_tx_ready, next: :idle

    end
  end

end
