defmodule Hw.Diag.CycleTrace do
  @moduledoc """
  Triggered cycle-by-cycle recorder — the "sweep" upgrade to the sticky-latch
  health dashboard.

  The sticky dashboard answers "did signal X EVER do Y" but collapses time, so
  it cannot see an intra-cycle clobber (a register set then reset the same cycle
  by a later branch). This module records a WINDOW of full signal snapshots
  around a trigger into block RAM, then streams the window out the UART as hex —
  turning the oracle from a boolean into a time series readable cycle by cycle.

  Fixed 40-bit sample bus, 64-cycle ring. It records continuously so PRE-trigger
  cycles are kept; on `trig` it records POST_CYCLES more then FREEZES and dumps
  all 64 entries oldest-first as `ii dddddddddd` lines (2 hex index, space,
  10 hex sample), CR/LF each, blank line between full dumps. Then it re-arms.

  Sample layout (bit 39..0, MSB first in the hex), packed by the top level:
    [39:32] req_type   [31:24] req_code   [23:16] {5'b0, setup_cnt}
    [15:8]  {ep_out_pkt_end,ep_out_setup,ep_out_valid,ep_out_ep(4),ep0_state[1]}
    [7:0]   {ep0_state[0],ep_in_loaded,setup_full,dispatch_hit, 4'b0}
  (the top level defines the packing; this module just stores/streams 40 bits.)

  Pure passive observer: reads `sample`/`trig`, drives its own UART @ 9600 8N1.
  """

  use Hw.Component

  # Cycles kept recording AFTER the trigger before freezing.
  param :POST_CYCLES, default: 40
  # Byte-slot cadence (timer-based; ~12 bit-times at 9600 + margin).
  param :BYTE_CYCLES, default: 60_000
  # Gap cycles between full dumps.
  param :GAP_CYCLES, default: 480_000

  clock :clk, freq: 48.0
  input  :rst, 1

  input :sample, 40
  input :trig,   1
  output :txd,   1

  # --- Trace RAM: 40 bits x 64 cycles ---
  memory :trace, width: 40, depth: 64

  # --- Capture control ---
  # cap_state: 0=recording/armed 1=post-trigger 2=dumping 3=inter-dump gap
  wire :cap_state, 2, init: 2   # DEBUG: start in dump state to isolate UART/dump path
  wire :wp,        6, init: 0
  wire :post_cnt,  6, init: 0
  wire :frozen_wp, 6, init: 0
  wire :free_cnt,  8, init: 0   # DEBUG: cycles in state 0 (auto-trigger fallback)

  # --- Dump control ---
  # Line = 13 bytes: idx_hi idx_lo ' ' d9 d8 d7 d6 d5 d4 d3 d2 d1 d0  (then CR LF)
  # We fold CR/LF into byte positions 13,14 -> 15 bytes/line.
  wire :dump_idx,  6, init: 0
  wire :col,       4, init: 0    # byte position within the line, 0..14
  wire :slot_cnt, 24, init: 0
  wire :gap_cnt,  23, init: 0
  wire :rd_word,  40
  wire :sel_nib,   4             # comb: the 4-bit nibble for the current data column
  wire :wr_addr,   6             # comb copy of wp for the mem-write address

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

  wire :idx_hi, 4
  wire :idx_lo, 4
  wire :ch,     8    # comb: the ASCII byte for the current column

  comb do
    # Separate comb address for the mem write (FIFO does the same — the write
    # address must be a comb wire, not the register being incremented in-block).
    wr_addr = wp

    # Oldest-first read: at freeze wp points to the next-to-overwrite = oldest.
    rd_word = trace[frozen_wp + dump_idx]
    idx_hi  = {0[1..0], dump_idx[5..4]}
    idx_lo  = dump_idx[3..0]

    # Data columns 3..12 map to nibbles [39:36]..[3:0] (MSB first).
    # col 3 -> nibble 9 (bits 39..36), col 12 -> nibble 0 (bits 3..0).
    hdl_case <<col::4>> do
      <<3::4>>  -> sel_nib = rd_word[39..36]
      <<4::4>>  -> sel_nib = rd_word[35..32]
      <<5::4>>  -> sel_nib = rd_word[31..28]
      <<6::4>>  -> sel_nib = rd_word[27..24]
      <<7::4>>  -> sel_nib = rd_word[23..20]
      <<8::4>>  -> sel_nib = rd_word[19..16]
      <<9::4>>  -> sel_nib = rd_word[15..12]
      <<10::4>> -> sel_nib = rd_word[11..8]
      <<11::4>> -> sel_nib = rd_word[7..4]
      <<_::4>>  -> sel_nib = rd_word[3..0]
    end

    # Assemble the ASCII byte for this column.
    #  0=idx_hi 1=idx_lo 2=' ' 3..12=data nibble 13=CR 14=LF
    hdl_case <<col::4>> do
      <<0::4>>  -> ch = if idx_hi < 10, do: 0x30 + idx_hi, else: 0x57 + idx_hi
      <<1::4>>  -> ch = if idx_lo < 10, do: 0x30 + idx_lo, else: 0x57 + idx_lo
      <<2::4>>  -> ch = 0x20
      <<13::4>> -> ch = 0x0D
      <<14::4>> -> ch = 0x0A
      <<_::4>>  -> ch = if sel_nib < 10, do: 0x30 + sel_nib, else: 0x57 + sel_nib
    end

    uart_data = ch
  end

  on :clk do
    if rst do
      cap_state  = 2   # DEBUG: reset straight into dump state
      wp         = 0
      post_cnt   = 0
      free_cnt   = 0
      frozen_wp  = 0
      dump_idx   = 0
      col        = 0
      slot_cnt   = 0
      gap_cnt    = 0
      uart_valid = 0
    else
      # Capture every cycle into the ring (unconditional write; wp advances always
      # while not dumping). Kept flat and simple — mem-writes must not sit inside
      # an hdl_case arm or complex enable.
      if cap_state == 0 or cap_state == 1 do
        trace[wr_addr] = sample
        wp = wp + 1
      end

      hdl_case <<cap_state::2>> do
        # --- 0: recording (ring), waiting for trigger ---
        # DEBUG: also auto-advance once the ring has filled a few times, so the
        # dump path runs even if `trig` never fires (isolates UART-alive from the
        # trigger source). free_cnt counts cycles in state 0.
        <<0::2>> ->
          uart_valid = 0
          free_cnt = free_cnt + 1
          if trig or free_cnt == 200 do
            cap_state = 1
            post_cnt  = 0
          end

        # --- 1: post-trigger countdown, keep recording ---
        <<1::2>> ->
          if post_cnt == POST_CYCLES do
            frozen_wp = wp     # next-to-overwrite = oldest
            dump_idx  = 0
            col       = 0
            slot_cnt  = 0
            cap_state = 2
          else
            post_cnt = post_cnt + 1
          end

        # --- 2: dumping the frozen window over UART (timer cadence) ---
        <<2::2>> ->
          if slot_cnt == 0 do
            uart_valid = 1
          else
            uart_valid = 0
          end

          if slot_cnt == BYTE_CYCLES do
            slot_cnt = 0
            if col == 14 do
              col = 0
              if dump_idx == 63 do
                dump_idx  = 0
                gap_cnt   = 0
                cap_state = 3
              else
                dump_idx = dump_idx + 1
              end
            else
              col = col + 1
            end
          else
            slot_cnt = slot_cnt + 1
          end

        # --- 3: gap, then re-dump the SAME frozen window (debug: stay latched so
        # the host reliably catches a full window; re-arm disabled for now). ---
        <<_::2>> ->
          uart_valid = 0
          if gap_cnt == GAP_CYCLES do
            cap_state = 2
            dump_idx  = 0
            col       = 0
            slot_cnt  = 0
            gap_cnt   = 0
          else
            gap_cnt = gap_cnt + 1
          end
      end
    end
  end
end
