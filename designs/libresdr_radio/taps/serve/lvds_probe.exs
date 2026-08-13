defmodule Nervezynq.LVDSProbe do
  @moduledoc """
  Statistical checks on the LVDS receive front end, designed around the fact
  that `STATUS3` cannot be read coherently.

  ## Why this is statistical and not a decoder

  `sample_word` is a 12-bit register in the `DATA_CLK` domain, wired
  combinationally into the AXI-Lite read path in the `axi_clk` domain — no
  synchroniser, no gray code, no capture handshake. Compare `dclk_count`, which
  was deliberately reduced to a single toggling bit before crossing for exactly
  this reason.

  Two consequences, and the second is the one that bites:

    * Individual bits can be captured either side of a transition, so a read can
      return a word the register never held.
    * Reads are not consecutive samples. The AXI round trip is thousands of
      `DATA_CLK` periods, and its phase is unrelated to the transceiver's.

  So anything that needs sample *order* — a PRBS check, a decoder, any DSP — is
  off the table until the fabric grows a capture buffer. What is still available
  is everything order-free: per-bit statistics, value histograms, and the
  response of those to a change in what the AD9363 is transmitting.

  That last part is what makes this a real measurement rather than a vibe.
  `STATUS3` being non-zero proves transitions arrive. `STATUS3` changing *in the
  specific way a commanded change predicts* is a much stronger claim, and it is
  one this module can actually make.

  ## The bit map

  From `LibreSDRRadio.Top`:

      sample_word = {fall_word, q1_bus_d}

  so bits 5:0 are the six lanes captured on the rising `DATA_CLK` edge and bits
  11:6 the same six lanes on the falling edge. `bit_ones/2` reports against that
  map, which means a dead lane or a stuck DDR edge shows up as a named bit
  sitting at 0.0 or 1.0 while its neighbours sit near 0.5 — a diagnosis, not a
  number to squint at.
  """

  import Bitwise
  alias Nervezynq.{Fabric, AD9363, Regs}

  # Register offsets and bit positions are NOT written here. They come from
  # `ehdl/designs/libresdr_radio/regmap.exs` -- the same spec `top.ex` unpacks
  # -- via `Nervezynq.Regs`, so driver and fabric cannot drift apart.
  # `@status3` survives only for `sample/1`, the legacy raw-read path.
  @status3 0x28

  @cap_depth 4096

  @doc """
  Capture `n` CONSECUTIVE sample words into the fabric buffer and read them out.

  This is what the old `sample/1` could never do. `STATUS3` used to expose the
  live `sample_word` across an unsynchronised domain crossing, so reads could
  tear and were separated by thousands of DATA_CLK periods at unrelated phase.
  Now the fabric captures 1024 samples back-to-back at full rate, halts, and the
  AXI side reads the static buffer at leisure.

  Order is meaningful here, which unlocks everything that needs it: the RX_FRAME
  waveform, an LFSR fit against the BIST PRBS, and any DSP at all.

  Returns `{:ok, [word]}` where each word is 26 bits:

    * `[11:0]`  — `sample_a`, the rising-edge sample, `{current, previous}`
    * `[23:12]` — `sample_b`, the falling-edge sample, same assembly
    * `[25:24]` — the RX_FRAME pair

  A 12-bit sample spans two DATA_CLK cycles, so only alternate words carry a
  correctly-aligned pair; see `Nervezynq.SampleFormat` for choosing the parity.
  """
  def capture(n \\ @cap_depth) when n <= @cap_depth do
    # Start from what the fabric actually holds, so flipping `cap_arm` does not
    # disturb `cap_rd_addr` (and vice versa) in the same word.
    Regs.sync_shadow()

    # Arm is a toggle, for the same reason the SPI `go` bit is: an AXI register
    # holds its value and has no write-pulse semantics. The fabric edge-detects.
    Regs.pulse_cap_arm()

    with :ok <- await_done(400) do
      # Tier 0 readout (2026-08-03). The fabric auto-advances the capture
      # read pointer on every completed STATUS3 read (top.ex), proven on
      # silicon this session: seek-to-0 then read_repeat returned words
      # identical to the addressed walk. One seek plus ONE port round trip
      # replaces 2N round trips — the ~200x lever Fabric.read_repeat/2's
      # docstring promises, and the difference between a 0.4 row/s
      # waterfall and a live one. STATUS3 bit 26 (cap_done) rides along in
      # the raw words; masking to 26 bits drops it, same as cap_word did.
      Regs.put_cap_rd_addr(0)

      with {:ok, raw} <- Fabric.read_repeat(@status3, n) do
        {:ok, Enum.map(raw, &(&1 &&& 0x3FFFFFF))}
      end
    end
  end

  defp await_done(0), do: {:error, :capture_timeout}

  defp await_done(n) do
    if Regs.cap_done() == 1 do
      :ok
    else
      Process.sleep(1)
      await_done(n - 1)
    end
  end

  @doc "The rising-edge sample stream only."
  def capture_samples(n \\ @cap_depth) do
    with {:ok, words} <- capture(n), do: {:ok, Enum.map(words, &(&1 &&& 0xFFF))}
  end

  @doc "Both edges as `{sample_a, sample_b}` pairs, in capture order."
  def capture_pairs(n \\ @cap_depth) do
    with {:ok, words} <- capture(n) do
      {:ok, Enum.map(words, &{&1 &&& 0xFFF, &1 >>> 12 &&& 0xFFF})}
    end
  end

  @doc "The RX_FRAME bit pairs, in capture order — the frame waveform."
  def capture_frame(n \\ @cap_depth) do
    with {:ok, words} <- capture(n), do: {:ok, Enum.map(words, &(&1 >>> 24 &&& 0x3))}
  end

  @doc """
  Legacy asynchronous reads of `STATUS3`.

  Retained only so the historical statistics remain reproducible. `STATUS3` now
  carries the capture buffer's read port, so this no longer samples anything
  live — use `capture/1`.
  """
  def sample(n \\ 20_000) do
    Enum.map(1..n, fn _ ->
      {:ok, v} = Fabric.read32(@status3)
      v
    end)
  end

  @doc """
  Order-free statistics over a batch of `STATUS3` reads.

  `distinct` and `values_for_90pct` are the shape test. A tone at `Fs/32` is
  periodic over 32 samples, so the sample word can only take a small set of
  values and the mass should concentrate in a few dozen of them. A PRBS should
  spread over most of the 4096. Noise on an unconfigured receiver should look
  like neither.
  """
  def summarise(words) do
    n = length(words)
    sw = Enum.map(words, &(&1 &&& 0xFFF))
    hist = Enum.frequencies(sw)
    sorted = Enum.sort_by(hist, fn {_v, c} -> -c end)

    %{
      n: n,
      distinct: map_size(hist),
      zero_fraction: frac(Map.get(hist, 0, 0), n),
      values_for_90pct: cover(sorted, n, 0.90),
      top: sorted |> Enum.take(10) |> Enum.map(fn {v, c} -> {hex12(v), frac(c, n)} end),
      frame_pair:
        words
        |> Enum.map(&(&1 >>> 24 &&& 0x3))
        |> Enum.frequencies()
        |> Map.new(fn {k, c} -> {k, frac(c, n)} end),
      bit_ones: bit_ones(sw, n)
    }
  end

  @doc """
  Fraction of samples in which each captured bit is 1, labelled by lane and
  DDR edge.

  This is the single most informative number available without a capture
  buffer, and it is immune to the tearing: a torn word is still a word whose
  individual bits were each genuinely on the wire at some instant. A lane that
  is not connected, not terminated well enough to resolve, or captured on the
  wrong edge does not average to 0.5 over random data.
  """
  def bit_ones(sample_words, n) do
    for i <- 0..11 do
      ones = Enum.count(sample_words, fn v -> (v >>> i &&& 1) == 1 end)
      {bit_label(i), frac(ones, n)}
    end
  end

  # sample_word = {fall_word, q1_bus_d}: bits 5:0 rising edge, 11:6 falling.
  defp bit_label(i) when i < 6, do: :"rise_d#{i}"
  defp bit_label(i), do: :"fall_d#{i - 6}"

  # --- the sweep ---------------------------------------------------------------

  @doc """
  The AD9363 states worth comparing, in order.

  The two masked-tone states are the sharp test and the reason this sweep is
  worth running before any fabric change. ADI's mask bits blank a channel's data
  in the BIST path, so `:tone_ch1_only` and `:tone_ch2_only` should partition:
  whatever fraction of sample words goes to exactly zero in one should be very
  close to the complement of the other, and the two should sum to about one.

  That prediction is quantitative, it is falsifiable, and — this is the point —
  it survives the tearing. A word torn between two zeros is still zero. So a
  clean partition is strong evidence that the lane capture and the data port
  framing are fundamentally right, and no partition at all is strong evidence
  that they are not. Neither conclusion requires a single coherent read.
  """
  def states, do: [:quiet, :tone_fs32, :tone_ch1_only, :tone_ch2_only, :prbs]

  defp setup(:quiet), do: AD9363.bist_tone(:disable)
  defp setup(:tone_fs32), do: AD9363.bist_tone(:rx, 0, 0, 0b0000)
  # mask bits are ch1 I, ch1 Q, ch2 I, ch2 Q from bit 0 up; masking channel 2
  # leaves channel 1 carrying the tone, and vice versa.
  defp setup(:tone_ch1_only), do: AD9363.bist_tone(:rx, 0, 0, 0b1100)
  defp setup(:tone_ch2_only), do: AD9363.bist_tone(:rx, 0, 0, 0b0011)
  defp setup(:prbs), do: AD9363.bist_prbs(:rx)

  @doc """
  Run every state and collect statistics for each.

  `DATA_CLK` is re-measured per state. If it moves, the states are not
  comparable and nothing below it means anything — which is worth knowing
  before reading a histogram, not after.
  """
  def sweep(n \\ 5_000) do
    Enum.map(states(), fn state ->
      {:ok, _reg} = setup(state)
      Process.sleep(50)
      {:ok, bist} = AD9363.bist_state()
      clk = data_clk_mhz(200)
      {state, summarise(sample(n)) |> Map.merge(%{bist: bist, data_clk_mhz: clk})}
    end)
  end

  @doc "DATA_CLK in MHz, from the divide-by-512 edge counter, over `ms`."
  def data_clk_mhz(ms \\ 500) do
    a = Regs.dclk_count()
    t0 = System.monotonic_time(:microsecond)
    Process.sleep(ms)
    b = Regs.dclk_count()
    t1 = System.monotonic_time(:microsecond)
    Float.round((b - a) * 512 / (t1 - t0), 3)
  end

  @doc "Run the sweep and print it."
  def report(n \\ 5_000) do
    results = sweep(n)

    Enum.each(results, fn {state, r} ->
      IO.puts("")
      IO.puts("=== #{state} ===")
      IO.puts("  bist        : #{inspect(r.bist)}")
      IO.puts("  data_clk    : #{r.data_clk_mhz} MHz")
      IO.puts("  distinct    : #{r.distinct} of 4096   (90% of mass in #{r.values_for_90pct})")
      IO.puts("  exact zero  : #{r.zero_fraction}")
      IO.puts("  frame_pair  : #{inspect(r.frame_pair)}")
      IO.puts("  top values  : #{inspect(r.top)}")

      IO.puts("  bit ones    :")

      r.bit_ones
      |> Enum.chunk_every(6)
      |> Enum.each(fn row ->
        IO.puts("      " <> Enum.map_join(row, "  ", fn {l, f} -> "#{l}=#{f}" end))
      end)
    end)

    IO.puts("")
    IO.puts("--- mask partition check ---")
    m = Map.new(results)
    z1 = m[:tone_ch1_only].zero_fraction
    z2 = m[:tone_ch2_only].zero_fraction

    IO.puts("  zero fraction, ch1 only : #{z1}")
    IO.puts("  zero fraction, ch2 only : #{z2}")
    IO.puts("  sum                     : #{Float.round(z1 + z2, 4)}   (predict ~1.0)")

    results
  end


  # --- interface timing: eye diagram ------------------------------------------

  @reg_rx_clock_data_delay 0x006

  @doc """
  Fraction of period-4 slots where `w[n] == w[n+2]` for `n = 0 mod 4`.

  This is the alignment invariant discovered in the first coherent capture: with
  a BIST pattern injected and both receive channels fed from it, slot 0 and slot
  2 of each 4-sample frame carry identical values. Measured at 255/256 with the
  delays at zero.

  It makes an excellent timing oracle for three reasons. It needs no knowledge of
  the PRBS polynomial; it is self-aligning, since only one of the four phase
  classes shows the effect; and it degrades gracefully, so a marginal setting
  reads as 80% rather than as a pass/fail. `ad9361_dig_tune()` uses ADI's HDL PN
  checker for the same purpose — this is the same idea with an invariant we can
  verify ourselves.
  """
  def match_rate(words) do
    arr = words |> Enum.map(&(&1 &&& 0xFFF)) |> List.to_tuple()
    n = tuple_size(arr)

    # Best of all four phase classes, NOT a fixed one.
    #
    # Capture begins at an arbitrary point relative to the transceiver's 4-sample
    # frame, so which `rem(i, 4)` class carries the invariant shifts from capture
    # to capture. Pinning it at 0 — as the first version of this did — turns the
    # oracle into a coin flip on alignment, and produces an "eye diagram" of
    # scattered 100s and 0s that looks like a marginal interface and is really
    # just phase luck. Taking the maximum makes the measurement phase-invariant,
    # which is what it needed to be to mean anything.
    {best, total} =
      Enum.map(0..3, fn phase ->
        pairs =
          for i <- 0..(n - 3), rem(i, 4) == phase do
            elem(arr, i) == elem(arr, i + 2)
          end

        {Enum.count(pairs, & &1), length(pairs)}
      end)
      |> Enum.max_by(fn {ok, tot} -> if tot > 0, do: ok / tot, else: 0 end)

    {best, total}
  end

  @doc "Match rate per phase class, for when the alignment itself is the question."
  def match_rate_by_phase(words) do
    arr = words |> Enum.map(&(&1 &&& 0xFFF)) |> List.to_tuple()
    n = tuple_size(arr)

    Map.new(0..3, fn phase ->
      pairs = for i <- 0..(n - 3), rem(i, 4) == phase, do: elem(arr, i) == elem(arr, i + 2)
      {phase, {Enum.count(pairs, & &1), length(pairs)}}
    end)
  end

  @doc """
  Sweep `REG_RX_CLOCK_DATA_DELAY` and print the match rate as a 16x16 grid.

  `DATA_CLK_DELAY` is bits 7:4 and `RX_DATA_DELAY` bits 3:0, each 0..15. Together
  they slide the sampling instant relative to the data, so the grid is an eye
  diagram measured in software: a broad plateau of 100 means comfortable timing
  margin, and a narrow ridge means the interface is only just working.

  **This is the measurement the `DIFF_TERM` question has been waiting for since
  session 1.** openXC7 silently ignores `DIFF_TERM`, so the receive pairs are
  unterminated. If that matters at this rate, it shows up here as a narrow or
  ragged eye — and per-lane, since `rise_d1` and `rise_d2` were the biased lanes
  (0.59 and 0.62 against 0.49 for their neighbours). A wide clean plateau would
  say the missing termination does not matter at 16 MHz, which is also a real
  answer and the more useful one.
  """
  def eye_sweep(opts \\ []) do
    samples = Keyword.get(opts, :samples, 512)
    restore = Keyword.get(opts, :restore, 0x00)

    IO.puts("rows = DATA_CLK_DELAY, cols = RX_DATA_DELAY, cell = % slots matching")
    IO.puts("     " <> Enum.map_join(0..15, " ", &String.pad_leading(to_string(&1), 3)))

    grid =
      Enum.map(0..15, fn clk_d ->
        row =
          Enum.map(0..15, fn data_d ->
            AD9363.write(@reg_rx_clock_data_delay, clk_d <<< 4 ||| data_d)
            Process.sleep(3)

            case capture(samples) do
              {:ok, w} ->
                {ok, tot} = match_rate(w)
                if tot > 0, do: round(100 * ok / tot), else: -1

              _ ->
                -1
            end
          end)

        IO.puts(
          String.pad_leading(to_string(clk_d), 3) <>
            "  " <> Enum.map_join(row, " ", &String.pad_leading(to_string(&1), 3))
        )

        row
      end)

    AD9363.write(@reg_rx_clock_data_delay, restore)

    best =
      for {row, c} <- Enum.with_index(grid), {v, d} <- Enum.with_index(row), do: {v, c, d}

    {bv, bc, bd} = Enum.max_by(best, fn {v, _, _} -> v end)
    hundreds = Enum.count(best, fn {v, _, _} -> v == 100 end)

    IO.puts("")
    IO.puts("best #{bv}% at DATA_CLK_DELAY=#{bc} RX_DATA_DELAY=#{bd}; #{hundreds}/256 cells at 100%")
    %{grid: grid, best: {bv, bc, bd}, cells_at_100: hundreds}
  end

  # --- helpers -----------------------------------------------------------------

  defp frac(_count, 0), do: 0.0
  defp frac(count, n), do: Float.round(count / n, 4)

  defp cover(sorted, n, target_frac) do
    target = target_frac * n

    sorted
    |> Enum.reduce_while({0, 0}, fn {_v, c}, {k, acc} ->
      if acc >= target, do: {:halt, {k, acc}}, else: {:cont, {k + 1, acc + c}}
    end)
    |> elem(0)
  end

  defp hex12(v), do: "0x" <> String.pad_leading(Integer.to_string(v, 16), 3, "0")
end
