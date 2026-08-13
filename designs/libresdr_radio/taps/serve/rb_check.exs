defmodule RbCheck do
  @moduledoc """
  Direct readback probe, independent of SiliconSweep's tile bookkeeping.

  Exists to answer ONE question the :selfcheck failure cannot answer on its
  own: when readback returns all zeros for a tile, is the READBACK dead, or is
  the tile genuinely unconfigured in the bitstream currently loaded?

  A tile-local check cannot tell those apart. Reading a frame range that is
  nonzero in EVERY configured design can.
  """
  import Bitwise
  alias SiliconSweep.{Devcfg, DmaBuf, Readback}

  @cmd_offset 0
  @rb_offset 4096
  @clk_offset 262_144

  def raw(far, n_frames) do
    words = Readback.words_for(n_frames)
    clocks = Readback.clock_words(words)
    seq = Readback.arm_sequence(far, n_frames)

    with :ok <- Devcfg.assert_queue_idle!(),
         :ok <- prime(),
         :ok <- DmaBuf.write_words(@cmd_offset, seq),
         :ok <- DmaBuf.write_words(@clk_offset, List.duplicate(0x2000_0000, clocks)),
         # Poison the landing zone. Without this, "all zeros" is ambiguous
         # between "the DMA wrote zeros" and "the DMA wrote nothing and the
         # buffer was already zero" -- and those have opposite diagnoses.
         :ok <- DmaBuf.fill(@rb_offset, words, 0xDEAD_BEEF),
         :ok <- Devcfg.clear_ints(),
         :ok <- Devcfg.dma(DmaBuf.base() + @cmd_offset * 4, 0xFFFF_FFFF, length(seq), 0),
         {:ok, _} <- Devcfg.await_transfer(4_000),
         :ok <- Devcfg.clear_ints(),
         :ok <- Devcfg.dma(0xFFFF_FFFF, DmaBuf.base() + @rb_offset * 4, 0, words),
         :ok <- Devcfg.dma(DmaBuf.base() + @clk_offset * 4, 0xFFFF_FFFF, clocks, 0),
         {:ok, _} <- Devcfg.await_transfer(15_000),
         {:ok, w} <- DmaBuf.read_chunked(@rb_offset, words) do
      _ = cleanup()
      {:ok, w}
    end
  end

  defp prime do
    with {:ok, c} <- Devcfg.read32(0x00), do: Devcfg.write32(0x00, c ||| 1 <<< 26 ||| 1 <<< 27)
  end

  defp cleanup do
    seq = Readback.readback_cleanup()

    with :ok <- DmaBuf.write_words(@cmd_offset, seq),
         :ok <- Devcfg.clear_ints(),
         :ok <- Devcfg.dma(DmaBuf.base() + @cmd_offset * 4, 0xFFFF_FFFF, length(seq), 0) do
      Devcfg.await_transfer(2_000)
    end
  end

  @doc "Summary rather than 3000 words: enough to judge live-vs-dead at a glance."
  def stat(far, n) do
    case raw(far, n) do
      {:ok, w} ->
        %{
          far: "0x" <> Integer.to_string(far, 16),
          words: length(w),
          nonzero: Enum.count(w, &(&1 != 0)),
          untouched: Enum.count(w, &(&1 == 0xDEAD_BEEF)),
          distinct: w |> Enum.uniq() |> length(),
          first12: Enum.take(w, 12)
        }

      other ->
        %{far: "0x" <> Integer.to_string(far, 16), error: inspect(other)}
    end
  end

  @doc """
  Read ONE configuration register through the readback path.

  This is the gate the tile-local :selfcheck cannot be: IDCODE has a known,
  design-independent answer (0x03727093 on xc7z020). If IDCODE comes back
  right, the readback path is alive and any zeros in FDRO are the fabric's
  actual content. If IDCODE also reads zero, the path is dead and no frame
  result means anything.

  Uses the same clocked three-step shape as `raw/2` -- the engine only emits
  while the PCAP interface is clocked, register reads included.
  """
  @reg_idcode 0x0C
  @reg_stat 0x07
  @op_read 1

  def reg(addr, collect \\ 1) do
    seq =
      Readback.preamble() ++
        [
          0x2000_0000,
          (1 <<< 29) ||| (@op_read <<< 27) ||| ((addr &&& 0x3FFF) <<< 13) ||| 1,
          0x2000_0000,
          0x2000_0000
        ]

    clocks = 512

    with :ok <- Devcfg.assert_queue_idle!(),
         :ok <- prime(),
         :ok <- DmaBuf.write_words(@cmd_offset, seq),
         :ok <- DmaBuf.write_words(@clk_offset, List.duplicate(0x2000_0000, clocks)),
         :ok <- DmaBuf.fill(@rb_offset, 16, 0xDEAD_BEEF),
         :ok <- Devcfg.clear_ints(),
         :ok <- Devcfg.dma(DmaBuf.base() + @cmd_offset * 4, 0xFFFF_FFFF, length(seq), 0),
         {:ok, _} <- Devcfg.await_transfer(4_000),
         :ok <- Devcfg.clear_ints(),
         :ok <- Devcfg.dma(0xFFFF_FFFF, DmaBuf.base() + @rb_offset * 4, 0, collect),
         :ok <- Devcfg.dma(DmaBuf.base() + @clk_offset * 4, 0xFFFF_FFFF, clocks, 0),
         {:ok, _} <- Devcfg.await_transfer(10_000),
         {:ok, w} <- DmaBuf.read_chunked(@rb_offset, max(collect, 4)) do
      _ = cleanup()
      {:ok, Enum.map(w, &("0x" <> Integer.to_string(&1, 16)))}
    end
  end

  @doc "IDCODE gate. Expect 0x3727093."
  def idcode, do: reg(@reg_idcode)

  @doc "Configuration STATUS register."
  def stat_reg, do: reg(@reg_stat)

  # --- alignment --------------------------------------------------------------
  #
  # The readback stream does NOT begin at a fixed offset.
  #
  # `Readback.to_frames/1` drops exactly one 101-word pad frame, on the strength
  # of XAPP1230's "32530 frames + 1 frame + 10 words". That held for one read
  # earlier in this project (202/202 words, frame 0x900 head 20A80 0 20800 ...)
  # and does NOT hold now: a 10-frame read at FAR 0x900 came back with every
  # word displaced by a further 14, confirmed three independent ways --
  #
  #     base[0]  = 0x00020800   silicon[14] = 0x00020A80   (the known 1-bit diff)
  #     base[10] = 0x06020800   silicon[24] = 0x06020800
  #     base[85] = 0x06020000   silicon[99] = 0x06020000
  #
  # and decisively by the ECC word, which belongs at word 50 of a frame and was
  # found at 64 holding 0x1A6D -- a 13-bit value where its neighbours are
  # 0x06020800-class routing words.
  #
  # Assuming the offset is fatal: every conclusion downstream is drawn from
  # words attributed to the wrong bit positions, and the error is invisible
  # because shifted routing data still looks like routing data. So MEASURE it.
  #
  # ## The detector
  #
  # Frame ECC is the one field whose VALUE RANGE is known a priori and is
  # design-independent: 13 bits, so always < 0x2000, and it recurs every 101
  # words. Ordinary configuration words in these frames are routinely far
  # larger. Sliding a 101-word comb over the stream and scoring how many teeth
  # land on a small value therefore locates the frame phase without knowing
  # anything about the design under test -- which is exactly the property
  # `base.frames` comparison lacks, since base.frames is from another build.
  #
  # Reported with a MARGIN. A detector that returns its best guess and not how
  # much better it was than the runner-up is how this project has been fooled
  # before; if the margin is thin the answer is "unaligned", not a number.

  @ecc_word 50
  @ecc_max 0x2000
  @frame 101
  @min_teeth 4

  def align(words) do
    n = length(words)
    arr = List.to_tuple(words)
    # At least @min_teeth teeth, or the rate is meaningless: a comb with ONE
    # tooth scores 1.0 whenever it happens to land on any small nonzero word,
    # and there are plenty of those near the end of the stream. That is what
    # kept `runner_up_rate` pinned at 1.0 after the phase fix -- the runner-up
    # was a one-tooth accident, not a rival alignment.
    max_off = n - @frame * @min_teeth

    scores =
      for off <- 0..max(max_off, 0) do
        teeth = div(n - off - @ecc_word - 1, @frame)

        hits =
          if teeth < @min_teeth do
            0
          else
            # NONZERO and 13-bit. The `< 0x2000` half alone is degenerate:
            # these frames are mostly zeros, and zero passes it, so nearly
            # every offset scored 1.0 and the detector reported a tie it had
            # no business reporting. Requiring nonzero is what makes the comb
            # discriminate -- a wrong phase lands on a zero or on a
            # 0x06020800-class routing word, and both now fail.
            Enum.count(0..(teeth - 1), fn k ->
              v = elem(arr, off + @ecc_word + k * @frame)
              v > 0 and v < @ecc_max
            end)
          end

        # Frames with NO content are not evidence either way. An all-zero frame
        # has an all-zero ECC legitimately, so counting it as a miss penalises
        # correct alignments over sparse regions -- measured: the same read at
        # FAR 0x900 scored 1.0 at 10 frames and 0.759 at 30, identical offset
        # 115 both times, purely because frames 15..30 of that region are
        # empty. Scoring against POPULATED teeth only is what makes the
        # detector usable on a mostly-unused tile, which is precisely the case
        # `:census` runs on.
        populated =
          if teeth < @min_teeth do
            0
          else
            Enum.count(0..(teeth - 1), fn k ->
              base = off + k * @frame
              Enum.any?(0..(@frame - 1), fn j ->
                idx = base + j
                idx < n and elem(arr, idx) != 0
              end)
            end)
          end

        # Same trap as @min_teeth, one level down: after excluding empty
        # frames a candidate can be left with one or two POPULATED teeth and
        # score a meaningless 1.0. That is why n=20 and n=30 reported a
        # runner-up of 1.0 and refused to call themselves confident while
        # returning the right answer. A candidate needs enough populated
        # evidence to be scored at all.
        if populated < @min_teeth do
          {0, 1, off}
        else
          {hits, populated, off}
        end
      end

    # Ties broken toward the SMALLEST offset so the report is reproducible;
    # an unstable argmax makes two identical reads disagree.
    sorted = Enum.sort_by(scores, fn {h, t, o} -> {-(h / max(t, 1)), o} end)
    [{h1, t1, o1} | rest] = sorted
    # A "competitor" must be a DIFFERENT FRAME PHASE. Offsets 115, 216, 317 ...
    # all satisfy `rem(o, 101) == 14`: they are the same alignment starting one
    # frame later, so they necessarily score the same and comparing against
    # them makes a perfect detection look like a dead tie. That is what the
    # first version of this reported -- offset 115 at hit_rate 1.0, runner-up
    # 1.0, confident: false -- and the answer was right the whole time.
    #
    # Note this also explains why the winner is 115 and not 14, which shares
    # the phase: the pipeline PAD FRAME is all zeros, so its ECC tooth is zero
    # and fails the nonzero test. The pad frame excludes itself.
    phase = rem(o1, @frame)
    competitors = Enum.reject(rest, fn {_, _, o} -> rem(o, @frame) == phase end)
    {h2, t2, _o2} = List.first(competitors) || {0, 1, nil}

    # Report the PHASE, then derive the data offset from it.
    #
    # The comb locates the frame grid, not the first frame of DATA. Scoring
    # populated teeth only -- necessary, see above -- makes the all-zero pad
    # frame invisible, so the best-scoring offset drifts to the smallest one
    # sharing the correct phase (14) rather than the first real frame (115).
    # Both describe the same grid; only one indexes frames correctly.
    #
    # So: take the phase from the detector, which is what it actually measures
    # and measures robustly, and add the ONE pipeline pad frame XAPP1230
    # documents. That yields 14 + 101 = 115, which is the offset verified
    # against base.frames at FAR 0x900 -- 3 differing words out of 101, being
    # the two known routing diffs and the device-computed ECC.
    #
    # The 14 is the finding. It is not in UG470, not in UG585, and not in
    # Xilinx's xdevcfg readback example, all of which imply data begins
    # immediately after the pad frame.
    lead = rem(o1, @frame)

    %{
      lead: lead,
      offset: lead + @frame,
      best_scoring_offset: o1,
      frames: t1,
      hit_rate: Float.round(h1 / max(t1, 1), 3),
      runner_up_rate: Float.round(h2 / max(t2, 1), 3),
      confident: h1 / max(t1, 1) >= 0.9 and h1 / max(t1, 1) - h2 / max(t2, 1) >= 0.2,
      top5:
        scores
        |> Enum.sort_by(fn {h, t, o} -> {-(h / max(t, 1)), o} end)
        |> Enum.take(5)
        |> Enum.map(fn {h, t, o} -> {o, h, t} end)
    }
  end

  @doc """
  Read `n` frames at `far` and split them using the MEASURED offset.

  Returns `{:error, {:unaligned, report}}` rather than guessing. A silently
  misaligned frame list is worse than no frame list.
  """
  def frames(far, n) do
    with {:ok, w} <- raw(far, n) do
      a = align(w)

      if a.confident do
        fr =
          w
          |> Enum.drop(a.offset)
          |> Enum.chunk_every(@frame)
          |> Enum.reject(&(length(&1) < @frame))

        {:ok, fr, a}
      else
        {:error, {:unaligned, a}}
      end
    end
  end
end
