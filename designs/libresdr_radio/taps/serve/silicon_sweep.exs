#!/usr/bin/env elixir
#
# silicon_sweep.exs -- the brute-force silicon characterisation harness, on the board.
#
#     iex> c "scripts/silicon_sweep.exs"
#     iex> SiliconSweep.probe()          # what can this board actually do right now
#     iex> SiliconSweep.run(:selfcheck)  # MUST pass before anything else is believed
#     iex> SiliconSweep.run(:census)
#     iex> SiliconSweep.run(:functional, limit: 50)
#
# ## What this is
#
# prjxray documents bits by DIFFERENTIAL BITSTREAM ANALYSIS: build two designs
# in Vivado, diff the bitstreams, name the delta. Its structural blind spot is
# any bit Vivado writes identically in every design -- those never vary, so they
# never appear, and no amount of fuzzing with the vendor tool will find them.
#
# We cannot run Vivado at all. What we have instead is a board, and that permits
# two things prjxray's fuzzers structurally cannot do:
#
#   1. DIFFERENTIAL HARDWARE BEHAVIOUR -- poke a bit, load, measure, record.
#      Answers "does this bit do something", not "what would Vivado write".
#   2. CONFIGURATION READBACK -- ask the silicon what is actually in its
#      configuration memory, rather than inferring it from a file we wrote.
#
# (2) is the one this project has never used, and it is the more powerful of the
# two by a wide margin. See STRATEGIES below.
#
# ## STRATEGIES, and where each came from
#
#   :selfcheck   Write a bitstream, read it back, compare against the .frames we
#                built it from, masked with prjxray's mask_*.db. Known answer,
#                available immediately, no new hardware.
#
#                Six instruments in this project have produced confident wrong
#                answers and every one was caught by a known-answer control,
#                none by reading the code. Nothing below is believed until this
#                passes.
#
#   :pokecheck   Re-validate frames_poke's bit arithmetic against SILICON rather
#                than against fasm2frames. Today it is validated against another
#                tool's opinion of where a bit goes; readback replaces that with
#                the chip's.
#
#   :census      Write 1 to every candidate bit in a tile, read back, keep the
#                ones that stuck. Bits that read back 0 are not physical
#                configuration cells.
#
#                This is the big one. It prunes the entire dark space in ONE
#                write+read instead of N functional tests, and unlike a
#                functional oracle it is MONOTONE -- setting more bits cannot
#                hide a result. It answers "which of these bit positions
#                exist", not "what do they do", and that is exactly the right
#                first question.
#
#   :functional  One bit at a time: poke, load, run the oracle, record, restore.
#                O(n). For the CMT's 2,614 undocumented positions that is an
#                overnight run, and it is the ONLY sound way to get semantics.
#
#   :grouptest   DELIBERATELY NOT IMPLEMENTED. See the module below for why --
#                it is not a matter of effort, the method is invalid here and
#                the refutation is recorded so nobody spends a week rediscovering
#                it.
#
# ## Status
#
# Written from the register documentation, NOT yet run against silicon. Every
# strategy is gated on `probe/0`, and any prerequisite that is missing is
# reported by name rather than silently skipped. A harness that reports success
# after doing nothing is the worst failure mode available to it; that already
# happened once in this project, to fasm_audit.exs, which cheerfully printed
# "0 tile types ... clean" when its tilegrid parser had silently matched nothing.

defmodule SiliconSweep.Devcfg do
  @moduledoc """
  The Zynq-7000 Device Configuration Interface at `0xF800_7000` (UG585 ch. 6).

  Mapped exactly the way `Nervezynq.SLCR` maps the SLCR block: a second
  `fabric_port` instance with a different base in argv. No Rust changes -- the
  port already takes `<base> <len>`, and `mmap` is not subject to the
  `valid_phys_addr_range()` check that makes `:file.pread` on /dev/mem fail with
  `:efault` for non-RAM physical addresses.

  ## Why the PS and not the ICAP

  ICAPE2 would need a fabric design carrying the ICAP primitive, which means the
  thing being characterised is also the thing doing the characterising -- and a
  poked bit that breaks the fabric would take the instrument with it. Driving
  devcfg from the PS keeps the instrument outside the device under test. The PL
  can be wrecked and re-loaded without losing the ability to observe it.
  """

  use GenServer
  import Bitwise
  require Logger

  @base 0xF800_7000
  @len 0x1000

  # UG585 Table 6-1. Offsets from @base.
  @ctrl 0x00
  @lock 0x04
  @cfg 0x08
  @int_sts 0x0C
  @int_mask 0x10
  @status 0x14
  @dma_src_addr 0x18
  @dma_dst_addr 0x1C
  @dma_src_len 0x20
  @dma_dst_len 0x24
  @multiboot 0x2C
  @unlock 0x34
  @mctrl 0x80

  # CTRL bits
  @ctrl_force_rst 1 <<< 31
  @ctrl_pcap_pr 1 <<< 27
  @ctrl_pcap_mode 1 <<< 26
  @ctrl_quartermode 1 <<< 25

  # INT_STS bits that matter for a transfer
  @int_dma_done 1 <<< 13
  @int_d_p_done 1 <<< 12
  @int_pcfg_done 1 <<< 2

  @unlock_magic 0x757B_DF0D

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def read32(off), do: GenServer.call(__MODULE__, {:read32, off}, 5_000)
  def write32(off, v), do: GenServer.call(__MODULE__, {:write32, off, v}, 5_000)

  @doc "Register names for dumps, so a raw offset never appears in a log."
  def regs,
    do: %{
      ctrl: @ctrl,
      lock: @lock,
      cfg: @cfg,
      int_sts: @int_sts,
      int_mask: @int_mask,
      status: @status,
      dma_src_addr: @dma_src_addr,
      dma_dst_addr: @dma_dst_addr,
      dma_src_len: @dma_src_len,
      dma_dst_len: @dma_dst_len,
      multiboot: @multiboot,
      unlock: @unlock,
      mctrl: @mctrl
    }

  def dump do
    Map.new(regs(), fn {name, off} ->
      {name, case read32(off) do
        {:ok, v} -> "0x" <> String.pad_leading(Integer.to_string(v, 16), 8, "0")
        e -> inspect(e)
      end}
    end)
  end

  @doc """
  Is devcfg reachable and unlocked?

  `LOCK` is write-once-per-POR: once a bit is set there the corresponding CTRL
  field is frozen until the next power cycle. The FSBL sets some of these. If a
  lock bit we need is already set, readback is impossible for this power cycle
  and the honest answer is to say so rather than to fail obscurely later.
  """
  def status do
    with {:ok, ctrl} <- read32(@ctrl),
         {:ok, lock} <- read32(@lock),
         {:ok, sts} <- read32(@status) do
      {:ok,
       %{
         ctrl: ctrl,
         lock: lock,
         status: sts,
         pcap_mode: (ctrl &&& @ctrl_pcap_mode) != 0,
         pcap_pr: (ctrl &&& @ctrl_pcap_pr) != 0,
         # STATUS[14] PCFG_INIT -- PL is powered and initialised
         pl_init: (sts &&& 1 <<< 4) != 0,
         locked_fields: lock
       }}
    end
  end

  def unlock, do: write32(@unlock, @unlock_magic)

  # STATUS bits, from native/fabric/src/devcfg.rs which already had to learn
  # this the hard way for the load path.
  @status_dma_q_f 1 <<< 31
  @status_dma_q_e 1 <<< 30

  @doc """
  Is the DMA command queue idle?

  This is THE health check, and everything must be gated on it.

  A readback whose data phase asks for more words than the configuration engine
  emits leaves its DMA command queued for ever. The queue fills, and from then
  on every transfer -- including a one-word register read that worked seconds
  earlier -- fails. Worse, the failures look like ordinary timeouts, so the
  results afterwards are garbage that reads as data.

  Nothing clears it short of a power cycle. A PL reset via PCFG_PROG_B does not:
  the queue lives in the PS-side controller, not the fabric. `Nervezynq.PL.reload/1`
  refuses outright with "DMA command queue not idle".

  So: check before, check after, and never interpret a result taken while this
  is false.
  """
  def queue_idle? do
    case read32(@status) do
      {:ok, s} -> (s &&& @status_dma_q_f) == 0 and (s &&& @status_dma_q_e) != 0
      _ -> false
    end
  end

  @doc "Raise rather than return a plausible-looking wrong answer."
  def assert_queue_idle! do
    unless queue_idle?() do
      {:ok, s} = read32(@status)
      raise "devcfg DMA queue not idle (STATUS 0x#{Integer.to_string(s, 16)}) -- " <>
              "a previous readback stalled. This needs a POWER CYCLE; a reboot will " <>
              "not clear it and will not boot."
    end

    :ok
  end

  @doc """
  Point the PCAP datapath at the PS (readback direction).

  UG585: PCAP_MODE selects PCAP (rather than ICAP) as the configuration
  interface; PCAP_PR selects partial reconfiguration mode. The DMA direction
  itself is expressed by which of DMA_SRC/DMA_DST is the PL, encoded by the
  0xFFFF_FFFF sentinel address.
  """
  def set_readback_direction do
    with {:ok, ctrl} <- read32(@ctrl) do
      write32(@ctrl, ctrl ||| @ctrl_pcap_mode ||| @ctrl_pcap_pr)
    end
  end

  @doc "Clear the transfer-complete interrupt flags before starting a transfer."
  def clear_ints, do: write32(@int_sts, 0xFFFF_FFFF)

  @doc """
  Program one DMA transfer.

  Addresses are PHYSICAL. `0xFFFF_FFFF` is `XDCFG_DMA_INVALID_ADDRESS`, the
  sentinel disabling one direction. Lengths are in 32-bit WORDS, and the low two
  bits of an address are flags, so buffers must be word aligned.

  ## The length of the UNUSED direction must be ZERO

  From `XDcfg_Transfer`'s readback path in Xilinx's `xdevcfg.c`, which calls
  `XDcfg_InitiateDma` TWICE:

      phase 1  dma(cmd_buffer, INVALID,     src_len, 0)         send commands
      phase 2  dma(INVALID,    data_buffer, 0,       dst_len)   receive data

  This project set BOTH lengths equal in each phase. Phase 1 therefore told
  devcfg to expect `src_len` words back FROM the PL while it was sending
  commands. Nothing ever comes back, so the transfer never completes -- and a
  never-completing transfer is exactly the wedge that costs a power cycle,
  blocks the FSBL, and prevents the board from booting.

  So the wedges were self-inflicted by this one field, and every "the engine
  stalled" conclusion drawn from them was measuring that bug rather than the
  silicon.
  """
  def dma(src, dst, src_words, dst_words) do
    with :ok <- write32(@dma_src_addr, src),
         :ok <- write32(@dma_dst_addr, dst),
         :ok <- write32(@dma_src_len, src_words),
         :ok <- write32(@dma_dst_len, dst_words) do
      :ok
    end
  end

  @doc "Poll INT_STS for DMA and PCAP completion, with a deadline."
  def await_transfer(timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    want = @int_dma_done ||| @int_d_p_done

    poll = fn poll ->
      case read32(@int_sts) do
        {:ok, sts} when (sts &&& want) == want ->
          {:ok, sts}

        {:ok, sts} ->
          if System.monotonic_time(:millisecond) > deadline,
            do: {:error, {:timeout, sts}},
            else: (Process.sleep(1); poll.(poll))

        e ->
          e
      end
    end

    poll.(poll)
  end

  # --- driver arbitration ----------------------------------------------------

  @driver "/sys/bus/platform/drivers/zynq_fpga_manager"
  @device "f8007000.devcfg"

  @doc """
  Take devcfg away from the kernel driver for the duration of a readback.

  `/proc/iomem` shows `f8007000-f80070ff : f8007000.devcfg` -- the
  `zynq_fpga_manager` driver has claimed this register block and uses it every
  time `Nervezynq.PL.reload/1` loads a bitstream. Driving the same registers
  from userspace underneath it is a race with a live DMA engine, and the
  failure mode is a wedged PL or a corrupted load rather than an error message.

  So unbind it first and rebind after. Reversible, standard sysfs, and it means
  the readback path and the loader can never both think they own the engine.

  Returns `{:error, :unbind_failed}` rather than proceeding unbound-but-racy --
  running anyway would produce results that look fine and are not.
  """
  def with_devcfg(fun) when is_function(fun, 0) do
    assert_queue_idle!()

    case unbind_driver() do
      :ok ->
        try do
          fun.()
        after
          bind_driver()
        end

      e ->
        e
    end
  end

  def unbind_driver do
    case File.write(Path.join(@driver, "unbind"), @device) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      _ -> {:error, :unbind_failed}
    end
  end

  def bind_driver do
    _ = File.write(Path.join(@driver, "bind"), @device)
    :ok
  end

  # --- GenServer: an mmap port, exactly as SLCR does it ---------------------

  @impl true
  def init(_opts) do
    case Nervezynq.PortWire.open(@base, @len) do
      {:ok, port} -> {:ok, %{port: port}}
      {:error, e} -> {:stop, e}
    end
  end

  @impl true
  def handle_call(request, _from, state) do
    {:reply, Nervezynq.PortWire.transact(state.port, request), state}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state),
    do: {:stop, {:port_exited, status}, state}

  def handle_info(_msg, state), do: {:noreply, state}
end

defmodule SiliconSweep.DmaBuf do
  @moduledoc """
  The reserved physical buffer devcfg DMAs into, mapped from Elixir.

  Declared in `nerves_system_libresdr/dts/xilinx/zynq-libresdr.dts` as a
  `reserved-memory` node with `no-map`, so the kernel never touches it and its
  physical address is fixed and known at compile time. 4 MB at the top of the
  1 GB -- enough for the whole xc7z020 configuration memory in one transfer, not
  just one tile.

  Mapped with a third `fabric_port` instance. The port already takes
  `<base> <len>` in argv, so this needs no Rust: it is the same trick
  `Nervezynq.SLCR` uses for the SLCR block.

  ## The one invariant

  `@base` here and the `reg` property in the DTS must agree. If they drift, the
  DMA writes 4 MB of frame data wherever this points instead, which on a
  `no-map` mismatch is live kernel memory. `verify/0` reads back a signature it
  wrote and is called by `probe/0` before any transfer is programmed -- that is
  cheap insurance against a mismatch that would otherwise present as random
  kernel corruption.
  """

  use GenServer
  import Bitwise

  @base 0x3FC0_0000
  @len 0x0040_0000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def base, do: @base
  def size_words, do: div(@len, 4)

  def read_words(offset_words, count),
    do: GenServer.call(__MODULE__, {:read_block, offset_words * 4, count}, 30_000)

  def write_words(offset_words, words),
    do: GenServer.call(__MODULE__, {:write_block, offset_words * 4, words}, 30_000)

  @doc """
  Write a signature, read it back, and confirm the mapping is live.

  Deliberately checks a word at BOTH ends of the region. A short mapping -- from
  a DTS `reg` size smaller than @len -- reads fine at offset 0 and faults or
  aliases at the top, which is exactly the failure that would otherwise be
  discovered as a truncated readback that looks like missing frames.
  """
  def verify do
    top = size_words() - 1
    sig_a = 0xA5A5_1234
    sig_b = 0x5A5A_4321

    with :ok <- write_words(0, [sig_a]),
         :ok <- write_words(top, [sig_b]),
         {:ok, [a]} <- read_words(0, 1),
         {:ok, [b]} <- read_words(top, 1) do
      cond do
        a != sig_a -> {:error, {:low_word_mismatch, a}}
        b != sig_b -> {:error, {:high_word_mismatch, b}}
        true -> {:ok, %{base: @base, bytes: @len, words: size_words()}}
      end
    end
  end

  @doc "Fill `count` words from `offset_words` with `value`, chunked to the framing limit."
  def fill(offset_words, count, value) do
    max = Nervezynq.PortWire.max_block_words()

    Enum.reduce_while(0..div(count - 1, max), :ok, fn i, _ ->
      n = min(max, count - i * max)

      case write_words(offset_words + i * max, List.duplicate(value, n)) do
        :ok -> {:cont, :ok}
        e -> {:halt, e}
      end
    end)
  end

  @doc "Read `count` words, chunked, and concatenate."
  def read_chunked(offset_words, count) do
    max = Nervezynq.PortWire.max_block_words()

    Enum.reduce_while(0..div(count - 1, max), {:ok, []}, fn i, {:ok, acc} ->
      n = min(max, count - i * max)

      case read_words(offset_words + i * max, n) do
        {:ok, w} -> {:cont, {:ok, acc ++ w}}
        e -> {:halt, e}
      end
    end)
  end

  @impl true
  def init(_opts) do
    case Nervezynq.PortWire.open(@base, @len) do
      {:ok, port} -> {:ok, %{port: port}}
      {:error, e} -> {:stop, e}
    end
  end

  @impl true
  def handle_call(req, _from, state),
    do: {:reply, Nervezynq.PortWire.transact(state.port, req, 30_000), state}

  @impl true
  def handle_info({port, {:exit_status, st}}, %{port: port} = state),
    do: {:stop, {:port_exited, st}, state}

  def handle_info(_m, state), do: {:noreply, state}

  # Kept so a caller can express "the PL side" without knowing the sentinel.
  def pl_sentinel, do: 0xFFFF_FFFF

  @doc "devcfg address encoding: low 2 bits are flags, so buffers must be word aligned."
  def dma_addr(phys) when (phys &&& 3) == 0, do: phys
end

defmodule SiliconSweep.Readback do
  @moduledoc """
  PL configuration readback over PCAP (UG470 ch. 6).

  ## The command sequence

  Readback is not a register read. You DMA a short command stream INTO the
  configuration engine that arms it, then DMA the frame data back OUT:

      SYNC 0xAA995566
      NOOP
      Type-1 write RDBK_TYPE -- select readback of configuration
      Type-1 write to CMD register, value RCFG
      Type-1 write to FAR, value <frame address>
      NOOP
      Type-1 read from FDRO, word count = (frames * 101) + 1
      ... then read that many words back ...

  ## Two things that bite

  1. **The pad frame.** The configuration engine pipelines: the first frame's
     worth of words out of FDRO is garbage from the pipeline, and the real data
     starts one frame later. Read `(n+1) * 101` words and discard the first 101.
     Getting this wrong shifts every result by one frame, which looks like a
     plausible-but-wrong answer rather than an obvious failure -- which is
     precisely the class of bug that has burned this project six times.

  2. **Readback is not what you wrote.** A configured, RUNNING design has state
     in the same configuration memory: flip-flop outputs, LUT RAM, SRL contents,
     BRAM. Those read back as whatever the design is currently doing.

     prjxray already ships the answer to this: `mask_<tiletype>.db` lists exactly
     the bits that are dynamic and must be excluded before comparing readback to
     the bitstream. We have had those files the whole time and never used them --
     they exist for this and nothing else.
  """

  import Bitwise

  @words_per_frame 101

  # Type-1 packet header: [31:29] type=001, [28:27] op, [26:13] addr, [10:0] count
  @op_read 1
  @op_write 2

  # Configuration register addresses (UG470 Table 5-23)
  @reg_crc 0x00
  @reg_far 0x01
  @reg_fdri 0x02
  @reg_fdro 0x03
  @reg_cmd 0x04
  @reg_stat 0x07
  @reg_cor0 0x09
  @reg_idcode 0x0C

  # CMD register values
  @cmd_wcfg 0x01
  @cmd_rcfg 0x04
  @cmd_start 0x05
  @cmd_rcrc 0x07
  @cmd_desynch 0x0D
  @cmd_lfrm 0x03
  @cmd_grestore 0x0A
  @cmd_null 0x00
  @idcode_7z020 0x0372_7093

  @sync 0xAA99_5566
  # Frame ECC lives in word 50 of a frame; see SiliconSweep.Mask.
  @ecc_word_rb 50
  @noop 0x2000_0000

  def type1(op, addr, count),
    do: (1 <<< 29) ||| (op <<< 27) ||| ((addr &&& 0x3FFF) <<< 13) ||| (count &&& 0x7FF)

  @doc """
  The 12-word preamble every PCAP command stream must begin with.

  Verbatim from Xilinx's own `xdevcfg_reg_readback_example.c`:

      CmdBuf[0..7]  0xFFFFFFFF   eight dummy words
      CmdBuf[8]     0x000000BB   bus width sync word
      CmdBuf[9]     0x11220044   bus width detect
      CmdBuf[10]    0xFFFFFFFF   dummy
      CmdBuf[11]    0xAA995566   sync

  This project sent ONE dummy word and the sync. The bus-width detect pattern
  was missing entirely, and that is the leading explanation for FDRO returning
  zeros for hours while register reads worked: a register read got through on
  an engine the kernel driver had already synced during its own bitstream load,
  but a frame readback needs the stream parsed from a known bus width.

  `0x000000BB` is deliberately asymmetric across byte lanes -- that IS its
  purpose, the device uses it to determine how a 32-bit word is presented. It
  cannot be skipped and it cannot be reordered.
  """
  def preamble,
    do: List.duplicate(0xFFFF_FFFF, 8) ++ [0x0000_00BB, 0x1122_0044, 0xFFFF_FFFF, @sync]

  @doc """
  The command stream that arms a readback of `n_frames` starting at `far`.

  `far` is the raw Frame Address Register value. For xc7 that is the same
  encoding prjxray uses for a tile `baseaddr`, so `FramesPoke.tile_info/2`
  values can be handed straight here.

  ## The pad frame is real

  XAPP1230 gives an XCKU040 readback as "32530 frames + 1 frame + 10 words".
  The extra frame is the configuration engine's pipeline. So `n_frames` of real
  data means requesting `(n_frames + 1) * 101` words and discarding the first
  101 -- which is what `words_for/1` and `to_frames/1` do.

  ## One transfer, not two

  This stream and the data phase are a SINGLE DMA, matching
  `XDcfg_Transfer(cmdbuf, cmd_words, data, data_words, XDCFG_PCAP_READBACK)`.
  Two-phase works for a one-word register read and cannot work for frames: the
  command DMA completes first, the engine fills its ~80-word output FIFO with
  nowhere to drain, and stalls. Measured -- 303 words requested, exactly 80
  written, remainder untouched.
  """
  def arm_sequence(far, n_frames) do
    # ASYMMETRIC LENGTHS, and the asymmetry has a direction.
    #
    # The engine must be told to produce STRICTLY MORE than the DMA will
    # collect. If it produces fewer, the DMA waits for words that never arrive,
    # the queue stalls, INT_STS latches an error that does not clear, and every
    # subsequent transfer fails -- a POWER CYCLE, not a reboot.
    #
    # This is `engine_words/1`, deliberately not `words_for/1`. Raising
    # `words_for` from (n+1) to (n+2) frames to cover the 14-word lead while
    # this line still said (n+1) inverted the asymmetry and wedged the engine
    # on the first call. The two quantities must be defined together and can
    # never be edited independently.
    words = engine_words(n_frames)

    preamble() ++
      [
        @noop,
        type1(@op_write, @reg_cmd, 1),
        @cmd_rcrc,
        @noop,
        @noop,
        type1(@op_write, @reg_far, 1),
        far,
        type1(@op_write, @reg_cmd, 1),
        @cmd_rcfg,
        @noop,
        type1(@op_read, @reg_fdro, 0),
        (2 <<< 29) ||| (@op_read <<< 27) ||| words,
        @noop,
        @noop
      ]
  end

  @doc """
  The command stream that arms a WRITE of `n_frames` starting at `far`.

  Symmetric with `arm_sequence/2` but through FDRI instead of FDRO, and with no
  pad frame -- the pipeline pad exists on the way OUT of the engine, not on the
  way in. Getting that backwards would shift every written frame by one, which
  is the same invisible-and-fatal class as the readback pad.

  Xilinx requires a trailing NOOP flush after the last FDRI word so the engine
  commits the final frame; without it the last frame silently does not land.
  """
  def write_sequence(far, n_frames) do
    # (n + 1), not n. The configuration engine writes frame data through a
    # pipeline one frame deep: the words for frame k are not committed to frame
    # k until the words for frame k+1 arrive. So a write of n frames must be
    # followed by one extra PAD FRAME or the last frame never lands.
    #
    # This is why `:census` wrote 3,136 ones and read back zero. Every candidate
    # bit lives in minor 28 or 29 -- the last two frames of the tile -- which
    # are exactly the frames a missing pad frame silently discards. The write
    # reported success, because it was successful; the data just never left the
    # pipeline.
    #
    # Callers must append `pad_frame/0` to the payload. `write_payload/1` does.
    words = (n_frames + 1) * @words_per_frame

    # Mirrors the preamble of a real bitstream, read out of `tier1_s3.bin` with
    # a packet parser rather than guessed. The parts that were missing and are
    # not optional:
    #
    #   CMD NULL   the engine expects an explicit no-op command before RCRC
    #   IDCODE     7-series compares this against the device and refuses frame
    #              writes on mismatch. Omitting it is not "no check" -- it is
    #              a check against whatever the register happens to hold.
    #
    # The tail matters just as much; see `disarm_sequence/0`.
    [
      0xFFFF_FFFF,
      @sync,
      @noop,
      type1(@op_write, @reg_cmd, 1),
      @cmd_null,
      @noop,
      type1(@op_write, @reg_cmd, 1),
      @cmd_rcrc,
      @noop,
      type1(@op_write, @reg_idcode, 1),
      @idcode_7z020,
      @noop,
      type1(@op_write, @reg_far, 1),
      far,
      type1(@op_write, @reg_cmd, 1),
      @cmd_wcfg,
      @noop,
      type1(@op_write, @reg_fdri, 0),
      (2 <<< 29) ||| (@op_write <<< 27) ||| words
    ]
  end

  @doc "One all-zero frame. Flushes the write pipeline; see `write_sequence/2`."
  def pad_frame, do: List.duplicate(0, @words_per_frame)

  @doc """
  Frame payload for a write: the frames themselves plus the trailing pad frame.

  Always build a write payload through this. Flattening the frame list directly
  is the mistake that made `:census` report a dead tile.
  """
  def write_payload(frames), do: List.flatten(frames) ++ pad_frame()

  @doc """
  Cleanup after a WRITE: START commits the configuration, then DESYNC.
  """
  def disarm_sequence,
    do: [
      type1(@op_write, @reg_cmd, 1),
      @cmd_rcrc,
      @noop,
      type1(@op_write, @reg_cmd, 1),
      @cmd_grestore,
      @noop,
      # LFRM -- "last frame". THIS is the documented flush for the one-frame-deep
      # write pipeline, and its absence is why `:census` wrote 3,136 ones into
      # minors 28 and 29 (the last two frames of the tile) and read back zero.
      # An explicit trailing pad frame is the other half of the same mechanism;
      # a real bitstream sends both.
      type1(@op_write, @reg_cmd, 1),
      @cmd_lfrm,
      @noop,
      type1(@op_write, @reg_cmd, 1),
      @cmd_start,
      @noop,
      type1(@op_write, @reg_cmd, 1),
      @cmd_desynch,
      @noop,
      @noop
    ]

  @doc """
  Cleanup after a READBACK, verbatim from Xilinx's example.

      CmdBuf[0]    0x30008001   write CMD
      CmdBuf[1]    0x0000000D   DESYNC
      CmdBuf[2..5] 0x20000000   NOOP x4

  Six words, and Xilinx sends it as its own DMA with the destination set to the
  invalid-address sentinel and a destination length of ZERO -- it produces no
  data, so asking for any would stall the queue.

  No START here: a readback must not commit anything. Using the write path's
  cleanup after a readback would issue START on a running device.

  Skipping cleanup entirely leaves the engine synced, so the next stream's sync
  word is parsed as data instead of as a fresh sync. Several confusing results
  in this project came from exactly that.
  """
  def readback_cleanup,
    do: [type1(@op_write, @reg_cmd, 1), @cmd_desynch] ++ List.duplicate(@noop, 4)

  @doc """
  Words to request for `n` frames: the pad frame, the lead, and slack.

  ## Why this is not `(n + 1) * 101`

  MEASURED: the readback stream carries **14 words of lead** before the
  pipeline pad frame (SILICON_MAP.md section 22). `(n + 1) * 101` sizes the DMA
  for the pad alone, so those 14 words push the tail of the LAST frame past the
  end of the buffer, where `to_frames/1` drops it as a short chunk.

      request 30 -> 3131 words -> drop 115 -> 3016 -> 29 full frames

  Minor 29 comes back missing and nothing says so. On the CMT that hid 120 of
  209 documented assertions and made a correct database look 91/209 wrong.

  Two extra frames, not one: one covers the lead, one is the pad. Over-reading
  is free -- the engine produces more than the DMA collects, which is the
  ASYMMETRIC-LENGTHS rule that keeps the queue from stalling.
  """
  def words_for(n), do: (n + 1) * @words_per_frame

  @doc """
  Words the COMMAND STREAM asks the engine to produce.

  ## Equal to `words_for/1`, and changing that cost two power cycles

  The obvious-looking improvement -- ask the engine for one frame MORE than the
  DMA collects, so the DMA can never wait on words that are not coming -- does
  not work here, and failed in two different ways:

    1. Raising `words_for` to `(n+2)*101` while this still said `(n+1)*101`
       inverted the asymmetry: DMA collecting 3232 from an engine told to make
       3131. Immediate stall.
    2. Raising BOTH, so the engine was asked for 3333 and the DMA collected
       3232, ALSO stalled -- on the second read after a load, having succeeded
       on the first. The engine did not deliver 3232 despite being asked for
       3333, so its output is evidently not governed by the type-2 count alone.

  What has actually run many consecutive reads without a stall, across two
  boots, is the SYMMETRIC form: ask for exactly what you collect. So that is
  what this is, and the asymmetric-lengths trick from HANDOFF.md is reserved
  for the case it was measured on -- a short register-style read where the
  collect count is far below the production count, not one frame below it.

  ## Getting `n` aligned frames

  Do NOT solve the lead by widening the DMA. Solve it at the CALL SITE: ask for
  `n + 2` frames and take the first `n` after alignment. `raw(far, 32)` is a
  proven-safe way to obtain 30 aligned frames; `words_for(30) + 202` is not.
  """
  def engine_words(n), do: words_for(n)

  @doc """
  Frames to REQUEST in order to end up with `n` aligned frames.

  Two extra: one for the pipeline pad frame, one for the lead, which has been
  observed as high as 14 words and is not constant across boots.
  """
  def request_frames(n), do: n + 2

  # --- alignment -------------------------------------------------------------
  #
  # THE LEAD IS NOT A CONSTANT AND MUST NOT BE HARDCODED.
  #
  # The readback stream carries some number of lead words before the pipeline
  # pad frame. Measured on two consecutive boots of the same board, same
  # bitstream (`mmcm_zinv`), same tile (`0x00402400`), same code:
  #
  #     boot A   lead 14   data at 115    209/209 assertions agree at 115
  #                                        13/209            agree at 101
  #     boot B   lead  0   data at 101    209/209 assertions agree at 101
  #                                        13/209            agree at 115
  #
  # Exactly mirrored. Within a boot it is stable -- 5 consecutive reads and
  # request sizes 6, 8, 10, 14, 20, 30 all agreed -- which is precisely what
  # makes it dangerous: it looks like a constant for as long as you are in a
  # position to notice.
  #
  # An earlier revision of this file hardcoded 14 on that evidence. It was
  # wrong on the very next boot, and wrong in the way that matters: a 14-word
  # displacement leaves routing data looking exactly like routing data, so
  # every bit is silently attributed to the wrong position and nothing
  # complains.
  #
  # So: MEASURE IT, EVERY READ.

  @ecc_max 0x2000
  @min_teeth 4

  @doc """
  Locate the frame grid in a raw readback stream, using the frame ECC.

  `base.frames` cannot serve as the reference in general -- it comes from a
  different build than whatever is loaded, so a mismatch is ambiguous between
  "misaligned" and "different design". The ECC can, because it is the one field
  whose value range is known a priori and is design-independent:

    * 13 bits, so always `< 0x2000`
    * recurs every 101 words, at word 50 of each frame
    * non-zero in any frame that has content

  Slide a 101-tooth comb; score teeth landing on a non-zero 13-bit value.

  Three traps, each of which produced a confident wrong answer before it was
  fixed, and each of which will do so again if this is rewritten:

    1. `< 0x2000` ALONE IS DEGENERATE. These frames are mostly zeros and zero
       passes it, so nearly every offset scored 1.0. Non-zero is what makes the
       comb discriminate.
    2. SAME-PHASE OFFSETS ARE NOT COMPETITORS. 115, 216, 317 ... all satisfy
       `rem(o, 101) == 14`; they are the same alignment one frame later and
       necessarily score identically, so a perfect detection reported itself as
       a dead tie.
    3. EMPTY FRAMES ARE NOT EVIDENCE. An all-zero frame has an all-zero ECC
       legitimately. Counting them as misses dropped a correct detection from
       1.00 to 0.76 over sparse regions -- which is the regime `:census` runs
       in, on a mostly-unused tile.

  Returns the phase; the caller adds the pad frame. Taking the best-scoring
  offset directly does NOT work: once empty frames are excluded the all-zero
  pad frame becomes invisible to the scorer and the argmax drifts one frame
  early.
  """
  def align(words) when is_list(words) do
    n = length(words)
    arr = List.to_tuple(words)
    max_off = n - @words_per_frame * @min_teeth

    scores =
      for off <- 0..max(max_off, 0) do
        teeth = div(n - off - @ecc_word_rb - 1, @words_per_frame)

        if teeth < @min_teeth do
          {0, 1, 0, off}
        else
          # Compute the tooth values ONCE. `hits` and `distinct` must be
          # derived from the SAME filtered set: counting distinctness over all
          # teeth while counting hits over only the ECC-shaped ones let
          # `distinct / hits` exceed 1 and produced a hit_rate of 1.091.
          ecc_vals =
            0..(teeth - 1)
            |> Enum.map(&elem(arr, off + @ecc_word_rb + &1 * @words_per_frame))
            |> Enum.filter(&(&1 > 0 and &1 < @ecc_max))

          hits = length(ecc_vals)

          populated =
            Enum.count(0..(teeth - 1), fn k ->
              base = off + k * @words_per_frame

              Enum.any?(0..(@words_per_frame - 1), fn j ->
                idx = base + j
                idx < n and elem(arr, idx) != 0
              end)
            end)

          # DISTINCTNESS, as a tiebreak.
          #
          # A frame's ECC is effectively a pseudorandom 13-bit number, so
          # across k frames the teeth should be mostly DIFFERENT. Structured
          # configuration data is the opposite: dense routing regions are full
          # of small repeating values, which is why a wrong phase over
          # FAR 0x900 could score a perfect 1.0 hit rate and tie the true one.
          # Hit rate says "these look like ECC values"; distinctness says
          # "these look like DIFFERENT ECC values", and only the second
          # separates real ECC from a column of identical small constants.
          distinct = ecc_vals |> Enum.uniq() |> length()

          if populated < @min_teeth,
            do: {0, 1, 0, off},
            else: {hits, populated, distinct, off}
        end
      end

    # Rank by hit rate first, then by distinctness, then by offset for
    # reproducibility. Distinctness only ever breaks a tie -- it is corroborating
    # evidence, not a substitute for the teeth being ECC-shaped at all.
    # THE PAD FRAME IS ALWAYS ALL ZEROS, whatever the design.
    #
    # That is a structural fact about the configuration engine's pipeline, not
    # a property of the bitstream, so it discriminates exactly where the ECC
    # comb runs out: over a DENSE region (FAR 0x900) a rival phase can score a
    # perfect hit rate AND perfect distinctness, because dense routing data
    # contains plenty of small, varied, non-zero words. It cannot, however,
    # fake 101 consecutive zeros in the right place.
    #
    # Checked at the PHASE, since the pad frame is the first frame emitted:
    # words [phase, phase+101) must all be zero.
    pad_zero? = fn off ->
      ph = rem(off, @words_per_frame)

      ph + @words_per_frame <= n and
        Enum.all?(ph..(ph + @words_per_frame - 1), &(elem(arr, &1) == 0))
    end

    quality = fn {h, t, d, o} ->
      {-(h / max(t, 1)), -(d / max(h, 1)), if(pad_zero?.(o), do: 0, else: 1)}
    end

    sorted = Enum.sort_by(scores, fn {_, _, _, o} = sc -> Tuple.append(quality.(sc), o) end)
    [{h1, t1, d1, o1} | rest] = sorted
    phase = rem(o1, @words_per_frame)

    {h2, t2, d2, _} =
      Enum.find(rest, {0, 1, 0, nil}, fn {_, _, _, o} -> rem(o, @words_per_frame) != phase end)

    # Score combines "ECC-shaped" with "actually varying". Both are in [0,1].
    rate = h1 / max(t1, 1) * (d1 / max(h1, 1))
    runner = h2 / max(t2, 1) * (d2 / max(h2, 1))

    %{
      lead: phase,
      offset: phase + @words_per_frame,
      hit_rate: Float.round(rate, 3),
      runner_up_rate: Float.round(runner, 3),
      # MARGIN, not absolute rate, is the discriminating statistic. Every
      # verified-correct detection so far scored a margin of 0.40, 0.45 or
      # 0.55, while absolute rate ranged 0.786 to 1.0 -- a rate threshold of
      # 0.9 would have rejected two detections that were independently
      # confirmed correct by the 209-assertion set.
      pad_zero: pad_zero?.(o1),
      # A zero pad frame at the chosen phase is strong enough on its own to
      # settle a tie the ECC statistics cannot. Without it, fall back to
      # requiring a clear margin.
      confident: rate >= 0.7 and (pad_zero?.(o1) or rate - runner >= 0.25)
    }
  end

  @doc """
  How many NOOP words must be transmitted to clock out `words` of readback.

  The configuration engine only emits readback data WHILE THE PCAP INTERFACE
  IS BEING CLOCKED. This is not in UG470, UG585 or Xilinx's `xdevcfg` driver,
  because the driver's only readback example reads a single register word and
  the command packet alone supplies far more clocks than that needs.

  Measured on this board: 56 command words yielded 101 output words, then a
  further 256 NOOPs yielded 88 more. Call it ~1.7 transmitted words per output
  word. The ratio is not the interesting part; the ASYMMETRY is. Surplus NOOPs
  are consumed harmlessly, while a shortfall leaves the receive DMA waiting for
  words that will never come -- and with both queue slots then occupied, that
  costs a power cycle. So overshoot, deliberately and by a lot.
  """
  def clock_words(words), do: max(words * 3, 512)

  @doc """
  Drop the pipeline pad frame and split into frames of 101 words.

  Split out and named so it can be unit-tested without a board, because an
  off-by-one-frame error here is invisible in the data and fatal to every
  conclusion drawn from it.
  """
  def to_frames(words) when is_list(words) do
    case align(words) do
      %{confident: true} = a -> {:ok, split(words, a.offset), a}
      a -> {:error, {:unaligned, a}}
    end
  end

  @doc """
  Split at a KNOWN offset. Only for callers that have already measured one.

  Kept separate from `to_frames/1` so that "I measured this" and "I assumed
  this" cannot be spelled the same way.
  """
  def split(words, offset) do
    words
    |> Enum.drop(offset)
    |> Enum.chunk_every(@words_per_frame)
    |> Enum.reject(&(length(&1) < @words_per_frame))
  end
end

defmodule SiliconSweep.Mask do
  # Elixir reads module attributes at the point of USE, in source order, so
  # these must precede `strip_ecc/1`. Defining them below it made both `nil`,
  # which is how this file has now produced `nil * 4` and
  # `List.update_at(list, nil, fun)` in the same session. Attributes go at the
  # top of the module. No exceptions.
  @ecc_word 50
  @ecc_mask 0x1FFF

  @moduledoc """
  prjxray `mask_<tiletype>.db` -- the bits that are DYNAMIC and must be excluded
  before comparing readback against the bitstream we wrote.

  Without this, every flip-flop in the design reads back as a "difference" and
  the comparison is meaningless noise. With it, a difference is a real
  difference.

  The mask files ship in prjxray-db and have been sitting unused in this project
  since the beginning.
  """

  @doc "Parse `mask_*.db`: one `<minor>_<bit>` per line."
  def parse(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^bit\s+(\d+)_(\d+)/, String.trim(line)) do
        [_, mi, bi] -> [{String.to_integer(mi), String.to_integer(bi)}]
        _ -> []
      end
    end)
    |> MapSet.new()
  end

  @doc """
  Zero the per-frame ECC that the DEVICE computes and the bitstream does not.

  Measured, not assumed: ten consecutive frames read back from `FAR=0x900`
  matched `base.frames` exactly except in **word 50, bits [12:0]**, in every
  single frame -- `0xE12`, `0xE0F`, `0x1E5`, `0x62`, `0x1D84`, `0x143E`,
  `0x4D8`, `0x1760`, `0x7F8`, `0x1122`. All thirteen bits wide, all in the same
  place, never anywhere else.

  That is the 7-series frame ECC. The device computes a Hamming code over each
  frame and reports it on readback; openXC7 writes zeros there, and Vivado only
  fills it in when asked. It is not a discrepancy and it is not silicon telling
  us anything -- but left unmasked it makes EVERY frame differ, which would
  make the whole comparison useless exactly the way an unmasked flip-flop would.

  This is separate from `mask_*.db`, which covers dynamic bits per tile type.
  The ECC is per frame and applies everywhere, so it is masked unconditionally.
  """
  def strip_ecc(frames) do
    import Bitwise

    Enum.map(frames, fn frame ->
      List.update_at(frame, @ecc_word, fn w -> w &&& bnot(@ecc_mask) end)
    end)
  end

  @doc "Zero every masked bit in a list of frames so a comparison is meaningful."
  def apply(frames, masked, offset, words) do
    import Bitwise

    frames
    |> Enum.with_index()
    |> Enum.map(fn {frame, minor} ->
      frame
      |> Enum.with_index()
      |> Enum.map(fn {word, wi} ->
        if wi < offset or wi >= offset + words do
          word
        else
          Enum.reduce(0..31, word, fn b, acc ->
            bit = (wi - offset) * 32 + b
            if MapSet.member?(masked, {minor, bit}), do: acc &&& bnot(1 <<< b), else: acc
          end)
        end
      end)
    end)
  end
end

defmodule SiliconSweep.GroupTesting do
  @moduledoc """
  NOT IMPLEMENTED, ON PURPOSE. Read this before proposing it again.

  The obvious way to find one interesting bit among 2,614 is adaptive group
  testing: poke half, test, recurse. The information-theoretic bound is
  `T >= d*log2(n/d)`, so about 12 loads instead of 2,614. It is enormously
  attractive and it is wrong here.

  Group testing rests on ONE assumption: a pool tests positive if it contains
  ANY defective. Monotone. Adding items to a pool can only push the result
  toward positive.

  Poking configuration bits is ANTI-monotone. A pool containing the one
  interesting bit plus two hundred harmful ones reads NEGATIVE, because the
  harmful bits break the design. Setting more bits monotonically increases the
  probability of a broken result. The oracle inverts exactly the property the
  algorithm requires.

  This is not the "noisy group testing" case either. Noise models assume a
  probability of a flipped answer around a still-monotone truth; here the truth
  itself has the wrong shape.

  So the sound options are:

    * `:census` -- monotone, because it asks the configuration memory what stuck
      rather than asking the design whether it still works. One experiment for
      the whole space.
    * `:functional` -- one bit at a time, O(n), no pooling.

  An earlier plan in this project called the 2,614-bit group-test search
  "tractable" on the basis of having counted the space. Counting the space is
  not the same as checking that the search is valid on it.
  """
  def run(_), do: {:error, :invalid_method_see_moduledoc}
end

defmodule SiliconSweep.Journal do
  @moduledoc """
  Append-only, flushed per record, so a sweep that dies at bit 1,900 of 2,614
  does not lose 1,900 results.

  A long unattended run WILL be interrupted -- by a wedged PL, a power cycle, or
  a poke that takes the fabric down hard enough to need a reboot. Resumability
  is not a nicety here, it is what makes an overnight sweep possible at all.
  """

  @path "/root/silicon_sweep.jsonl"

  def path, do: @path

  def append(record) when is_map(record) do
    line = record |> Map.put(:t, System.system_time(:second)) |> inspect(limit: :infinity)
    File.write!(@path, line <> "\n", [:append])
    :ok
  end

  @doc "Bits already tested, so a resumed run skips them."
  def done_bits do
    case File.read(@path) do
      {:ok, text} ->
        text
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn l ->
          case Regex.run(~r/minor: (\d+), bit: (\d+)/, l) do
            [_, mi, bi] -> [{String.to_integer(mi), String.to_integer(bi)}]
            _ -> []
          end
        end)
        |> MapSet.new()

      _ ->
        MapSet.new()
    end
  end
end

defmodule SiliconSweep.Safety do
  @moduledoc """
  Guards for a long unattended sweep that is writing arbitrary bits into
  configuration memory.

  prjxray's fuzzers never need this: every bitstream they produce came from a
  valid Vivado design, so it is electrically sane by construction. We have no
  such protection. A poked bit can enable two drivers onto one wire, and
  internal contention is a real way to damage a die -- not a theoretical one.

  So: short dwell, check liveness after every load, and stop the whole run on
  anything unexpected rather than pressing on and collecting garbage.
  """

  @dwell_ms 150

  def dwell, do: Process.sleep(@dwell_ms)

  @doc """
  Is the board still healthy enough to trust the next result?

  Deliberately checks the PS side too. If a poke wedges the PL badly enough that
  AXI reads hang, the CPU hangs with it -- there is no timeout on the Zynq
  interconnect -- so the only way to survive is to not get there.
  """
  def healthy? do
    with {:ok, _} <- Nervezynq.SLCR.read32(0x170),
         {:ok, st} <- SiliconSweep.Devcfg.status() do
      st.pl_init
    else
      _ -> false
    end
  end

  @doc "Abort criteria that stop a whole sweep rather than one bit."
  def fatal?(%{result: :board_unreachable}), do: true
  def fatal?(%{result: :pl_deconfigured}), do: true
  def fatal?(_), do: false
end

defmodule SiliconSweep do
  # --- buffer layout ---------------------------------------------------------
  #
  # Every transfer stages words in the reserved buffer and hands devcfg a
  # PHYSICAL address. Command streams go out at @cmd_offset; readback data comes
  # back at @rb_offset, so an armed sequence is never overwritten by the data it
  # is fetching; the NOOP clock stream sits at @clk_offset, 1 MW in, far past any
  # readback payload, so a long read can never overlap the words clocking it out.
  #
  # DEFINED HERE, AT THE TOP, DELIBERATELY. Elixir reads module attributes at the
  # point of USE, in source order. These three lived at the bottom of the module
  # while `readback_tile/1` and `cleanup_readback/0` referenced them a hundred
  # lines earlier, so every one of those references evaluated to `nil` -- and
  # `nil * 4` is the only reason it ever surfaced. Harness readback could not
  # have worked at any point before this was fixed, which is worth knowing when
  # reading back through this file's history.

  @cmd_offset 0
  @rb_offset 4096
  @clk_offset 262_144

  # Fail the compile rather than the transfer if one of them ever goes missing
  # again. A nil offset silently becomes address 0 in some arithmetic paths, and
  # a DMA to address 0 is not a mistake that announces itself.
  for {name, v} <- [cmd_offset: @cmd_offset, rb_offset: @rb_offset, clk_offset: @clk_offset] do
    unless is_integer(v), do: raise("@#{name} is #{inspect(v)} -- must be an integer")
  end

  @moduledoc """
  Runner. Every strategy declares prerequisites; nothing runs unchecked.
  """

  import Bitwise

  alias SiliconSweep.{Devcfg, Journal, Readback, Safety}

  @strategies [:selfcheck, :pokecheck, :census, :functional]

  @doc """
  What can this board actually do right now?

  Reports each prerequisite by NAME. A harness that says "clean" after
  examining nothing is worse than one that crashes, and this project has
  already shipped one of those.
  """
  def probe do
    checks = [
      {:fabric_port_binary, fn -> File.exists?(Application.app_dir(:nervezynq, "priv/fabric_port")) end},
      {:slcr_mapped, fn -> match?({:ok, _}, Nervezynq.SLCR.read32(0x170)) end},
      {:devcfg_mapped, fn -> match?({:ok, _}, Devcfg.read32(0x00)) end},
      {:devcfg_wire_protocol, fn -> match?({:ok, _}, Devcfg.read32(0x14)) end},
      {:pl_configured, fn -> match?({:ok, _}, Nervezynq.Fabric.info()) end},
      {:dma_buffer, &dma_buffer_available?/0},
      {:mask_db_present, fn -> File.exists?("/root/mask_cmt_top_l_lower_b.db") end},
      {:base_frames_present, fn -> File.exists?("/root/base.frames") end}
    ]

    results =
      Map.new(checks, fn {name, f} ->
        {name, try do f.() catch _, _ -> false end}
      end)

    IO.puts("\ncapability probe")
    for {k, v} <- Enum.sort(results) do
      IO.puts("  #{if v, do: "yes", else: "NO "}  #{k}")
    end

    IO.puts("\nstrategies")
    for s <- @strategies do
      missing = prerequisites(s) |> Enum.reject(&results[&1])
      IO.puts(
        "  #{String.pad_trailing(to_string(s), 12)} " <>
          if(missing == [], do: "ready", else: "blocked: " <> Enum.join(missing, ", "))
      )
    end

    IO.puts("\n  grouptest    invalid method -- see SiliconSweep.GroupTesting")
    results
  end

  def prerequisites(:selfcheck),
    do: [:devcfg_mapped, :devcfg_wire_protocol, :dma_buffer, :mask_db_present, :base_frames_present]

  def prerequisites(:pokecheck), do: prerequisites(:selfcheck)
  def prerequisites(:census), do: prerequisites(:selfcheck)
  def prerequisites(:functional), do: [:pl_configured, :devcfg_mapped, :dma_buffer]

  @doc """
  The physical DMA buffer devcfg needs for readback.

  This is the one prerequisite that cannot be satisfied from Elixir alone.
  devcfg's DMA takes PHYSICAL addresses, so readback needs a physically
  contiguous, word-aligned buffer that the kernel is not using. Options, in
  increasing order of intrusiveness:

    1. Reserve a range at boot (`mem=` on the kernel cmdline, or a
       `reserved-memory` node) and map it with a third fabric_port instance.
       No Rust, one firmware rebuild.
    2. A CMA allocation exposed through a small NIF addition.

  Until one exists, every readback strategy is correctly reported blocked. It is
  NOT acceptable to point the DMA at a guessed address: writing frame data over
  live kernel memory is not a recoverable mistake.
  """
  def dma_buffer_available? do
    match?({:ok, _}, SiliconSweep.DmaBuf.verify())
  end

  def run(strategy, opts \\ [])

  def run(:grouptest, _), do: SiliconSweep.GroupTesting.run(nil)

  def run(strategy, opts) when strategy in @strategies do
    results = probe()
    missing = prerequisites(strategy) |> Enum.reject(&results[&1])

    if missing != [] do
      {:error, {:blocked, missing}}
    else
      do_run(strategy, opts)
    end
  end

  # --- :selfcheck -----------------------------------------------------------
  #
  # Read back the bitstream we just wrote and compare against the .frames it was
  # built from, with prjxray's mask applied. Passing means readback addressing,
  # the pad-frame drop, and the mask are all correct. Nothing else in this file
  # is believed until it does.
  defp do_run(:selfcheck, _opts) do
    with :ok <- Devcfg.unlock(),
         :ok <- Devcfg.set_readback_direction(),
         {:ok, frames} <- readback_tile(base_tile()) do
      expected = expected_for(base_tile(), load_expected_frames())
      masked = load_mask()

      # Strip the device-computed per-frame ECC before anything else. It lives in
      # word 50, outside the tile's word window, so `Mask.apply/4` would never
      # reach it -- and left in place it makes every one of the 30 frames differ
      # for a reason that has nothing to do with the tile under test.
      a =
        frames
        |> SiliconSweep.Mask.strip_ecc()
        |> SiliconSweep.Mask.apply(masked, base_tile().offset, base_tile().words)

      b =
        expected
        |> SiliconSweep.Mask.strip_ecc()
        |> SiliconSweep.Mask.apply(masked, base_tile().offset, base_tile().words)

      diffs =
        Enum.zip(a, b)
        |> Enum.with_index()
        |> Enum.flat_map(fn {{fa, fb}, minor} ->
          Enum.zip(fa, fb)
          |> Enum.with_index()
          |> Enum.reject(fn {{x, y}, _} -> x == y end)
          |> Enum.map(fn {{x, y}, wi} -> {minor, wi, x, y} end)
        end)

      # A tile whose expected frames are entirely zero cannot validate anything:
      # readback returning zeros would "match" without a single bit of evidence
      # that the readback path works. `CMT_TOP_L_LOWER_B_X178Y61` is exactly
      # such a tile in this bitstream -- the CMT is unused, so `base.frames`
      # holds nothing for it, and an earlier run of this gate reported
      # `differing_words: 0` while proving precisely nothing.
      #
      # The real evidence came from a target with content: 10 frames at
      # FAR 0x900, 1010 words, matching base.frames exactly apart from the
      # per-frame ECC. A gate that cannot tell those two situations apart is
      # not a gate.
      live = Enum.count(List.flatten(expected), &(&1 != 0))

      verdict =
        cond do
          live == 0 -> :vacuous
          diffs == [] -> :pass
          true -> :fail
        end
      Journal.append(%{
        strategy: :selfcheck,
        result: verdict,
        diffs: length(diffs),
        nonzero_expected_words: live
      })

      {verdict,
       %{
         differing_words: length(diffs),
         nonzero_expected_words: live,
         sample: Enum.take(diffs, 8),
         note:
           if(live == 0,
             do: "expected frames are ALL ZERO -- this target proves nothing, pick another tile",
             else: nil
           )
       }}
    end
  end

  # --- :census --------------------------------------------------------------
  #
  # Monotone, one experiment. Write 1 to every candidate bit; whatever reads
  # back 1 is a real configuration cell, whatever reads back 0 is not wired to
  # anything. Prunes the dark space without a functional oracle at all.
  defp do_run(:census, opts) do
    tile = base_tile()
    candidates = Keyword.get(opts, :candidates, undocumented_bits(tile))

    IO.puts("census over #{length(candidates)} candidate bit positions in #{tile.name}")
    IO.puts("this is ONE write and ONE read, not #{length(candidates)} tests")

    with {:ok, poked} <- write_all_ones(tile, candidates),
         :ok <- Safety.dwell(),
         {:ok, readback} <- readback_tile(tile) do
      stuck =
        Enum.filter(candidates, fn {minor, bit} ->
          read_bit(readback, tile, minor, bit) == 1
        end)

      Journal.append(%{
        strategy: :census,
        candidates: length(candidates),
        stuck: length(stuck),
        bits: stuck
      })

      _ = poked

      {:ok,
       %{
         candidates: length(candidates),
         real_cells: length(stuck),
         pruned: length(candidates) - length(stuck),
         bits: stuck
       }}
    end
  end

  # --- :functional ----------------------------------------------------------
  #
  # One bit at a time. O(n). Resumable, because it will be interrupted.
  defp do_run(:functional, opts) do
    tile = base_tile()
    oracle = Keyword.get(opts, :oracle, &default_oracle/0)
    limit = Keyword.get(opts, :limit, :infinity)

    done = Journal.done_bits()

    candidates =
      Keyword.get(opts, :candidates, undocumented_bits(tile))
      |> Enum.reject(&MapSet.member?(done, &1))
      |> then(fn l -> if limit == :infinity, do: l, else: Enum.take(l, limit) end)

    IO.puts("functional sweep: #{length(candidates)} bits, ~#{div(length(candidates) * 10, 60)} min")
    IO.puts("resuming past #{MapSet.size(done)} already recorded")

    baseline = oracle.()
    Journal.append(%{strategy: :functional, phase: :baseline, oracle: baseline})

    Enum.reduce_while(candidates, %{changed: [], tested: 0}, fn {minor, bit}, acc ->
      record =
        case poke_load_test(tile, minor, bit, oracle) do
          {:ok, obs} ->
            %{
              strategy: :functional,
              minor: minor,
              bit: bit,
              oracle: obs,
              changed: obs != baseline,
              result: :ok
            }

          {:error, why} ->
            %{strategy: :functional, minor: minor, bit: bit, result: why}
        end

      Journal.append(record)

      cond do
        Safety.fatal?(record) ->
          {:halt, Map.put(acc, :aborted, {minor, bit})}

        not Safety.healthy?() ->
          Journal.append(%{strategy: :functional, result: :board_unhealthy, at: {minor, bit}})
          {:halt, Map.put(acc, :aborted, {minor, bit})}

        true ->
          {:cont,
           acc
           |> Map.update!(:tested, &(&1 + 1))
           |> Map.update!(:changed, fn c -> if record[:changed], do: [{minor, bit} | c], else: c end)}
      end
    end)
    |> then(&{:ok, &1})
  end

  defp do_run(:pokecheck, _opts) do
    # Validate frames_poke's arithmetic against SILICON: poke one KNOWN
    # documented bit, read it back, confirm it landed exactly where prjxray
    # says. Today that arithmetic is validated against fasm2frames, i.e.
    # against another tool's opinion rather than the chip's.
    {:error, :not_implemented_until_selfcheck_passes}
  end

  # --- plumbing -------------------------------------------------------------

  @doc "The tile under test. Public so `readback_tile/1` is usable standalone."
  def base_tile do
    # CMT_TOP_L_LOWER_B_X178Y61, from tilegrid.json. Regenerate for another tile
    # with:  mix run scripts/frames_poke_cli.exs --show <TILE>
    %{
      name: "CMT_TOP_L_LOWER_B_X178Y61",
      baseaddr: 0x0040_2400,
      frames: 30,
      offset: 0,
      words: 49
    }
  end

  @doc """
  The dark space: every addressable bit in the tile that prjxray does NOT name.

  For the CMT that is minors 28 and 29 only -- every documented CMT feature,
  config and pip alike, lives there. 2 x 49 x 32 = 3,136 positions, of which 522
  are documented, leaving 2,614.

  Counting them is easy and was never the hard part. What matters is that
  `:census` can dismiss most of them in one experiment.
  """
  def undocumented_bits(tile, documented \\ nil) do
    doc = documented || documented_bits()

    for minor <- [28, 29],
        bit <- 0..(tile.words * 32 - 1),
        not MapSet.member?(doc, {minor, bit}),
        do: {minor, bit}
  end

  defp documented_bits do
    # Generated host-side from segbits_cmt_top_l_lower_b.db; shipped to the
    # board as a term file so this script needs no prjxray checkout.
    case File.read("/root/documented_bits.term") do
      {:ok, t} -> t |> Code.eval_string() |> elem(0) |> MapSet.new()
      _ -> MapSet.new()
    end
  end

  @doc """
  Read `tile`'s frames back.

  ## Three steps, and the order matters

      1. TX  command sequence, await D_P_DONE
      2. RX  N words                       <- armed, will stall part-way
      3. TX  clock_words(N) NOOP words     <- supplies the clocks that drain it

  Steps 2 and 3 occupy both DMA queue slots simultaneously. Step 3 must be
  queued BEHIND the already-armed receive: the receive has to be waiting before
  the clocks arrive, or the data it should have caught is emitted into nothing.

  ## Why this replaces the single combined DMA

  This function previously issued one transaction with both lengths programmed
  together, on the theory that the engine would otherwise fill a ~80-word FIFO
  and stall. The evidence for that theory was real -- a request for 303 words
  wrote exactly 80 and stopped -- but the diagnosis was wrong. The engine was
  not backed up; it was out of clocks. The command stream had ended, and with
  it the only thing driving the fabric.

  The same misreading explains why one-word register reads worked for hours
  while no frame ever did: a single word needs almost no clocks, and the
  command packet supplies them.

  Confirmed directly: a read of `FAR=0x900` stalled at the pad frame, and
  pushing 256 NOOPs at the still-armed receive resumed the stream and delivered
  frame 0x900 matching `base.frames`.
  """
  @doc """
  Read a tile's frames, aligned. Public because it is the instrument.

  Every claim this harness makes reduces to this call, so it needs to be
  callable on its own -- to check stability, to re-derive a result by hand, and
  to be exercised without dragging a whole strategy along with it.
  """
  def readback_tile(tile) do
    alias SiliconSweep.DmaBuf
    # request_frames/1, not tile.frames: the readback stream carries a variable
    # lead, so obtaining `tile.frames` ALIGNED frames means asking for two
    # more and letting the aligner find them. Asking for exactly tile.frames
    # returns one frame short, and the missing one is the LAST minor -- which
    # on the CMT is where 120 of 209 documented assertions live, so the loss
    # presents as a half-wrong database rather than as a truncated read.
    asked = Readback.request_frames(tile.frames)
    words = Readback.words_for(asked)
    clocks = Readback.clock_words(words)
    # SAME `asked` on both sides. The command stream and the DMA length are one
    # decision; spelling them with two different frame counts is what stalled
    # the engine twice tonight.
    seq = Readback.arm_sequence(tile.baseaddr, asked)

    with :ok <- Devcfg.assert_queue_idle!(),
         :ok <- prime_ctrl(),
         :ok <- DmaBuf.write_words(@cmd_offset, seq),
         :ok <- DmaBuf.write_words(@clk_offset, List.duplicate(0x2000_0000, clocks)),
         :ok <- Devcfg.clear_ints(),
         :ok <- Devcfg.dma(DmaBuf.base() + @cmd_offset * 4, 0xFFFF_FFFF, length(seq), 0),
         {:ok, _} <- Devcfg.await_transfer(4_000),
         :ok <- Devcfg.clear_ints(),
         :ok <- Devcfg.dma(0xFFFF_FFFF, DmaBuf.base() + @rb_offset * 4, 0, words),
         :ok <- Devcfg.dma(DmaBuf.base() + @clk_offset * 4, 0xFFFF_FFFF, clocks, 0),
         {:ok, _} <- Devcfg.await_transfer(15_000),
         {:ok, raw} <- DmaBuf.read_chunked(@rb_offset, words),
         # Alignment is MEASURED here, not assumed. It has been observed to
         # differ between boots (lead 0 and lead 14 on consecutive boots of the
         # same board and bitstream), and an unaligned split silently
         # misattributes every bit. `to_frames/1` returns an error rather than
         # a guess when the evidence is thin, and that error must propagate --
         # a readback that cannot be aligned is not a readback.
         {:ok, frames, _align} <- Readback.to_frames(raw) do
      _ = cleanup_readback()
      # Trim back to the tile's real frame count. The extra two were requested
      # only to give the aligner room to find the lead.
      {:ok, Enum.take(frames, tile.frames)}
    end
  end

  @words_per_frame_rb 101

  # Cleanup DMA: six words out, ZERO words back. Asking for data here would
  # stall the queue, and a stalled queue costs a power cycle.
  defp cleanup_readback do
    alias SiliconSweep.DmaBuf
    seq = Readback.readback_cleanup()

    with :ok <- DmaBuf.write_words(@cmd_offset, seq),
         :ok <- Devcfg.clear_ints(),
         :ok <- Devcfg.dma(DmaBuf.base() + @cmd_offset * 4, 0xFFFF_FFFF, length(seq), 0) do
      Devcfg.await_transfer(2_000)
    end
  end

  # PCAP_MODE|PCAP_PR must be set before any transfer. Omitting this once cost a
  # whole power cycle: the command phase reported :ok and the data phase failed,
  # which looks exactly like a bad command stream.
  defp prime_ctrl do
    with {:ok, c} <- Devcfg.read32(0x00) do
      Devcfg.write32(0x00, c ||| 1 <<< 26 ||| 1 <<< 27)
    end
  end

  defp read_bit(frames, tile, minor, bit) do
    import Bitwise
    word = tile.offset + div(bit, 32)

    frames
    |> Enum.at(minor, [])
    |> Enum.at(word, 0)
    |> then(&((&1 >>> rem(bit, 32)) &&& 1))
  end

  # --- the platform boundary, now real --------------------------------------
  #
  # Every transfer stages words in the reserved buffer and hands devcfg a
  # PHYSICAL address. Command streams go out at word offset 0; readback data
  # comes back at @rb_offset, so an armed sequence is never overwritten by the
  # data it is fetching.

  @doc """
  DMA a command stream from the buffer into the configuration engine.

  src = our buffer, dst = the PL sentinel. Lengths are in WORDS.
  """
  defp write_command_stream(words) do
    alias SiliconSweep.DmaBuf
    n = length(words)

    with :ok <- DmaBuf.write_words(@cmd_offset, words),
         :ok <- Devcfg.clear_ints(),
         # dst_len is ZERO. This phase sends commands and receives NOTHING.
         :ok <-
           Devcfg.dma(
             DmaBuf.dma_addr(DmaBuf.base() + @cmd_offset * 4),
             DmaBuf.pl_sentinel(),
             n,
             0
           ),
         {:ok, _} <- Devcfg.await_transfer() do
      :ok
    end
  end

  @doc """
  DMA `count` words of frame data back out of the PL into the buffer.

  src = the PL sentinel, dst = our buffer. The engine must already have been
  armed by `Readback.arm_sequence/2`; this is only the data phase.
  """
  defp dma_read(count) do
    alias SiliconSweep.DmaBuf

    with :ok <- Devcfg.clear_ints(),
         # src_len is ZERO. This phase sends nothing and receives `count`.
         :ok <-
           Devcfg.dma(
             DmaBuf.pl_sentinel(),
             DmaBuf.dma_addr(DmaBuf.base() + @rb_offset * 4),
             0,
             count
           ),
         {:ok, _} <- Devcfg.await_transfer(5_000),
         {:ok, words} <- DmaBuf.read_chunked(@rb_offset, count) do
      {:ok, words}
    end
  end

  @doc """
  The :census write: set every candidate bit and load the result.

  Built as a PARTIAL bitstream over the tile's frames rather than a full device
  load, so the rest of the design is left alone and the census does not depend
  on the fabric still working afterwards -- which it very likely will not, since
  the whole point is to write bits with no regard for what they do.

  Note this is the one operation here that is deliberately reckless about
  function. It is safe to be, because `:census` never asks the design a
  question; it asks the configuration memory what stuck, and that answer does
  not require a working fabric.
  """
  defp write_all_ones(tile, bits) do
    alias SiliconSweep.DmaBuf
    import Bitwise

    # Start from the frames currently in the device, so only the candidate bits
    # change. Reading first also means a census can be repeated without a
    # rebuild.
    with {:ok, current} <- readback_tile(tile) do
      patched =
        Enum.reduce(bits, current, fn {minor, bit}, frames ->
          word = tile.offset + div(bit, 32)

          List.update_at(frames, minor, fn f ->
            List.update_at(f, word, &(&1 ||| 1 <<< rem(bit, 32)))
          end)
        end)

      seq =
        Readback.write_sequence(tile.baseaddr, tile.frames) ++
          Readback.write_payload(patched) ++ Readback.disarm_sequence()

      with :ok <- write_command_stream(seq), do: {:ok, length(bits)}
    end
  end

  @doc """
  The frames the running bitstream was built from, KEYED BY FRAME ADDRESS.

  Keyed, not positional. `base.frames` is a whole-device file -- 7802 frames in
  file order -- while a readback returns only the 30 frames of one tile. Zipping
  those two lists positionally compares the CMT against whatever happens to sit
  in the first 30 lines of the file, which is a comparison that can fail for
  reasons having nothing to do with readback, or pass by coincidence on a
  region that is zero in both.

  A frame absent from the file is all-zero: `fasm2frames` only emits frames it
  has something to say about, and a frame it never mentions is genuinely zero in
  the bitstream.
  """
  def load_expected_frames do
    case File.read("/root/base.frames") do
      {:ok, text} ->
        text
        |> String.split("\n", trim: true)
        |> Map.new(fn line ->
          [addr | rest] = String.split(line, " ", parts: 2)

          words =
            rest
            |> List.first("")
            |> String.split(",")
            |> Enum.map(
              &(&1 |> String.trim() |> String.replace_prefix("0x", "") |> String.to_integer(16))
            )

          {addr |> String.replace_prefix("0x", "") |> String.to_integer(16), words}
        end)

      e ->
        # NOT `%{}`. An empty expected-set makes every frame compare against
        # all-zero, which makes `:selfcheck` pass by vacuum. This project has
        # already shipped one audit tool that reported "clean" after examining
        # nothing; that must not happen to the gate everything else depends on.
        raise "cannot read /root/base.frames (#{inspect(e)}) -- refusing to " <>
                "compare against an empty expected set"
    end
  end

  @doc "The `n` frames of `tile`, in minor order, from an address-keyed map."
  def expected_for(tile, by_addr) do
    zero = List.duplicate(0, 101)
    for minor <- 0..(tile.frames - 1), do: Map.get(by_addr, tile.baseaddr + minor, zero)
  end

  defp load_mask do
    case File.read("/root/mask_cmt_top_l_lower_b.db") do
      {:ok, t} ->
        SiliconSweep.Mask.parse(t)

      e ->
        # An empty mask does not fail loudly, it just stops excluding dynamic
        # bits -- so comparisons start reporting differences that are not
        # differences, or (worse, here) stop excluding nothing at all and look
        # fine. Same reasoning as base.frames: refuse.
        raise "cannot read /root/mask_cmt_top_l_lower_b.db (#{inspect(e)})"
    end
  end

  @doc """
  One functional test: poke a bit, load, ask the oracle, put it back.

  Restores by rewriting the tile from the pristine frames rather than by
  clearing the poked bit, because a bit that took the fabric down may also have
  prevented the clear from landing. Restoring from a known image is the only
  version of this that is idempotent under failure.
  """
  defp poke_load_test(tile, minor, bit, oracle) do
    alias SiliconSweep.Safety
    import Bitwise

    with {:ok, pristine} <- readback_tile(tile) do
      word = tile.offset + div(bit, 32)

      poked =
        List.update_at(pristine, minor, fn f ->
          List.update_at(f, word, &(&1 ||| 1 <<< rem(bit, 32)))
        end)

      result =
        with :ok <- write_frames(tile, poked),
             :ok <- Safety.dwell() do
          {:ok, oracle.()}
        end

      # Always restore, including on the failure path.
      _ = write_frames(tile, pristine)
      Safety.dwell()

      result
    end
  end

  @doc """
  Write an explicit frame list into `tile`. Public because it is the other half
  of the instrument.

  `:census` can only write ONES, which makes it a one-sided test: a position
  that reads 1 after an all-ones write could be a cell holding 1, or a position
  that is not a cell and reads as 1. Distinguishing those needs the mirror --
  write ZEROS to the same positions and confirm they read 0 -- and that needs a
  way to write an arbitrary frame image.
  """
  def write_frames(tile, frames) do
    # write_payload/1, NOT List.flatten/1.
    #
    # `write_sequence/2` declares an FDRI packet of (n+1)*101 words because the
    # engine's write pipeline is one frame deep and needs a trailing pad frame.
    # Flattening the frame list alone supplies only n*101, so the engine sits
    # mid-packet waiting for 101 words that never come, consumes the DESYNC
    # words as frame data instead, and the NEXT readback stalls -- a power
    # cycle, and one that presents as a broken reader rather than a broken
    # writer.
    #
    # `:census` was never affected because `write_all_ones/2` already used
    # `write_payload/1`. This path -- and therefore `poke_load_test/4` and the
    # whole `:functional` strategy -- did not. The two writers must agree.
    seq =
      Readback.write_sequence(tile.baseaddr, tile.frames) ++
        Readback.write_payload(frames) ++ Readback.disarm_sequence()

    write_command_stream(seq)
  end

  @doc """
  Default functional oracle: does the radio still decode?

  Deliberately the STRONGEST signal available rather than a status bit. This
  project has been fooled three times by status bits that lie -- a lock bit, a
  frame-integrity metric that reads 0.25 on perfect captures, and an aliased
  heartbeat. `deg_per_sample` at 11.25 with `mag_cv` near zero is arithmetic
  that can only come out right if the whole capture path works.
  """
  def default_oracle do
    try do
      case Nervezynq.MIMO.validate(Nervezynq.Fabric.read_repeat(0x28, 8192) |> elem(1)) do
        {:ok, v} -> %{deg: v.ch1.deg_per_sample, cv: v.ch1.mag_cv, mean: v.ch1.mag_mean}
        other -> %{error: inspect(other)}
      end
    catch
      _, e -> %{error: inspect(e)}
    end
  end
end
