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
