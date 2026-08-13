defmodule RbProbe do
  @moduledoc """
  PCAP configuration-FRAME readback.

  ## The mechanism, which is not documented anywhere

  The configuration engine only emits readback data **while the PCAP interface
  is being clocked**. The command transfer supplies clocks for exactly as long
  as it is being sent; when it ends, the engine stops mid-stream. A receive DMA
  armed for more words than those clocks produced then waits for ever.

  That is what every "wedge" in this project actually was. Not a wrong packet
  encoding, not a rate bit, not a queueing order -- starvation.

  Xilinx's driver never trips over this because its only readback example reads
  a single register word, and the command packet alone supplies far more clocks
  than that needs.

  ## Measured clock budget

  56 command words produced 101 output words. A further 256 NOOP words produced
  88 more. So roughly **0.6 output words per transmitted word**. `@clock_ratio`
  below is set to 3 transmitted words per wanted word, which is ample margin --
  and margin is the whole game, because the DMA command queue is only two deep,
  so the transmit that supplies the clocks gets exactly one attempt.

  ## The working shape

      1. TX  command sequence, wait D_P_DONE
      2. RX  N words                     <- armed, will stall part-way
      3. TX  N * @clock_ratio NOOPs      <- supplies the clocks that drain it

  Steps 2 and 3 occupy both queue slots at once. Step 3 must be queued *behind*
  the already-armed receive: the receive has to be waiting before the clocks
  arrive, or the data it should have caught is emitted into nothing.

  ## Ruled out earlier, recorded so they are not re-tried

  * `QUARTER_PCAP_RATE_EN` (CTRL[25]) -- `XDcfg_Transfer` sets it only for
    AES-encrypted writes and explicitly clears it for non-secure ones. The
    readback path never touches it.
  * Arming the receive concurrently with the command send -- `XDcfg_PcapReadback`
    is serial, and serial is correct.
  * Internal PCAP loopback (`MCTRL[4]`) -- read off the board as already clear.
  * Type-1 inline count versus canonical type-1 count 0 plus type-2 -- tested
    directly, made no difference. The engine emitted exactly one frame either
    way, because either way the clocks ran out at the same point.
  """

  import Bitwise

  alias SiliconSweep.{Devcfg, DmaBuf, Readback}

  @words_per_frame 101

  # Transmitted words per wanted output word. Measured at ~1.7; 3 for margin.
  # Overshooting costs nothing -- surplus NOOPs are consumed harmlessly -- while
  # undershooting costs a power cycle. The asymmetry is the whole reason for
  # the number.
  @clock_ratio 3
  @clock_floor 512

  @ctrl 0x00
  @mctrl 0x80

  @ctrl_pcap_mode 1 <<< 26
  @ctrl_pcap_pr 1 <<< 27
  @mctrl_pcap_lpbk 1 <<< 4

  @cmd_off 0
  @data_off 8192
  # The NOOP clock stream goes 1 MW in, FAR past any readback payload.
  #
  # It was at word 2048 with data at 8192, which is only 6144 words of room. A
  # 31-frame read needs 9393 clock words, so the NOOP stream ran into the data
  # buffer and was overwritten by the very data it was clocking in. The engine
  # stopped being clocked, the receive stalled, and both queue slots filled --
  # a power cycle, caused by two constants sitting too close together.
  #
  # An 11-frame read needed 3333 and fit, which is why this survived until the
  # first genuinely large scan.
  @noop_off 262_144

  @noop 0x2000_0000

  @doc "Type-2 packet: `010 <op:2> <count:27>`. Continues the type-1 before it."
  def type2(op, count), do: 2 <<< 29 ||| (op &&& 3) <<< 27 ||| (count &&& 0x07FF_FFFF)

  @doc "UG470 readback command sequence."
  def seq(far, words) do
    Readback.preamble() ++
      [
        @noop,
        Readback.type1(2, 0x04, 1),
        0x0000_0007,
        @noop,
        @noop,
        Readback.type1(2, 0x01, 1),
        far,
        Readback.type1(2, 0x04, 1),
        0x0000_0004,
        @noop,
        Readback.type1(1, 0x03, 0),
        type2(1, words)
      ]
  end

  @doc """
  Read `chunks` frames starting at `far`. Chunk 0 is the pad frame UG470
  requires be discarded; the rest are real.

  Returns the frames as lists of words, plus enough state to tell a short read
  from a complete one. `complete?` is the only field worth trusting as a
  go/no-go: a receive that timed out still has whatever partial data arrived
  before the clocks ran out, and that data is real, but the frame containing
  the cut-off point is not.
  """
  def run(far, chunks) when chunks >= 2 do
    words = chunks * @words_per_frame
    clocks = max(words * @clock_ratio, @clock_floor)

    # Refuse rather than silently corrupt. Overlapping regions do not fail
    # loudly at the point of the mistake -- they fail as a stalled transfer
    # minutes later, which reads as a hardware problem.
    if @data_off + words > @noop_off or @noop_off + clocks > 1_048_576 do
      raise "buffer layout overflow: data #{@data_off}+#{words}, " <>
              "noop #{@noop_off}+#{clocks}, buffer is 1048576 words"
    end

    Devcfg.with_devcfg(fn ->
      DmaBuf.fill(@data_off, words, 0xDEAD_BEEF)
      DmaBuf.write_words(@noop_off, List.duplicate(@noop, clocks))
      Devcfg.unlock()

      {:ok, ctrl0} = Devcfg.read32(@ctrl)
      Devcfg.write32(@ctrl, ctrl0 ||| @ctrl_pcap_mode ||| @ctrl_pcap_pr)

      {:ok, mctrl0} = Devcfg.read32(@mctrl)
      Devcfg.write32(@mctrl, mctrl0 &&& bnot(@mctrl_pcap_lpbk))

      # 1. command
      s = seq(far, words)
      DmaBuf.write_words(@cmd_off, s)
      Devcfg.clear_ints()
      Devcfg.dma(DmaBuf.base(), 0xFFFF_FFFF, length(s), 0)
      cmd = Devcfg.await_transfer(4_000)

      # 2. arm the receive. It will stall, by design, until step 3 feeds it.
      Devcfg.clear_ints()
      Devcfg.dma(0xFFFF_FFFF, DmaBuf.base() + @data_off * 4, 0, words)

      # 3. clocks. Queued BEHIND the armed receive, in the second queue slot.
      Devcfg.dma(DmaBuf.base() + @noop_off * 4, 0xFFFF_FFFF, clocks, 0)

      data = Devcfg.await_transfer(15_000)

      cleanup_if_safe()

      {:ok, w} = DmaBuf.read_chunked(@data_off, words)
      missing = Enum.count(w, &(&1 == 0xDEAD_BEEF))

      %{
        cmd: cmd,
        data: data,
        asked_words: words,
        clocks_sent: clocks,
        words_landed: words - missing,
        complete?: missing == 0,
        mctrl_before: "0x" <> Integer.to_string(mctrl0, 16),
        idle_after: Devcfg.queue_idle?(),
        frames: frames(w)
      }
    end)
  end

  defp frames(w) do
    w
    |> Enum.chunk_every(@words_per_frame)
    |> Enum.with_index()
    |> Map.new(fn {frame, i} ->
      {if(i == 0, do: "pad", else: "frame+#{i - 1}"), frame}
    end)
  end

  # Never queue behind a stalled transfer: that fills the second slot and turns
  # a starved read -- which more NOOPs can still rescue -- into a hard wedge.
  defp cleanup_if_safe do
    if Devcfg.queue_idle?() do
      cl = Readback.readback_cleanup()
      DmaBuf.write_words(@cmd_off, cl)
      Devcfg.clear_ints()
      Devcfg.dma(DmaBuf.base(), 0xFFFF_FFFF, length(cl), 0)
      Devcfg.await_transfer(2_000)
    else
      :skipped
    end
  end

  @doc """
  Compare a frame read off the silicon against the same frame in `base.frames`.

  The oracle discipline: an instrument is not trusted until it reproduces a
  known answer. `base.frames` is what the flow *intended* to load, so a match
  means the readback path is sound and any later mismatch is silicon telling us
  something. Returns the differing word indices, which is what a mismatch needs
  to be actionable.
  """
  def check(frame_words, far, path \\ "/tmp/base.frames") do
    key = "0x" <> String.pad_leading(Integer.to_string(far, 16), 8, "0")

    expected =
      path
      |> File.stream!()
      |> Enum.find(&String.starts_with?(&1, key))

    case expected do
      nil ->
        {:error, {:no_such_frame_in_base, key}}

      line ->
        # `base.frames` lines are `0xADDR<space>0xWORD,0xWORD,...` -- the words
        # are comma-separated, so splitting on whitespace alone yields the whole
        # list as a single element and every comparison silently fails.
        [_addr, body] = line |> String.trim() |> String.split(" ", parts: 2)

        want =
          body
          |> String.split(",")
          |> Enum.map(fn s ->
            s |> String.trim() |> String.replace_prefix("0x", "") |> String.to_integer(16)
          end)

        if length(want) != @words_per_frame do
          raise "base.frames #{key} has #{length(want)} words, expected #{@words_per_frame} -- " <>
                  "the parse is wrong and any comparison against it would be meaningless"
        end

        diffs =
          Enum.zip(want, frame_words)
          |> Enum.with_index()
          |> Enum.reject(fn {{a, b}, _} -> a == b end)
          |> Enum.map(fn {{a, b}, i} -> %{word: i, base: hex(a), silicon: hex(b)} end)

        %{far: key, words: length(want), diffs: length(diffs), detail: Enum.take(diffs, 12)}
    end
  end

  defp hex(v), do: "0x" <> String.pad_leading(Integer.to_string(v, 16), 8, "0")
end
