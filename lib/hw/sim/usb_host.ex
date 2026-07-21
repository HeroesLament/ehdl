defmodule Hw.Sim.USBHost do
  @moduledoc """
  USB Full-Speed host stimulus for the Rust NIF simulator.

  Drives `dp_raw` and `dn_raw` to simulate a USB host performing
  device enumeration. Uses `Hw.Sim.Nif.set_signal/3` and `tick/3`
  to bit-bang NRZI-encoded USB packets at 12 Mbit/s on a 48 MHz clock.

  ## Signal encoding (from fs_phy.ex)

      dp_raw=1, dn_raw=x  → J  (idle state / NRZI 1)
      dp_raw=0, dn_raw=1  → K  (NRZI 0 / SYNC start)
      dp_raw=0, dn_raw=0  → SE0 (reset / EOP)

  4 clock cycles per bit at 48 MHz = 12 Mbit/s.

  ## Usage

      {:ok, auto} = Hw.Sim.Nif.compile(compiled)
      changes = Hw.Sim.USBHost.enumerate(auto)
      # changes is the full NIF change log across the enumeration sequence
  """

  alias Hw.Sim.Nif

  @clocks_per_bit 4   # 48 MHz / 12 Mbit/s
  @reset_ticks    480_000  # 10ms SE0 = USB reset

  # PID values (USB 2.0, with complement check bits)
  @pid_sof   0xA5
  @pid_setup 0x2D
  @pid_in    0x69
  @pid_out   0xE1
  @pid_data0 0xC3
  @pid_data1 0x4B
  @pid_ack   0xD2

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Run a full USB enumeration sequence and return the accumulated change log.

  Sequence:
  1. USB reset (SE0 for 10ms)
  2. Idle (J for 3ms)
  3. SOF frame 0
  4. SETUP GET_DESCRIPTOR (device descriptor, addr 0)
  5. IN data stage (read 18 bytes)
  6. OUT status stage
  7. SOF
  8. SETUP SET_ADDRESS (assign addr 1)
  9. IN status stage
  10. SOF with new address
  """
  @spec enumerate(reference()) :: [tuple()]
  def enumerate(auto) do
    {changes, _phases} = enumerate_with_phases(auto)
    changes
  end

  @doc """
  Run enumeration and build a windowed `Hw.Trace` directly.

  Folds the change log into a trace over the requested signals (default: the USB
  device-state signals), and records a transaction span (`begin_tr`/`end_tr`) for
  each protocol phase — so you can `Render.ascii(trace, window: :set_address)`,
  `find_when(trace, [window: :set_address], ...)`, and assert on named phases.

      trace = USBHost.enumerate_trace(auto)
      Hw.Trace.transactions(trace)                       # the phase list
      IO.puts Hw.Trace.Render.ascii(trace, window: :set_address)

  ## Modes

    * `mode: :delta` (default) — folds the **sparse change log** (`apply_delta`),
      which carries only *registered* signals that changed. Fast, but
      **combinational** signals (`phy_rx_active`, `phy_rx_valid`, `phy_rx_data`,
      the whole PHY→SIE handshake) never appear and read frozen at init. Fine for
      registered signals (`*_state`, `dev_addr`, `dev_state`).

    * `mode: :snapshot` — takes a **dense full snapshot** of the requested signals
      after each packet-level drive step, so **combinational signals are
      captured faithfully**. Heavier (one snapshot per drive), but this is the
      mode to use when inspecting the receive handshake. Snapshots are only taken
      during packet activity, not during the multi-ms idle/reset drives, so the
      cost stays bounded.

      trace = USBHost.enumerate_trace(auto, schedule: sched, mode: :snapshot,
                signals: [:phy_rx_active, :phy_rx_valid, :phy_rx_state, :sie_rx_state])
  """
  @spec enumerate_trace(reference(), keyword()) :: Hw.Trace.t()
  def enumerate_trace(auto, opts \\ []) do
    schedule = Keyword.fetch!(opts, :schedule)
    mode = Keyword.get(opts, :mode, :delta)

    signals =
      Keyword.get(opts, :signals, [
        :dev_addr,
        :cdc_dev_state,
        :sie_rx_state,
        :sie_tx_state
      ])

    trace0 = Hw.Trace.Adapter.Nif.new(schedule, signals: signals)

    {folded, phases} =
      case mode do
        :snapshot ->
          {snaps, phases} =
            enumerate_with_phases(auto, snapshot: signals, stride: Keyword.get(opts, :stride, :bit))

          folded =
            Enum.reduce(snaps, trace0, fn {t, snap}, acc ->
              Hw.Trace.apply_snapshot(acc, snap, t)
            end)

          {folded, phases}

        :delta ->
          {changes, phases} = enumerate_with_phases(auto)

          folded =
            Enum.reduce(changes, trace0, fn {t, sig, _o, n}, acc ->
              Hw.Trace.apply_delta(acc, [{t, sig, 0, n}], t)
            end)

          {folded, phases}
      end

    # Overlay phase spans (begin_tr/end_tr) from the recorded boundaries.
    Enum.reduce(phases, folded, fn
      {label, :begin, ps}, acc -> Hw.Trace.begin_tr(acc, label, ps)
      {label, :end, ps}, acc -> Hw.Trace.end_tr(acc, label, ps)
    end)
  end

  @pdict_snapshot :usb_host_snapshot_sink

  # Run the full enumeration, returning {change_log, phase_events} where
  # phase_events is [{label, :begin | :end, time_ps}] captured at sim time as
  # each protocol phase starts/ends. This is the single source both enumerate/1
  # and enumerate_trace/2 build on.
  @spec enumerate_with_phases(reference(), keyword()) ::
          {[tuple()] | [{non_neg_integer(), map()}], [{atom(), :begin | :end, non_neg_integer()}]}
  def enumerate_with_phases(auto, opts \\ []) do
    # phase collector: mutable via process dictionary-free closure over a ref cell
    phases_ref = :counters.new(1, [])
    tbl = :ets.new(:usb_phases, [:ordered_set, :private])
    seq = fn -> n = :counters.get(phases_ref, 1); :counters.add(phases_ref, 1, 1); n end

    phase = fn label, kind ->
      ps = Nif.get_time(auto)
      :ets.insert(tbl, {seq.(), {label, kind, ps}})
    end

    # In :snapshot mode, install a dense-snapshot sink that the tick primitives
    # write to after each packet-level drive. Snapshots capture COMBINATIONAL
    # signals (invisible in the sparse change log).
    snap_signals = Keyword.get(opts, :snapshot)
    stride = Keyword.get(opts, :stride, :bit)

    result =
      if snap_signals do
        snap_tbl = :ets.new(:usb_snaps, [:ordered_set, :private])
        snap_seq = :counters.new(1, [])
        Process.put(@pdict_snapshot, {auto, snap_signals, snap_tbl, snap_seq, stride})

        _ = enumerate_body(auto, phase)

        Process.delete(@pdict_snapshot)
        snaps = :ets.tab2list(snap_tbl) |> Enum.sort() |> Enum.map(fn {_i, s} -> s end)
        :ets.delete(snap_tbl)
        snaps
      else
        enumerate_body(auto, phase)
      end

    phase_events = :ets.tab2list(tbl) |> Enum.sort() |> Enum.map(fn {_i, ev} -> ev end)
    :ets.delete(tbl)
    {result, phase_events}
  end

  # ---------------------------------------------------------------------------
  # TX instrumentation — the encoder's own per-symbol decision log.
  #
  # This is the "little counter we can view the trace of": each symbol that
  # send_nrzi_bits drives records {sym_idx, field, bit, ones, stuffed, sym, ps}
  # so we can read exactly what the encoder DECIDED at each step, rather than
  # reconstructing it from wire observations. Enabled via `tx_log: true`.
  # ---------------------------------------------------------------------------

  @pdict_txlog :usb_host_txlog

  defp txlog_start do
    tbl = :ets.new(:usb_txlog, [:ordered_set, :private])
    Process.put(@pdict_txlog, {tbl, :counters.new(1, [])})
    tbl
  end

  defp txlog_stop(tbl) do
    Process.delete(@pdict_txlog)
    log = :ets.tab2list(tbl) |> Enum.sort() |> Enum.map(fn {_i, e} -> e end)
    :ets.delete(tbl)
    log
  end

  # Record one encoder decision. field = :pid | :sync | :payload | :stuff.
  defp tx_emit(auto, field, bit, ones, stuffed, sym) do
    case Process.get(@pdict_txlog) do
      {tbl, seq} ->
        i = :counters.get(seq, 1)
        :counters.add(seq, 1, 1)
        :ets.insert(tbl, {i, %{idx: i, field: field, bit: bit, ones: ones, stuffed: stuffed, sym: sym, ps: Nif.get_time(auto)}})

      _ ->
        :ok
    end
  end

  @doc """
  Run enumeration capturing the TX encoder's per-symbol decision log.
  Returns `{change_log_or_snaps, phase_events, tx_log}` where tx_log is a list of
  `%{idx, field, bit, ones, stuffed, sym, ps}` — the encoder's own record of what
  it drove, symbol by symbol.
  """
  @spec enumerate_with_txlog(reference()) :: {term(), list(), list()}
  def enumerate_with_txlog(auto) do
    tbl = txlog_start()
    {result, phases} = enumerate_with_phases(auto)
    {result, phases, txlog_stop(tbl)}
  end

  # Called by the tick primitives after a drive step. If a snapshot sink is
  # installed (snapshot mode), capture a dense {time, %{sig => val}} sample of
  # the requested signals — including combinational ones.
  defp maybe_snapshot(auto) do
    case Process.get(@pdict_snapshot) do
      {^auto, signals, tbl, seq, _stride} ->
        t = Nif.get_time(auto)

        snap =
          Map.new(signals, fn sig ->
            {:ok, v} = Nif.get_signal(auto, sig)
            {sig, v}
          end)

        i = :counters.get(seq, 1)
        :counters.add(seq, 1, 1)
        :ets.insert(tbl, {i, {t, snap}})

      _ ->
        :ok
    end
  end

  defp enumerate_body(auto, phase) do
    changes = []

    # Set bus to J (idle) first before asserting pll_locked
    # to avoid the PHY seeing a spurious K during reset sync startup
    Nif.set_signal(auto, :dp_diff, 1)
    Nif.set_signal(auto, :dn_raw, 0)

    # Assert pll_locked so the reset synchronizer starts counting
    Nif.set_signal(auto, :pll_locked, 1)

    # Wait for rst_sync to count to 1023 and release rst (~1100 ticks)
    {:ok, c0} = Nif.tick(auto, :clk_48, 1100)
    changes = changes ++ c0

    # Reset
    phase.(:reset, :begin)
    changes = changes ++ reset(auto)
    phase.(:reset, :end)

    # Release to J, wait 3ms for device to see reset end
    changes = changes ++ j_idle(auto, 144_000)

    # SOF frame 0
    changes = changes ++ sof(auto, 0)
    changes = changes ++ inter_packet_gap(auto)

    # SETUP GET_DESCRIPTOR(DEVICE) at addr 0, ep 0
    # bmRequestType=0x80, bRequest=0x06, wValue=0x0100, wIndex=0, wLength=18
    setup_data = [0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 0x12, 0x00]
    phase.(:get_descriptor, :begin)
    phase.(:setup, :begin)
    changes = changes ++ setup(auto, 0, 0, setup_data)
    phase.(:setup, :end)

    # IN data stage — request 18 bytes (we just send IN token, device responds)
    # Send enough IN tokens to cover the response (device sends up to 8 bytes per packet)
    phase.(:in_data, :begin)
    changes = changes ++ token_in(auto, 0, 0)
    changes = changes ++ inter_packet_gap(auto)
    changes = changes ++ send_ack(auto)

    changes = changes ++ token_in(auto, 0, 0)
    changes = changes ++ inter_packet_gap(auto)
    changes = changes ++ send_ack(auto)

    changes = changes ++ token_in(auto, 0, 0)
    changes = changes ++ inter_packet_gap(auto)
    changes = changes ++ send_ack(auto)
    phase.(:in_data, :end)

    # OUT status (zero-length DATA1)
    changes = changes ++ token_out(auto, 0, 0)
    changes = changes ++ send_data(auto, 1, [])
    phase.(:get_descriptor, :end)

    # SOF frame 1
    changes = changes ++ sof(auto, 1)

    # SETUP SET_ADDRESS (addr=1)
    set_addr_data = [0x00, 0x05, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00]
    phase.(:set_address, :begin)
    changes = changes ++ setup(auto, 0, 0, set_addr_data)

    # IN status (zero-length DATA1 from device)
    changes = changes ++ token_in(auto, 0, 0)
    changes = changes ++ inter_packet_gap(auto)
    changes = changes ++ send_ack(auto)
    phase.(:set_address, :end)

    # SOF with new address
    changes = changes ++ sof(auto, 2)
    changes = changes ++ inter_packet_gap(auto)

    # Second GET_DESCRIPTOR at new address (addr=1)
    phase.(:get_descriptor_addr1, :begin)
    changes = changes ++ setup(auto, 1, 0, setup_data)

    changes = changes ++ token_in(auto, 1, 0)
    changes = changes ++ inter_packet_gap(auto)
    changes = changes ++ send_ack(auto)

    changes = changes ++ token_in(auto, 1, 0)
    changes = changes ++ inter_packet_gap(auto)
    changes = changes ++ send_ack(auto)

    changes = changes ++ token_in(auto, 1, 0)
    changes = changes ++ inter_packet_gap(auto)
    changes = changes ++ send_ack(auto)

    # OUT status for GET_DESCRIPTOR
    changes = changes ++ token_out(auto, 1, 0)
    changes = changes ++ send_data(auto, 1, [])
    phase.(:get_descriptor_addr1, :end)

    # SOF frame 3
    changes = changes ++ sof(auto, 3)
    changes = changes ++ inter_packet_gap(auto)

    # SET_CONFIGURATION (config=1)
    set_cfg_data = [0x00, 0x09, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00]
    phase.(:set_configuration, :begin)
    changes = changes ++ setup(auto, 1, 0, set_cfg_data)

    # IN status ZLP from device
    changes = changes ++ token_in(auto, 1, 0)
    changes = changes ++ inter_packet_gap(auto)
    changes = changes ++ send_ack(auto)
    phase.(:set_configuration, :end)

    # Brief idle
    changes = changes ++ j_idle(auto, 48_000)

    changes
  end

  # ---------------------------------------------------------------------------
  # Packet builders
  # ---------------------------------------------------------------------------

  defp reset(auto) do
    drive(auto, :se0, @reset_ticks)
  end

  defp j_idle(auto, ticks) do
    drive(auto, :j, ticks)
  end

  defp inter_packet_gap(auto) do
    # Minimum 2 bit times between packets per USB spec, use 8 for safety
    drive(auto, :j, @clocks_per_bit * 32)
  end

  defp sof(auto, frame_num) do
    crc = crc5_token(frame_num, 11)
    data_bits = for i <- 0..10, do: Bitwise.band(Bitwise.bsr(frame_num, i), 1)
    crc_bits  = for i <- 4..0//-1, do: Bitwise.band(Bitwise.bsr(crc, i), 1)
    send_packet(auto, @pid_sof, data_bits ++ crc_bits)
  end

  defp setup(auto, addr, ep, data_bytes) do
    # SETUP token + DATA0 payload
    c = []
    c = c ++ send_token(auto, @pid_setup, addr, ep)
    c = c ++ inter_packet_gap(auto)
    c = c ++ send_data(auto, 0, data_bytes)
    # Device ACKs SETUP — we wait and advance time
    c = c ++ inter_packet_gap(auto)
    c ++ tick_n(auto, @clocks_per_bit * 8)  # time for device ACK
  end

  defp token_in(auto, addr, ep) do
    send_token(auto, @pid_in, addr, ep)
  end

  defp token_out(auto, addr, ep) do
    send_token(auto, @pid_out, addr, ep)
  end

  defp send_ack(auto) do
    # We send ACK to device after receiving data
    send_packet(auto, @pid_ack, [])
  end

  # ---------------------------------------------------------------------------
  # Packet framing: SYNC + PID + payload bits + EOP
  # ---------------------------------------------------------------------------

  defp send_token(auto, pid, addr, ep) do
    crc = crc5_token(Bitwise.bor(addr, Bitwise.bsl(ep, 7)), 11)
    payload_val = Bitwise.bor(addr, Bitwise.bsl(ep, 7))
    data_bits = for i <- 0..10, do: Bitwise.band(Bitwise.bsr(payload_val, i), 1)
    crc_bits  = for i <- 4..0//-1, do: Bitwise.band(Bitwise.bsr(crc, i), 1)
    send_packet(auto, pid, data_bits ++ crc_bits)
  end

  defp send_data(auto, pid_parity, data_bytes) do
    pid = if pid_parity == 0, do: @pid_data0, else: @pid_data1
    crc = crc16(data_bytes)
    crc_complement = Bitwise.band(Bitwise.bxor(crc, 0xFFFF), 0xFFFF)
    data_bits = Enum.flat_map(data_bytes, fn b ->
      for i <- 0..7, do: Bitwise.band(Bitwise.bsr(b, i), 1)
    end)
    # CRC16 complement transmitted LSB first (bits 0..15)
    crc_bits = for i <- 0..15, do: Bitwise.band(Bitwise.bsr(crc_complement, i), 1)
    send_packet(auto, pid, data_bits ++ crc_bits)
  end

  defp send_packet(auto, pid, payload_bits) do
    c = []

    # SYNC: KJKJKJKK — last symbol is K
    c = c ++ drive_sync(auto)

    # PID — 8 bits LSB first, NRZI encoded starting from K (last SYNC symbol)
    pid_bits = for i <- 0..7, do: Bitwise.band(Bitwise.bsr(pid, i), 1)
    {c, last_sym} = send_nrzi_bits(auto, pid_bits, :k, 0, c, :pid)

    # Payload bits — NRZI encoded continuing from last PID symbol
    {c, _last_sym} = send_nrzi_bits(auto, payload_bits, last_sym, 0, c, :payload)

    # EOP: SE0 SE0 J (immediately after last data bit)
    c = c ++ drive(auto, :se0, @clocks_per_bit)
    c = c ++ drive(auto, :se0, @clocks_per_bit)
    c = c ++ drive(auto, :j,   @clocks_per_bit)

    c
  end

  # SYNC pattern: from J idle, drive KJKJKJKK
  defp drive_sync(auto) do
    symbols = [:k, :j, :k, :j, :k, :j, :k, :k]
    Enum.reduce(symbols, [], fn sym, acc ->
      acc ++ drive(auto, sym, @clocks_per_bit)
    end)
  end

  # NRZI encode + bit stuffing
  # Returns {changes, last_symbol}
  defp send_nrzi_bits(auto, bits, last_sym, ones_count, c) do
    send_nrzi_bits(auto, bits, last_sym, ones_count, c, :payload)
  end

  defp send_nrzi_bits(auto, bits, last_sym, ones_count, c, field) do
    Enum.reduce(bits, {c, last_sym, ones_count}, fn bit, {acc, cur_sym, ones} ->
      # Insert stuff bit if 6 consecutive 1s
      {acc, cur_sym, ones} =
        if ones == 6 do
          # Force a 0-bit (toggle)
          next_sym = toggle(cur_sym)
          tx_emit(auto, :stuff, 0, ones, true, next_sym)
          {acc ++ drive(auto, next_sym, @clocks_per_bit), next_sym, 0}
        else
          {acc, cur_sym, ones}
        end

      # Encode bit: 1 = no change, 0 = toggle
      {next_sym, new_ones} =
        if bit == 1 do
          {cur_sym, ones + 1}
        else
          {toggle(cur_sym), 0}
        end

      tx_emit(auto, field, bit, new_ones, false, next_sym)
      {acc ++ drive(auto, next_sym, @clocks_per_bit), next_sym, new_ones}
    end)
    |> then(fn {c, sym, _ones} -> {c, sym} end)
  end

  defp toggle(:j), do: :k
  defp toggle(:k), do: :j

  # ---------------------------------------------------------------------------
  # Signal driving
  # ---------------------------------------------------------------------------

  defp drive(auto, :j, ticks) do
    Nif.set_signal(auto, :dp_diff, 1)
    Nif.set_signal(auto, :dn_raw, 0)
    t = Nif.get_time(auto)
    changes = tick_capturing(auto, ticks)
    [{t, :dp_diff, 0, 1}, {t, :dn_raw, 0, 0}] ++ changes
  end

  defp drive(auto, :k, ticks) do
    Nif.set_signal(auto, :dp_diff, 0)
    Nif.set_signal(auto, :dn_raw, 1)
    t = Nif.get_time(auto)
    changes = tick_capturing(auto, ticks)
    [{t, :dp_diff, 1, 0}, {t, :dn_raw, 0, 1}] ++ changes
  end

  defp drive(auto, :se0, ticks) do
    Nif.set_signal(auto, :dp_diff, 0)
    Nif.set_signal(auto, :dn_raw, 0)
    t = Nif.get_time(auto)
    changes = tick_capturing(auto, ticks)
    [{t, :dp_diff, 1, 0}, {t, :dn_raw, 0, 0}] ++ changes
  end

  # Tick `ticks` cycles. In per-cycle snapshot mode, step one cycle at a time and
  # snapshot after each (so sub-bit combinational signals like sample_en/rx_valid
  # are resolved). Otherwise tick the whole batch and snapshot once. The stride is
  # read from the installed snapshot sink.
  defp tick_capturing(auto, ticks) do
    case Process.get(@pdict_snapshot) do
      {^auto, _sigs, _tbl, _seq, :cycle} ->
        Enum.flat_map(1..ticks, fn _ ->
          {:ok, c} = Nif.tick(auto, :clk_48, 1)
          maybe_snapshot(auto)
          c
        end)

      _ ->
        {:ok, changes} = Nif.tick(auto, :clk_48, ticks)
        maybe_snapshot(auto)
        changes
    end
  end

  defp tick_n(auto, ticks) do
    {:ok, changes} = Nif.tick(auto, :clk_48, ticks)
    maybe_snapshot(auto)
    changes
  end

  # ---------------------------------------------------------------------------
  # CRC helpers
  # ---------------------------------------------------------------------------

  # CRC5 for token packets (addr + ep, 11 bits)
  defp crc5_token(data, nbits) do
    crc = Enum.reduce(0..(nbits - 1), 0x1F, fn i, crc ->
      bit = Bitwise.band(Bitwise.bsr(data, i), 1)
      inv = Bitwise.bxor(bit, Bitwise.band(Bitwise.bsr(crc, 4), 1))
      crc = Bitwise.band(Bitwise.bsl(crc, 1), 0x1F)
      if inv == 1, do: Bitwise.bxor(crc, 0x05), else: crc
    end)
    Bitwise.band(Bitwise.bxor(crc, 0x1F), 0x1F)
  end

  # CRC16 for data packets
  defp crc16(bytes) do
    # USB CRC16: reflected LFSR, polynomial 0xA001 (reflected 0x8005)
    # Must match Hw.USB.CRC16 — init 0xFFFF, complement transmitted MSB first
    bits = Enum.flat_map(bytes, fn b -> for i <- 0..7, do: Bitwise.band(Bitwise.bsr(b, i), 1) end)
    Enum.reduce(bits, 0xFFFF, fn bit, crc ->
      inv = Bitwise.bxor(bit, Bitwise.band(crc, 1))
      crc = Bitwise.bsr(crc, 1)
      if inv == 1, do: Bitwise.bxor(crc, 0xA001), else: crc
    end)
  end

end
