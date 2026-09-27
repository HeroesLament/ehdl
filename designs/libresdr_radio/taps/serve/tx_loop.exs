# Nervezynq.TxLoop: AD9363 TX data port gate, via the chip's internal
# data-port loopback (REG_OBSERVE_CONFIG 0x3F5 bit 0: TX data port -> RX data
# port, digital, no RF). Transcribed from ad9361_bist_loopback() mode 1 in
# no-OS ad9361.c; for 2R2T, ad9361_int_loopback_fix_ch_cross() is a no-op.
#
# Fabric: LibreSDRRadio.Top with Hw.AD936xTxPort (build_tx). The TX port sends
# a fixed pattern per frame, ctr advancing once per frame:
#     I1 = ctr   Q1 = ~ctr   I2 = {ctr[5:0], ctr[11:6]}   Q2 = 0xA5C
# EMIO bank 2: [3] tx_enable [4] half_swap [5] iq_swap [6] chan_swap [7] fb_clk inverted
#
#   Code.compile_file("/data/lsdr_bringup.exs")
#   LsdrBringup.run("http://<peer>:8101", ["tx_loop.exs"], "<tx bitstream>.bin")
#   Nervezynq.TxLoop.sweep()          # all 16 order/phase combos, scored
#   Nervezynq.TxLoop.once(opts)       # one combo, with raw samples
#
# TX DMA (build_txdma: HP0 reader -> tbuf -> TX port). EMIO bank 2:
#   [2] clear stickies  [8] source 0 pattern / 1 DMA  [9] reader enable
#   [10] cyclic (whole 1 MB ring loops)  [11] run
# bank 3 = head_addr. STATUS0 (AXI 0x1C): [22:10] read_ptr[19:7],
# [30:23] bursts[7:0], [31] underflow sticky.
#   Nervezynq.TxLoop.dma_gate()       # ring = marked pattern, cyclic, scored
#
# Over the air (dr-a TX, dr-b RX, as RF_FIRST_LIGHT.md; needs tx_tone.exs):
#   TxTone.set_tx_lo(2_413_000_000)
#   TxLoop.dma_fill_tone()            # +Fs/32 complex tone, TX1 only
#   TxLoop.dma_burst(3000)            # keyed from DDR, unkeys itself
#   TxLoop.dma_last()                 # status recorded at unkey

defmodule Nervezynq.TxLoop do
  import Bitwise
  alias Nervezynq.{AD9363, PortWire, SDR}

  @gpio_base 0xE000_A000
  @mask_data_2_lsw 0x10
  @dirm_2 0x284
  @oen_2 0x288
  @bits 0xF8

  @reg_observe_config 0x3F5
  @loop_test_enable 0x01

  defp gpio do
    case Process.get(:tx_loop_gpio) do
      nil ->
        {:ok, g} = PortWire.open(@gpio_base, 0x1000)
        {:ok, d} = PortWire.transact(g, {:read32, @dirm_2})
        :ok = PortWire.transact(g, {:write32, @dirm_2, d ||| @bits})
        {:ok, o} = PortWire.transact(g, {:read32, @oen_2})
        :ok = PortWire.transact(g, {:write32, @oen_2, o ||| @bits})
        Process.put(:tx_loop_gpio, g)
        g

      g ->
        g
    end
  end

  # Bits 3..7 only; MASK_DATA_2_LSW upper half: 1 = leave alone.
  defp ctrl(opts) do
    v =
      (if opts[:enable], do: 1 <<< 3, else: 0) |||
        (if opts[:half_swap], do: 1 <<< 4, else: 0) |||
        (if opts[:iq_swap], do: 1 <<< 5, else: 0) |||
        (if opts[:chan_swap], do: 1 <<< 6, else: 0) |||
        (if opts[:fb_inv], do: 1 <<< 7, else: 0)

    :ok = PortWire.transact(gpio(), {:write32, @mask_data_2_lsw, (0xFFFF &&& bnot(@bits)) <<< 16 ||| v})
  end

  def loopback(on?) do
    {:ok, r} = AD9363.read(@reg_observe_config)
    v = if on?, do: r ||| @loop_test_enable, else: r &&& bnot(@loop_test_enable)
    AD9363.write_verify(@reg_observe_config, v)
  end

  defp u12(v) when v < 0, do: v + 4096
  defp u12(v), do: v
  defp halves_swapped(c), do: (c &&& 0x3F) <<< 6 ||| c >>> 6

  alias Nervezynq.AD9363.ENSM

  @tx_delay_measured 0x08

  @doc """
  ALERT -> FDD mode -> FDD, in that order. Selecting FDD mode while the ENSM
  sits in TDD RX leaves the transition stuck in ALERT (ensm_timeout,
  2026-09-26); selecting it from ALERT works, and only then does the TX VCO
  report lock (0x287 = 2). TX attenuation is forced to maximum first.
  """
  def fdd_enter do
    {:ok, _} = Nervezynq.TxTone.set_tx_atten(89.75)
    {:ok, _} = ENSM.set_state(:alert)
    :ok = ENSM.set_mode(true)
    ENSM.set_state(:fdd)
  end

  @doc "Back to the receive-only operating point: ALERT, TDD, RX, max attenuation."
  def fdd_exit do
    ENSM.set_state(:alert)
    ENSM.set_mode(false)
    ENSM.set_state(:rx)
    Nervezynq.TxTone.set_tx_atten(89.75)
  end

  @doc """
  The TX data port gate, guarded: FDD with the transmitter at 89.75 dB,
  TX delay at the measured 0x08, `reps` captures of `n` frames, then restore.
  An unlinked process restores ALERT/TDD/RX and max attenuation after
  `guard_ms` whatever happens to the caller (the 2026-09-23 rule). Needs
  tx_tone.exs compiled (attenuation helpers).
  """
  def gate(opts \\ []) do
    reps = Keyword.get(opts, :reps, 3)
    n = Keyword.get(opts, :n, 1000)
    delay = Keyword.get(opts, :tx_delay, @tx_delay_measured)
    spawn(fn -> Process.sleep(Keyword.get(opts, :guard_ms, 30_000)); fdd_exit() end)
    {:ok, orig} = AD9363.read(0x007)

    try do
      {:ok, _} = fdd_enter()
      {:ok, _} = AD9363.write_verify(0x007, delay)
      scores = for _ <- 1..reps, do: once([quiet: true], n).score
      pass = Enum.all?(scores, &(&1.fit >= n - 4))
      r = %{gate: :tx_data_port, tx_delay: delay, pass: pass, scores: scores}
      IO.puts("TXLOOP GATE " <> inspect(r))
      r
    after
      AD9363.write_verify(0x007, orig)
      fdd_exit()
    end
  end

  # --- TX DMA -----------------------------------------------------------------
  @tx_base 0x3FD0_0000
  @tx_ring 0x0010_0000
  @dirm_3 0x2C4
  @oen_3 0x2C8
  @data_3 0x4C
  @dma_bits 0x0F04
  @status0 0x1C
  # Q2 in the DDR ring. The fabric pattern's is 0xA5C, so a capture that
  # scores against this marker cannot have come from the pattern generator.
  @dma_q2 0x3C5

  defp dma_ports do
    case Process.get(:tx_dma_ports) do
      nil ->
        g = gpio()
        {:ok, d} = PortWire.transact(g, {:read32, @dirm_2})
        :ok = PortWire.transact(g, {:write32, @dirm_2, d ||| @dma_bits})
        {:ok, o} = PortWire.transact(g, {:read32, @oen_2})
        :ok = PortWire.transact(g, {:write32, @oen_2, o ||| @dma_bits})
        :ok = PortWire.transact(g, {:write32, @dirm_3, 0xFFFF_FFFF})
        :ok = PortWire.transact(g, {:write32, @oen_3, 0xFFFF_FFFF})
        {:ok, tx} = PortWire.open(@tx_base, @tx_ring)
        p = %{gpio: g, tx: tx}
        Process.put(:tx_dma_ports, p)
        p

      p ->
        p
    end
  end

  # Bits 2 and 8..11 only (MASK_DATA_2_LSW: upper half 1 = leave alone).
  defp dma_ctrl(opts) do
    v =
      (if opts[:clear], do: 1 <<< 2, else: 0) |||
        (if opts[:dma], do: 1 <<< 8, else: 0) |||
        (if opts[:enable], do: 1 <<< 9, else: 0) |||
        (if opts[:cyclic], do: 1 <<< 10, else: 0) |||
        (if opts[:run], do: 1 <<< 11, else: 0)

    %{gpio: g} = dma_ports()
    :ok = PortWire.transact(g, {:write32, @mask_data_2_lsw, (0xFFFF &&& bnot(@dma_bits)) <<< 16 ||| v})
  end

  def dma_head(addr) do
    %{gpio: g} = dma_ports()
    :ok = PortWire.transact(g, {:write32, @data_3, addr})
  end

  def dma_status do
    {:ok, v} = Nervezynq.Fabric.read32(@status0)
    {:ok, s2} = Nervezynq.Fabric.read32(0x24)
    %{read_ptr: (v >>> 10 &&& 0x1FFF) <<< 7, bursts_lo: v >>> 23 &&& 0xFF, uflow: v >>> 31 &&& 1,
      rresp_errs: s2 >>> 24 &&& 0xF, rlast_errs: s2 >>> 28 &&& 0xF}
  end

  # Frame k in the RX packer / SampleFormat layout, as two little-endian u32:
  #   [11:0] I1 = k   [23:12] Q1 = ~k   [35:24] I2 = halves swapped   [47:36] Q2 = marker
  defp dma_frame(k) do
    i1 = k &&& 0xFFF
    q1 = bnot(k) &&& 0xFFF
    i2 = halves_swapped(i1)
    lo = i1 ||| q1 <<< 12 ||| (i2 &&& 0xFF) <<< 24
    hi = i2 >>> 8 ||| @dma_q2 <<< 4
    [lo, hi]
  end

  @doc "Fill the whole TX ring with marked frames 0..131071 (k mod 4096 wraps cleanly)."
  def dma_fill do
    %{tx: tx} = dma_ports()

    0..(div(@tx_ring, 8) - 1)
    |> Enum.chunk_every(2048)
    |> Enum.each(fn chunk ->
      vals = Enum.flat_map(chunk, &dma_frame/1)
      :ok = PortWire.transact(tx, {:write_block, hd(chunk) * 8, vals}, 15_000)
    end)
  end

  def dma_stop do
    dma_ctrl(run: false)
  end

  # --- over the air ------------------------------------------------------------
  # Same limits as TxTone: no PA on this board, but 0 dB attenuation is still
  # the chip's full output; bursts are bounded and unkey on the board itself.
  @dma_min_atten_db 10.0
  @dma_max_burst_ms 10_000
  @ring_frames 131_072

  @doc """
  Fill the ring with a complex tone on TX1: `cycles` per 131072-frame ring
  (4096 = Fs/32, 250 kHz at 8 Msps; an integer keeps the loop seamless),
  peak `amp` of 2047 (1024 = -6 dBFS). I = cos, Q = sin: positive
  frequency if the chip's I/Q convention is the usual one. TX2 = 0.
  """
  def dma_fill_tone(cycles \\ 4096, amp \\ 1024) when amp in 0..2047 do
    %{tx: tx} = dma_ports()
    period = div(@ring_frames, Integer.gcd(cycles, @ring_frames))

    table =
      for k <- 0..(period - 1) do
        ph = 2 * :math.pi() * rem(cycles * k, @ring_frames) / @ring_frames
        i = round(amp * :math.cos(ph)) &&& 0xFFF
        q = round(amp * :math.sin(ph)) &&& 0xFFF
        [i ||| q <<< 12, 0]
      end
      |> List.to_tuple()

    0..(@ring_frames - 1)
    |> Enum.chunk_every(2048)
    |> Enum.each(fn chunk ->
      vals = Enum.flat_map(chunk, &elem(table, rem(&1, period)))
      :ok = PortWire.transact(tx, {:write_block, hd(chunk) * 8, vals}, 15_000)
    end)

    {:ok, %{cycles: cycles, amp: amp, period_frames: period}}
  end

  @doc """
  Key from DDR for `ms`, then unkey, enforced on this board (TxTone.burst/2's
  rule). The unkey process is armed before the ENSM leaves ALERT. Primes the
  cyclic ring, selects the DMA source, sets `:atten_db` (default 30.0,
  floor #{@dma_min_atten_db} unless `force: true`), then ENSM -> TX.

  Also sets REG_TX_CLOCK_DATA_DELAY (0x007) to `:tx_delay` (default the
  measured 0x08) and leaves it there: the boot value 0x00 corrupts the
  falling-edge words, which on air showed as a -7 dBc image, Fs/4 spurs and
  a 4.5 dB higher floor (dr-a -> dr-b, 2026-09-26). gate/1 and dma_gate/1
  restore whatever was there before them, i.e. 0x00 on current firmware.
  """
  def dma_burst(ms, opts \\ []) when is_integer(ms) and ms > 0 and ms <= @dma_max_burst_ms do
    atten = Keyword.get(opts, :atten_db, 30.0)

    if atten < @dma_min_atten_db and not Keyword.get(opts, :force, false) do
      {:error, {:atten_below_floor, atten, @dma_min_atten_db}}
    else
      {:ok, _} = Nervezynq.TxTone.set_tx_atten(atten)
      {:ok, _} = AD9363.write_verify(0x007, Keyword.get(opts, :tx_delay, @tx_delay_measured))
      AD9363.bist_tone(:disable)
      AD9363.bist_prbs(:disable)
      {:ok, _} = loopback(false)
      dma_stop()
      Process.sleep(2)
      dma_head(@tx_base)
      dma_ctrl(run: true, enable: true, cyclic: true)
      Process.sleep(2)
      primed = dma_status()
      ctrl(enable: true)
      dma_ctrl(run: true, enable: true, cyclic: true, dma: true, clear: true)
      Process.sleep(1)
      dma_ctrl(run: true, enable: true, cyclic: true, dma: true)

      pid = spawn(fn -> Process.sleep(ms); dma_unkey() end)

      case ENSM.set_state(:tx) do
        {:ok, _} ->
          {:ok, %{burst_ms: ms, primed: primed, ensm: ENSM.state(), reg_007: AD9363.read(0x007),
                  tx_atten: Nervezynq.TxTone.tx_atten(), tx_lo_hz: Nervezynq.TxTone.tx_lo_freq(),
                  unkey_pid: pid}}

        err ->
          dma_unkey()
          err
      end
    end
  end

  @doc "Unkey: ENSM to ALERT first, record DMA status, stop DMA and the port, max attenuation."
  def dma_unkey do
    ENSM.set_state(:alert)
    st = dma_status()
    dma_stop()
    ctrl([])
    Nervezynq.TxTone.set_tx_atten(89.75)
    r = %{status_at_unkey: st, ensm: ENSM.state(), tx_atten: Nervezynq.TxTone.tx_atten()}
    :persistent_term.put({__MODULE__, :last}, r)
    {:ok, r}
  end

  def dma_last, do: :persistent_term.get({__MODULE__, :last}, nil)

  @doc "Score against the DMA frames: every field, the marker, and +1 continuity."
  def dma_score(%{ch1: ch1, ch2: ch2}) do
    rows =
      Enum.zip(ch1, ch2)
      |> Enum.map(fn {{i1, q1}, {i2, q2}} -> {u12(i1), u12(q1), u12(i2), u12(q2)} end)

    fit =
      Enum.count(rows, fn {i1, q1, i2, q2} ->
        q1 == (bnot(i1) &&& 0xFFF) and i2 == halves_swapped(i1) and q2 == @dma_q2
      end)

    steps =
      rows
      |> Enum.map(&elem(&1, 0))
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.count(fn [a, b] -> b == (a + 1 &&& 0xFFF) end)

    zeros = Enum.count(rows, &(&1 == {0, 0, 0, 0}))
    pattern = Enum.count(rows, fn {_, _, _, q2} -> q2 == 0xA5C end)
    %{n: length(rows), fit: fit, ctr_steps: steps, zeros: zeros, pattern_frames: pattern}
  end

  @doc """
  The TX DMA gate, guarded like gate/1: ring filled with marked frames,
  reader primed in cyclic mode, source switched to DMA, `reps` captures of
  `n` frames through the data-port loopback. Pass = every frame fits the
  marker, continuity n-1 each, no underflow, no RRESP/RLAST errors.
  """
  def dma_gate(opts \\ []) do
    reps = Keyword.get(opts, :reps, 3)
    n = Keyword.get(opts, :n, 1000)
    delay = Keyword.get(opts, :tx_delay, @tx_delay_measured)
    spawn(fn -> Process.sleep(Keyword.get(opts, :guard_ms, 60_000)); dma_stop(); fdd_exit() end)
    {:ok, orig} = AD9363.read(0x007)

    try do
      t0 = System.monotonic_time(:millisecond)
      :ok = dma_fill()
      fill_ms = System.monotonic_time(:millisecond) - t0

      dma_stop()
      Process.sleep(2)
      dma_head(@tx_base)
      dma_ctrl(run: true, enable: true, cyclic: true)
      Process.sleep(2)
      primed = dma_status()

      {:ok, _} = fdd_enter()
      {:ok, _} = AD9363.write_verify(0x007, delay)
      AD9363.bist_prbs(:disable)
      AD9363.bist_tone(:disable)
      {:ok, _} = loopback(true)
      ctrl(enable: true)
      dma_ctrl(run: true, enable: true, cyclic: true, dma: true, clear: true)
      Process.sleep(1)
      dma_ctrl(run: true, enable: true, cyclic: true, dma: true)
      Process.sleep(5)

      scores =
        for _ <- 1..reps do
          {:ok, cap} = SDR.rx(n)
          dma_score(cap)
        end

      st = dma_status()
      pass =
        Enum.all?(scores, &(&1.fit == n and &1.ctr_steps == n - 1)) and st.uflow == 0 and
          st.rresp_errs == 0 and st.rlast_errs == 0

      r = %{gate: :tx_dma, pass: pass, fill_ms: fill_ms, primed: primed, status: st, scores: scores}
      IO.puts("TXDMA GATE " <> inspect(r))
      r
    after
      dma_stop()
      ctrl([])
      loopback(false)
      AD9363.write_verify(0x007, orig)
      fdd_exit()
    end
  end

  @doc "Score a capture against the pattern: fraction of pairs that fit, plus ctr continuity."
  def score(%{ch1: ch1, ch2: ch2}) do
    rows =
      Enum.zip(ch1, ch2)
      |> Enum.map(fn {{i1, q1}, {i2, q2}} -> {u12(i1), u12(q1), u12(i2), u12(q2)} end)

    fit =
      Enum.count(rows, fn {i1, q1, i2, q2} ->
        q1 == (bnot(i1) &&& 0xFFF) and i2 == halves_swapped(i1) and q2 == 0xA5C
      end)

    steps =
      rows
      |> Enum.map(&elem(&1, 0))
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.count(fn [a, b] -> b == (a + 1 &&& 0xFFF) end)

    n = length(rows)

    # Per field, so a partially-timed port shows WHICH edges fail.
    q1_ok = Enum.count(rows, fn {i1, q1, _, _} -> q1 == (bnot(i1) &&& 0xFFF) end)
    i2_ok = Enum.count(rows, fn {i1, _, i2, _} -> i2 == halves_swapped(i1) end)
    q2_ok = Enum.count(rows, fn {_, _, _, q2} -> q2 == 0xA5C end)

    %{n: n, fit: fit, ctr_steps: steps, q1_ok: q1_ok, i2_ok: i2_ok, q2_ok: q2_ok,
      fit_frac: if(n > 0, do: Float.round(fit / n, 3), else: 0.0)}
  end

  # REG_TX_CLOCK_DATA_DELAY: FB_CLK delay [7:4], TX data delay [3:0]
  # (ad9361.h FB_CLK_DELAY / TX_DATA_DELAY). The TX mirror of the RX eye
  # sweep that settled 0x006 = 0x0A.
  @reg_tx_clock_data_delay 0x007

  @doc """
  Sweep all 256 values of REG_TX_CLOCK_DATA_DELAY with `opts` held, scoring
  each. Caller must have the ENSM in FDD with the loopback conditions set up
  (see fdd_eye/1). Restores the register afterwards.
  """
  def eye(opts \\ [], n \\ 128) do
    {:ok, orig} = AD9363.read(@reg_tx_clock_data_delay)

    res =
      try do
        for v <- 0..255 do
          {:ok, _} = AD9363.write_verify(@reg_tx_clock_data_delay, v)
          %{score: s} = once([{:quiet, true} | opts], n)
          {v, s.fit, s.ctr_steps, s.q1_ok, s.i2_ok, s.q2_ok}
        end
      after
        AD9363.write_verify(@reg_tx_clock_data_delay, orig)
      end

    good = Enum.filter(res, fn {_, fit, _, _, _, _} -> fit >= n - 4 end)
    IO.puts("TXLOOP EYE opts=#{inspect(opts)} full-fit cells: #{length(good)}/256 " <>
              inspect(Enum.map(good, &Integer.to_string(elem(&1, 0), 16))))
    res
  end

  @doc "One combination: loopback on, pattern on, capture, score. Always cleans up."
  def once(opts \\ [], n \\ 256) do
    AD9363.bist_prbs(:disable)
    AD9363.bist_tone(:disable)
    {:ok, lb} = loopback(true)
    ctrl(Keyword.put(opts, :enable, true))
    Process.sleep(5)

    result =
      try do
        case SDR.rx(n) do
          {:ok, cap} ->
            %{opts: opts, observe_config: lb, score: score(cap), head: Enum.take(Enum.zip(cap.ch1, cap.ch2), 4)}

          e ->
            %{opts: opts, error: e}
        end
      after
        ctrl([])
        loopback(false)
      end

    unless opts[:quiet], do: IO.puts("TXLOOP ONCE " <> inspect(Map.delete(result, :head)))
    result
  end

  @doc "All 16 combos of half/iq/chan swap and fb_clk phase, best first."
  def sweep(n \\ 256) do
    combos =
      for h <- [false, true], i <- [false, true], c <- [false, true], f <- [false, true],
          do: [half_swap: h, iq_swap: i, chan_swap: c, fb_inv: f]

    results =
      combos
      |> Enum.map(fn o -> once(o, n) end)
      |> Enum.sort_by(fn r -> -(get_in(r, [:score, :fit]) || -1) end)

    IO.puts("TXLOOP BEST " <> inspect(hd(results) |> Map.delete(:head)))
    results
  end
end
