defmodule Hw.USB.FSPhy do
  @moduledoc """
  USB Full-Speed Physical Layer (12 Mbit/s).

  Key improvements over original:

  1. Majority-vote glitch filter on dp_diff/dn_raw — two consecutive samples
     must agree before the filtered value updates. Eliminates single-cycle
     glitches. On hardware, the I/O registers provide one synchronization stage.

  2. Edge-triggered clock recovery. On a bit transition, the 4-cycle sample
     counter resets to re-center sampling at the bit midpoint. The original
     free-running counter could consistently sample at bit edges.

  3. Full SYNC validation (KJKJKJKK). Must see at least one J before accepting
     the final double-K as SYNC end. Guards against glitches triggering false
     packet reception.

  4. TX side unchanged from original — bit-serial NRZI + bit-stuffing,
     SIE drives tx_valid/tx_data, PHY pulses tx_ready each bit period.

  5. TX stuck watchdog recovers from power-on glitches.

  ## RX state machine

      idle    — waiting for K symbol
      detect  — K seen, confirm at sample point
      sync_k  — in SYNC, on K half-bit
      sync_j  — in SYNC, on J half-bit
      active  — receiving data bits
      eop0    — first SE0 of EOP
      eop1    — second SE0

  ## TX state machine

      idle   — drive J, wait for SIE
      data   — NRZI encode + bit stuffing
      stuff  — inserting forced 0-bit
      eop1   — first SE0 bit period
      eop2   — second SE0 bit period
      eop3   — trailing J
  """

  use Hw.Component
  import Bitwise

  clock :clk_48mhz
  input  :rst,      1

  input  :dp_diff,  1   # D+ (dp_raw from top)
  input  :dn_raw,   1   # D- with PULLMODE=DOWN

  output :dp_tx,    1
  output :dn_tx,    1
  output :tx_en,    1
  output :pu,       1

  output :rx_valid,  1
  output :rx_data,   1
  output :rx_se0,    1
  output :rx_active, 1
  output :rx_bit0,   1   # pulses on the rx_valid carrying PID bit 0 (first_bit)
  output :rx_pid_done, 1 # pulses on the rx_valid carrying PID bit 7 (last PID bit)

  input  :tx_valid,  1
  input  :tx_data,   1
  input  :tx_se0,    1
  output :tx_ready,  1
  output :tx_active, 1
  # Debug: a 1-cycle strobe at the MIDDLE of each transmitted bit (phase==2 while
  # transmitting). At this phase the registered tx_dp/tx_dn hold the CURRENT bit's
  # settled symbol, so a top-level capture buffer can sample one symbol per bit.
  output :dbg_tx_midbit, 1

  # ---------------------------------------------------------------------------
  # Two-flop synchronizer
  # ---------------------------------------------------------------------------
  wire :dp_s0, 1, init: 1
  wire :dp_s1, 1, init: 1
  wire :dp_s2, 1, init: 1
  wire :dp_s3, 1, init: 1
  wire :dn_s0, 1, init: 0
  wire :dn_s1, 1, init: 0
  wire :dn_s2, 1, init: 0
  wire :dn_s3, 1, init: 0
  wire :dp_sync, 1   # synchronizer output tapped at the swept depth (SYNCDEPTH)
  wire :dn_sync, 1

  # ---------------------------------------------------------------------------
  # Glitch filter — update only when two consecutive sync'd samples agree
  # ---------------------------------------------------------------------------
  wire :dp_p0, 1, init: 1
  wire :dp_p1, 1, init: 1
  wire :dp_f,  1, init: 1   # filtered D+
  wire :dn_p0, 1, init: 0
  wire :dn_p1, 1, init: 0
  wire :dn_f,  1, init: 0   # filtered D-

  # ---------------------------------------------------------------------------
  # Symbols (combinational, decoded from filtered signals)
  # ---------------------------------------------------------------------------
  wire :sym_j,   1
  wire :sym_k,   1
  wire :sym_se0, 1

  # ---------------------------------------------------------------------------
  # Clock recovery
  # ---------------------------------------------------------------------------
  wire :dp_prev,         1, init: 1
  wire :bit_edge,        1
  wire :sample_cnt,      2, init: 0
  wire :sample_en,       1
  wire :sample_cnt_next, 2

  # ---------------------------------------------------------------------------
  # RX data path
  # ---------------------------------------------------------------------------
  wire :sync_j_seen,    1, init: 0
  wire :first_bit,      1, init: 0   # 1 only until the first data bit of :active is taken
  wire :bit_cnt,        3, init: 0
  wire :ones_cnt,       3, init: 1
  wire :data_sr,        8, init: 0
  wire :rxd_last_j,     1, init: 0
  wire :bit_transition, 1
  wire :nrzi_rx_bit,    1
  wire :bit_stuff_now,  1
  wire :ones_cnt_next,  3
  wire :bit_cnt_next,   3

  # Debug instrumentation: a symbol counter incremented on every sampled bit
  # during active RX (state 4). Gives a direct index to align "PHY received
  # symbol N" against the host TX encoder's per-symbol decision log.
  wire :dbg_rx_sym, 8, init: 0

  # P4/P5 entry-state probes: latched AT the sync->active transition. These reveal
  # whatever NRZI/counter state is carried INTO :active for each packet, so SETUP
  # and SOF entries can be compared. dbg_entry_num increments per active-entry.
  wire :dbg_entry_num,     8, init: 0   # monotonic count of sync->active entries
  wire :dbg_entry_lastj,   1, init: 0   # rxd_last_j carried in at entry
  wire :dbg_entry_ones,    3, init: 0   # ones_cnt carried in at entry
  wire :dbg_entry_scnt,    2, init: 0   # sample_cnt (sub-bit phase) at entry

  # ---------------------------------------------------------------------------
  # TX data path
  # ---------------------------------------------------------------------------
  wire :tx_ones,      3, init: 0
  wire :tx_dp,        1, init: 1
  wire :tx_dn,        1, init: 0
  wire :tx_act,       1
  wire :tx_ones_next, 3
  wire :phase,        2, init: 0   # 4-cycle TX bit clock
  wire :phase_next,   2
  wire :tx_bit_en,    1
  wire :tx_stuck_cnt, 10, init: 0

  # ---------------------------------------------------------------------------
  # Simulation interface
  # ---------------------------------------------------------------------------

  # Simulation timing constants (derived empirically from PHY pipeline trace).
  #
  # The PHY pipeline is 4 clocks deep (2 sync flops + 2 filter agree stages).
  # sample_cnt runs freely with period 4; bit_edge only resets it when cnt≠0.
  # To guarantee exactly one sample per bit and correct state machine alignment:
  #
  #   @clocks_per_bit 4   — each symbol driven for exactly one sample_cnt period
  #   @phase_offset   2   — extra idle clocks so first SYNC K drives when
  #                         sample_cnt=2, ensuring dp_f transitions when cnt=2≠0
  #                         so bit_edge reset fires and re-centers sampling
  #   @sync_wire_pattern  — 9 wire symbols (KJKJKJKKK) not 8: pipeline consumes
  #                         the first symbol before SYNC state machine begins,
  #                         so one extra K is needed at the end to fire :active
  @clocks_per_bit    4
  @phase_offset      2
  # Wire symbols to drive for SYNC (J idle → active). 9 symbols at 4 clocks each.
  # line_state: 1=J (dp=1,dn=0), 0=K (dp=0,dn=1)
  @sync_wire_symbols [0, 1, 0, 1, 0, 1, 0, 0, 0]  # KJKJKJKKK

  @doc """
  Drive a complete USB FS packet onto dp_diff/dn_raw as if received from the bus.

  Encodes SYNC + payload bytes with NRZI and bit stuffing, drives 4 clocks per
  bit, then asserts SE0 EOP (2 bit periods) and returns to J idle.

  `bytes` is the raw payload starting from PID — SYNC and EOP are added
  automatically. CRC must be pre-computed by the caller if SIE validates it.
  """
  def send_packet(sim, bytes, opts \\ []) do
    prefix = Hw.Sim.DefhwInterpreter.resolve_prefix(sim, __MODULE__, opts)
    dp_sig = prefix_sig(prefix, :dp_diff)
    dn_sig = prefix_sig(prefix, :dn_raw)

    # Pre-settle J idle, then phase offset to align sample_cnt for SYNC detection
    Hw.Sim.set(sim, dp_sig, 1)
    Hw.Sim.set(sim, dn_sig, 0)
    Hw.Sim.tick(sim, :clk_48, 8 + @phase_offset)

    # Drive SYNC wire pattern, leaving line_state at K (final state after KJKJKJKKK)
    line_state = Enum.reduce(@sync_wire_symbols, 1, fn ls, _ ->
      drive_symbol_state(sim, dp_sig, dn_sig, ls)
      ls
    end)

    # Drive payload bytes NRZI-encoded with bit stuffing, starting from K
    {_line_state, _ones} = Enum.reduce(bytes, {line_state, 0}, fn byte, acc ->
      drive_byte(sim, dp_sig, dn_sig, byte, acc)
    end)

    # EOP: SE0 for 2 bit periods, then J idle
    drive_symbol(sim, dp_sig, dn_sig, :se0)
    drive_symbol(sim, dp_sig, dn_sig, :se0)
    drive_symbol(sim, dp_sig, dn_sig, :j)
    :ok
  end

  @doc """
  Wait for the PHY to transmit a packet, decode NRZI from dp_tx/dn_tx,
  and return the raw bytes (PID onward, SYNC stripped, before EOP).
  """
  def recv_packet(sim, opts \\ []) do
    prefix = Hw.Sim.DefhwInterpreter.resolve_prefix(sim, __MODULE__, opts)
    tx_active_sig = prefix_sig(prefix, :tx_active)
    dp_tx_sig     = prefix_sig(prefix, :dp_tx)

    wait_for_signal(sim, tx_active_sig, 1)
    Enum.each(1..8, fn _ -> Hw.Sim.tick(sim, :clk_48, @clocks_per_bit) end)
    collect_tx_bytes(sim, dp_tx_sig, tx_active_sig, 1, 0, [], 0, 0)
  end

  # ---------------------------------------------------------------------------
  # Private sim helpers
  # ---------------------------------------------------------------------------

  defp prefix_sig("", name), do: name
  defp prefix_sig(prefix, name), do: :"#{prefix}#{name}"

  defp drive_byte(sim, dp_sig, dn_sig, byte, {line_state, ones}) do
    Enum.reduce(0..7, {line_state, ones}, fn bit_pos, {ls, o} ->
      {ls2, o2} = if o == 6 do
        new_ls = 1 - ls
        drive_symbol_state(sim, dp_sig, dn_sig, new_ls)
        {new_ls, 0}
      else
        {ls, o}
      end

      data_bit = band(bsr(byte, bit_pos), 1)
      if data_bit == 1 do
        drive_symbol_state(sim, dp_sig, dn_sig, ls2)
        {ls2, o2 + 1}
      else
        flipped = 1 - ls2
        drive_symbol_state(sim, dp_sig, dn_sig, flipped)
        {flipped, 0}
      end
    end)
  end

  defp drive_symbol_state(sim, dp_sig, dn_sig, 1) do
    Hw.Sim.set(sim, dp_sig, 1)
    Hw.Sim.set(sim, dn_sig, 0)
    Hw.Sim.tick(sim, :clk_48, @clocks_per_bit)
  end
  defp drive_symbol_state(sim, dp_sig, dn_sig, 0) do
    Hw.Sim.set(sim, dp_sig, 0)
    Hw.Sim.set(sim, dn_sig, 1)
    Hw.Sim.tick(sim, :clk_48, @clocks_per_bit)
  end

  defp drive_symbol(sim, dp_sig, dn_sig, :j) do
    Hw.Sim.set(sim, dp_sig, 1)
    Hw.Sim.set(sim, dn_sig, 0)
    Hw.Sim.tick(sim, :clk_48, @clocks_per_bit)
  end
  defp drive_symbol(sim, dp_sig, dn_sig, :se0) do
    Hw.Sim.set(sim, dp_sig, 0)
    Hw.Sim.set(sim, dn_sig, 0)
    Hw.Sim.tick(sim, :clk_48, @clocks_per_bit)
  end

  defp wait_for_signal(sim, signal, expected, ticks \\ 0)
  defp wait_for_signal(_sim, signal, _expected, 10_000) do
    raise "FSPhy.recv_packet: timed out waiting for #{inspect(signal)}"
  end
  defp wait_for_signal(sim, signal, expected, ticks) do
    if Hw.Sim.get(sim, signal) == expected do
      :ok
    else
      Hw.Sim.tick(sim, :clk_48, 1)
      wait_for_signal(sim, signal, expected, ticks + 1)
    end
  end

  defp collect_tx_bytes(sim, dp_sig, tx_active_sig, prev_dp, bit_acc, byte_acc, bit_pos, ones) do
    Hw.Sim.tick(sim, :clk_48, @clocks_per_bit)
    tx_active = Hw.Sim.get(sim, tx_active_sig)
    dp = Hw.Sim.get(sim, dp_sig)

    if tx_active == 0 do
      Enum.reverse(byte_acc)
    else
      nrzi_bit = if dp == prev_dp, do: 1, else: 0
      if ones == 6 and nrzi_bit == 0 do
        collect_tx_bytes(sim, dp_sig, tx_active_sig, dp, bit_acc, byte_acc, bit_pos, 0)
      else
        new_bit_acc = bor(bit_acc, bsl(nrzi_bit, bit_pos))
        new_ones = if nrzi_bit == 1, do: ones + 1, else: 0
        if bit_pos == 7 do
          collect_tx_bytes(sim, dp_sig, tx_active_sig, dp, 0, [new_bit_acc | byte_acc], 0, new_ones)
        else
          collect_tx_bytes(sim, dp_sig, tx_active_sig, dp, new_bit_acc, byte_acc, bit_pos + 1, new_ones)
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Hardware helpers (inlined into FSM bodies by elaborator)
  # ---------------------------------------------------------------------------

  defhw nrzi_toggle() do
    tx_dp = bnot(tx_dp)
    tx_dn = tx_dp
  end

  defhw drive_se0() do
    tx_dp = 0
    tx_dn = 0
  end

  # ---------------------------------------------------------------------------
  # Combinational
  # ---------------------------------------------------------------------------

  comb do
    # RX synchronizer DEPTH sweep (prior art: Fomu/ValentyUSB traced intermittent,
    # per-build enumeration failure to metastability in the bus synchronizer). Tap
    # the flop chain at the swept depth: dp_s1 = 2 flops (baseline), dp_s2 = 3,
    # dp_s3 = 4. Deeper => exponentially lower metastability rate, +1 cyc latency each.
    dp_sync = dp_s1   # SYNCDEPTH
    dn_sync = dn_s1   # SYNCDEPTH

    # Symbol decode from filtered signals
    sym_se0 = dp_f == 0 and dn_f == 0
    sym_k   = dp_f == 0 and dn_f == 1
    sym_j   = dp_f == 1

    # Clock recovery
    bit_edge        = dp_prev != dp_f
    sample_cnt_next = sample_cnt + 1
    # Sample phase within the 4x oversample window. (A ValentyUSB-style port to
    # mid-bit + continuous re-centering was tried and reproducibly BROKE control-IN
    # completion at every phase, so reverted to the original phase-0 sampling.)
    sample_en       = (sample_cnt == 0)   # SAMPLEPHASE

    # NRZI decode
    bit_transition = bxor(rxd_last_j, sym_j)
    nrzi_rx_bit    = bnot(bit_transition)
    bit_stuff_now  = (ones_cnt == 6)

    # Counters
    ones_cnt_next = ones_cnt + 1
    bit_cnt_next  = bit_cnt + 1

    # TX
    phase_next   = phase + 1
    tx_ones_next = tx_ones + 1
    tx_bit_en    = (phase == 0)
    tx_act       = (tx_state != 0)

    tx_en     = tx_act
    tx_active = tx_act
    dp_tx     = tx_dp
    dn_tx     = tx_dn
    tx_ready  = tx_act and tx_bit_en and tx_state == 1
    # Mid-bit sample strobe (see output decl): current bit's symbol is settled.
    dbg_tx_midbit = (phase == 2) and tx_act

    # RX outputs — state encoding: idle=0 detect=1 sync_k=2 sync_j=3 active=4 eop0=5 eop1=6
    rx_active = (rx_state == 4)
    # rx_valid must pulse on EVERY sampled data bit — the SIE shifts one bit per
    # rx_valid and keeps its own bit_cnt. The old `bit_cnt == 7` gate made rx_valid
    # fire only once per 8-bit group, so the SIE received 1 bit per byte and never
    # assembled a real PID. (Stuff bits are correctly excluded.)
    # rx_valid must pulse on every sampled DATA bit, but NOT on the SE0/EOP boundary
    # sample: rx_state is still 4 (:active) the cycle the line goes SE0 (the FSM moves
    # to :eop0 next cycle), so without the bnot(sym_se0) gate rx_valid fires one EXTRA
    # time, feeding a spurious 81st bit that clobbered the valid CRC16 residue (0xB001
    # -> 0x5800) before the EOP check. Excluding SE0 samples fixes the bit count.
    rx_valid  = (rx_state == 4) and sample_en and bnot(bit_stuff_now) and bnot(sym_se0)
    # rx_bit0: high ONLY on the rx_valid carrying the packet's FIRST data bit. Uses
    # the first_bit flag (set at :active entry, cleared after the first non-stuffed
    # bit) — NOT bit_cnt==0, which WRAPS every 8 bits (3-bit counter) and fired the
    # strobe ~4.5x/packet, re-entering recv_pid mid-packet and scrambling assembly.
    rx_bit0   = rx_valid and first_bit
    # rx_pid_done: pulses ONCE, on the rx_valid carrying the 8th PID symbol. Uses
    # dbg_rx_sym (resets 0 at :active entry, counts up, does NOT wrap) so the strobe
    # fires exactly once per packet — unlike bit_cnt==7 which WRAPS every 8 bits and
    # fired 112x (mid-packet), hanging the SIE. dbg_rx_sym==7 = the 8th PID bit.
    rx_pid_done = rx_valid and (dbg_rx_sym == 7)
    # Present the freshly-decoded bit, not data_sr[0..0]: the SIE latches rx_data
    # on each rx_valid pulse, so it needs THIS bit, not the LSB of the (MSB-filled,
    # still-mostly-zero) internal shift register.
    rx_data   = nrzi_rx_bit
    rx_se0    = (rx_state == 5 or rx_state == 6) and sample_en

    pu = 1
  end

  # ---------------------------------------------------------------------------
  # Pipeline and housekeeping — runs every clock before the FSMs
  # ---------------------------------------------------------------------------

  on :clk_48mhz do
    # Stage 1: synchronizer flop chain (tapped at SYNCDEPTH via dp_sync/dn_sync)
    dp_s0 = dp_diff
    dp_s1 = dp_s0
    dp_s2 = dp_s1
    dp_s3 = dp_s2
    dn_s0 = dn_raw
    dn_s1 = dn_s0
    dn_s2 = dn_s1
    dn_s3 = dn_s2

    # Stage 2: Majority-vote glitch filter
    dp_p1 = dp_p0
    dp_p0 = dp_sync
    if dp_p0 == 1 and dp_p1 == 1 do
      dp_f = 1
    end
    if dp_p0 == 0 and dp_p1 == 0 do
      dp_f = 0
    end

    dn_p1 = dn_p0
    dn_p0 = dn_sync
    if dn_p0 == 1 and dn_p1 == 1 do
      dn_f = 1
    end
    if dn_p0 == 0 and dn_p1 == 0 do
      dn_f = 0
    end

    # TX phase clock — always runs
    phase = phase_next

    # Clock recovery — only during RX (not during TX). Re-center the sample counter
    # on a bit edge, but ONLY outside active data (rx_state < 4): continuous
    # re-centering (the ValentyUSB pattern) was tried and broke completion here.
    dp_prev = dp_f
    if bnot(tx_act) do
      if bit_edge and sample_cnt != 0 and rx_state < 4 do
        sample_cnt = 0
      else
        sample_cnt = sample_cnt_next
      end
    end

    # TX stuck watchdog
    if tx_act do
      if tx_stuck_cnt < 1023 do
        tx_stuck_cnt = tx_stuck_cnt + 1
      end
      if tx_stuck_cnt == 512 do
        tx_stuck_cnt = 0
      end
    else
      tx_stuck_cnt = 0
    end

  end

  # ---------------------------------------------------------------------------
  # RX state machine
  # ---------------------------------------------------------------------------

  fsm :rx_state, clock: :clk_48mhz, reset: :rst, init: :idle do

    case rx_state do

      :idle ->
        # Transition immediately (no sample_en guard) on first K symbol.
        sync_j_seen = 0
        ones_cnt    = 1
        on sym_k and bnot(tx_act), next: :detect

      :detect ->
        # Confirm K still present at sample point — guards against glitches.
        on sample_en and sym_k and bnot(tx_act), next: :sync_k
        on sample_en and bnot(sym_k) and bnot(tx_act), next: :idle

      :sync_k ->
        # On K half-bit of SYNC. Accept KK only after seeing at least one J.
        on sample_en and sym_k and sync_j_seen and bnot(tx_act) do
          # Valid SYNC end (KK after J) — enter data reception
          # P4/P5: latch carried state BEFORE the resets below. RHS reads see the
          # OLD (carried-in) values — exactly what would have flowed into :active.
          dbg_entry_num   = dbg_entry_num + 1
          dbg_entry_lastj = rxd_last_j
          dbg_entry_ones  = ones_cnt
          dbg_entry_scnt  = sample_cnt
          bit_cnt    = 0
          ones_cnt   = 1
          rxd_last_j = 0
          data_sr    = 0
          first_bit  = 1   # arm: next non-stuffed :active bit is the packet's bit 0
          dbg_rx_sym = 0   # debug: reset per-packet so index 0..7 = THIS packet's PID
          next :active
        end
        on sample_en and sym_j and bnot(tx_act) do
          sync_j_seen = 1
          next :sync_j
        end
        on sample_en and sym_k and bnot(sync_j_seen) and bnot(tx_act), next: :idle
        on sample_en and sym_se0 and bnot(tx_act), next: :idle

      :sync_j ->
        # On J half-bit of SYNC — must be followed by K.
        on sample_en and sym_k and bnot(tx_act), next: :sync_k
        on sample_en and bnot(sym_k) and bnot(tx_act), next: :idle

      :active ->
        # Receiving data bits — NRZI decode and bit-unstuff on each sample.
        on sample_en and sym_se0 and bnot(tx_act), next: :eop0
        on sample_en and bnot(sym_se0) and bnot(tx_act) do
          rxd_last_j = sym_j
          dbg_rx_sym = dbg_rx_sym + 1   # debug: count each sampled RX symbol
          if bit_stuff_now do
            ones_cnt = 0
          else
            data_sr = {nrzi_rx_bit, data_sr[7..1]}
            if bit_transition do
              ones_cnt = 0
            else
              ones_cnt = ones_cnt_next
            end
            bit_cnt = bit_cnt_next
            first_bit = 0   # first real data bit consumed; strobe fires only once
          end
        end

      :eop0 ->
        # First SE0 — must be followed by a second.
        on sample_en and sym_se0 and bnot(tx_act), next: :eop1
        on sample_en and bnot(sym_se0) and bnot(tx_act), next: :idle
        # ESCAPE: if TX becomes active while we're in EOP, the RX packet is already
        # done — return to idle so the RX FSM doesn't wedge in :eop0 for the whole TX
        # (measured: 54245 cycles stuck here after the first ACK drove tx_act high).
        on tx_act, next: :idle

      :eop1 ->
        # Second SE0 — packet complete, return to idle on next sample.
        on sample_en and bnot(tx_act) do
          sync_j_seen = 0
          ones_cnt    = 1
          bit_cnt     = 0
          data_sr     = 0
          rxd_last_j  = 0
          next :idle
        end
        # ESCAPE: same TX-collision guard as :eop0.
        on tx_act, next: :idle

    end
  end

  # ---------------------------------------------------------------------------
  # TX state machine
  # ---------------------------------------------------------------------------

  fsm :tx_state, clock: :clk_48mhz, reset: :rst, init: :idle do

    case tx_state do

      :idle ->
        tx_dp = 1
        tx_dn = 0
        on tx_bit_en and (tx_valid or tx_se0) do
          tx_ones = 0
          next :data
        end

      :data ->
        on tx_bit_en do
          hdl_case <<tx_se0::1, tx_valid::1, tx_data::1>> do
            <<1::1, _::1, _::1>> ->
              drive_se0()
              next :eop1

            <<0::1, 1::1, 1::1>> ->
              tx_ones = tx_ones_next
              on tx_ones == 5, next: :stuff

            <<0::1, 1::1, 0::1>> ->
              nrzi_toggle()
              tx_ones = 0

            <<0::1, 0::1, _::1>> ->
              # Sender de-asserted tx_valid without ever asserting tx_se0. This means
              # the packet is done (e.g. a HANDSHAKE: PID only, no data, and the SIE's
              # brief tx_se0 pulse ended before we sampled it here). Terminate: drive
              # SE0 and go to EOP so tx_state returns to idle. Without this the PHY TX
              # FSM sat in :data forever (measured 54231 cycles), wedging tx_act high
              # and blocking ALL further RX.
              drive_se0()
              next :eop1
          end
        end

      :stuff ->
        on tx_bit_en do
          nrzi_toggle()
          tx_ones = 0
          next :data
        end

      :eop1 ->
        on tx_bit_en do
          drive_se0()
          next :eop2
        end

      :eop2 ->
        on tx_bit_en do
          tx_dp = 1
          tx_dn = 0
          next :eop3
        end

      :eop3 ->
        on tx_bit_en do
          tx_dp   = 1
          tx_dn   = 0
          tx_ones = 0
          next :idle
        end

    end
  end

end
