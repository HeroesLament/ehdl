# Nervezynq.HPStream — the HP0 DMA stream consumer (SDR V2, STREAM_RX).
#
# Hot-loadable like sdr.exs, and used by it:
#
#     Code.compile_file("/data/hp_stream.exs")
#     {:ok, _} = Nervezynq.SDR.open()          # platform ritual + radio up
#     Nervezynq.HPStream.setup()               # EMIO directions, ports mapped
#     Nervezynq.HPStream.rate_test(200)        # Gate 4: counter mode, MB/s
#     {:ok, cap} = Nervezynq.HPStream.capture_burst(262_144)  # gapless radio
#     Nervezynq.HPStream.stream_rx(self())     # continuous decimated delivery
#
# ## What this consumes
#
# The `hp_dma_s1` fabric revision: LVDS -> Hw.AD936xFramePacker -> RegFIFO16
# -> Hw.AXIHPWriter -> DDR ring at 0x3FF0_0000 (top 1 MB of the DmaBuf
# reservation). One 64-bit word per radio frame:
#
#     [11:0] I1  [23:12] Q1  [35:24] I2  [47:36] Q2
#     [61:48] SEQ (mod 16384)  [62] ERR (first frame after resync)  [63] 0
#
# Raw 12-bit two's complement, same edge assembly as the snapshot path —
# nibble_swap:false semantics, no swap anywhere here. The layout's single
# source of truth is Hw.AD936xFramePacker's moduledoc; change both together.
#
# ## Control and status: EMIO only, never AFI
#
# Control rides EMIO bank 2 outputs (gpiochip line 54 = bit 0):
#     [0] dma_enable   [1] source select (0 counter / 1 radio)   [2] flag clear
# Status rides the EMIO input word (banks 2/3, read via DATA_RO):
#     bank2 RO: [15:0] bursts, [31:16] write_ptr[19:4]
#     bank3 RO: [7:0] bresp_errs, [8] heartbeat, [9] alive=1, [10] =1, [11] =0,
#               [17:12] WACOUNT, [25:18] WCOUNT, [28:26] overrun count,
#               [29] overrun sticky, [30] packer sync_lost, [31] src_sel readback
#
# The GPIO controller (0xE000A000) and the DDR ring both map and read safely
# from Linux (proven 2026-08-02). **NEVER map or read AFI0 (0xF800_8000): one
# read hung the CPU beyond recovery — power cycle. It is not needed;
# BRESP=OKAY already proved the defaults.**
#
# ## Rates, honestly
#
# At 8 Msps the stream writes 64 MB/s; the 1 MB ring holds 16 ms. Userspace
# CANNOT drain that continuously (uncached DDR reads through the port run
# tens of MB/s at best), and usb0 certainly cannot ship it. So there are two
# consumption modes, both real:
#
#   * capture_burst/2 — gapless up to 1 MB (131,072 frames = 16 ms at 8 Msps,
#     128x the snapshot depth): enable from clean state, watch write_ptr,
#     disable before wrap, read at leisure, verify SEQ is one unbroken run.
#     This is the beacon-depth capture the SDR plan runs through.
#   * stream_rx/2 — continuous decimated delivery: poll write_ptr, read only
#     the newest window per poll (default 8 KB at ~20 Hz), ship it decoded or
#     raw. Ring laps between polls are EXPECTED here and reported in the
#     meta, not silently dropped. This is the waterfall feed.
#
# SEQ makes lost data visible in both modes: any adjacent pair inside one
# read that is not +1 mod 16384 is a hole, and the poll meta carries the
# count. Overruns of the fabric FIFO (DMA stalled) additionally show in the
# sticky EMIO flag.

defmodule Nervezynq.HPStream do
  @moduledoc "HP0 DMA stream consumer. See file header."

  use GenServer
  import Bitwise
  require Logger

  alias Nervezynq.PortWire

  # --- physical constants (mirror top.ex; both baked in fabric) --------------
  @gpio_base 0xE000_A000
  @gpio_len 0x1000
  @ring_base 0x3FF0_0000
  @ring_size 0x0010_0000

  # Zynq GPIO controller offsets (UG585 ch. 14). Bank 2/3 are the EMIO banks.
  @mask_data_2_lsw 0x10
  @data_2_ro 0x68
  @data_3_ro 0x6C
  @dirm_2 0x284
  @oen_2 0x288

  # EMIO control bits (bank 2)
  @bit_enable 0
  @bit_src 1
  @bit_clear 2

  # One HP0 burst = BURST_LEN 16 beats x 8 B = 128 B.  MEASURED on hp_dma_s1
  # (2026-08-03, Gate A): 50,518 bursts in ~101 ms at DATA_CLK 32 MHz — that
  # is 500k bursts/s, which only squares with the 8 M words/s producer at 16
  # words per burst.  The previous value (64) halved every mb_per_s report
  # and put the tail-read guard half a burst too close to the write pointer.
  @burst_bytes 128
  @seq_mod 16384

  # ---------------------------------------------------------------------------
  # API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Map the GPIO and ring apertures and set EMIO bank-2 directions for the
  three control bits. Idempotent; call once after boot (and after SDR.open,
  which owns the THR_CNT/guard ritual this module deliberately does not
  duplicate).
  """
  def setup do
    ensure_started()
    GenServer.call(__MODULE__, :setup)
  end

  @doc "Full stream status decoded from the EMIO word."
  def status do
    ensure_started()
    GenServer.call(__MODULE__, :status)
  end

  @doc "Producer select. `:radio` streams packed LVDS frames; `:counter` the +1 oracle."
  def select(:radio), do: set_ctrl(@bit_src, 1)
  def select(:counter), do: set_ctrl(@bit_src, 0)

  def enable, do: set_ctrl(@bit_enable, 1)
  def disable, do: set_ctrl(@bit_enable, 0)

  @doc "Pulse the sticky-flag clear bit."
  def clear_flags do
    set_ctrl(@bit_clear, 1)
    set_ctrl(@bit_clear, 0)
  end

  @doc "Current producer position as a byte offset into the ring (64 B granular)."
  def wptr_offset do
    ensure_started()
    GenServer.call(__MODULE__, :wptr_offset)
  end

  @doc "Read `count` 32-bit words at byte `offset` in the ring (no wrap handling)."
  def ring_read(offset, count) do
    ensure_started()
    GenServer.call(__MODULE__, {:ring_read, offset, count}, 30_000)
  end

  # --- decode (mirrors Hw.AD936xFramePacker's word format) --------------------

  def signed12(v) when v >= 2048, do: v - 4096
  def signed12(v), do: v

  @doc "Decode one 64-bit stream word."
  def decode_word(w) do
    %{
      ch1: {signed12(w &&& 0xFFF), signed12(w >>> 12 &&& 0xFFF)},
      ch2: {signed12(w >>> 24 &&& 0xFFF), signed12(w >>> 36 &&& 0xFFF)},
      seq: w >>> 48 &&& 0x3FFF,
      err: w >>> 62 &&& 1
    }
  end

  @doc "Pair the port's 32-bit words (little-endian, low word first) into 64-bit stream words."
  def to_u64([]), do: []
  def to_u64([lo, hi | rest]), do: [hi <<< 32 ||| lo | to_u64(rest)]

  @doc """
  Verify SEQ continuity over a list of decoded 64-bit words. Returns
  `%{n:, holes:, err_flags:, first_seq:, last_seq:}` — `holes` is the number
  of adjacent pairs that are not +1 mod 16384; 0 means gapless.
  """
  def check_seq(u64s) do
    seqs = Enum.map(u64s, &(&1 >>> 48 &&& 0x3FFF))
    errs = Enum.count(u64s, &((&1 >>> 62 &&& 1) == 1))

    holes =
      seqs
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.count(fn [a, b] -> rem(a + 1, @seq_mod) != b end)

    %{
      n: length(seqs),
      holes: holes,
      err_flags: errs,
      first_seq: List.first(seqs),
      last_seq: List.last(seqs)
    }
  end

  @doc """
  Counter-mode continuity. The fabric packs the counter as {~ctr, ctr}
  (32-bit counter, complemented high half — the routing-friendly form the
  top.ex comment always promised). Returns `%{gaps:, bad_words:}`:
  `bad_words` counts words whose high half is not the complement of the
  low (transport corruption), `gaps` counts adjacent pairs whose low
  halves are not +1 mod 2^32 (lost words). Both 0 = gapless and intact.
  """
  def check_counter(u64s) do
    los = Enum.map(u64s, &(&1 &&& 0xFFFF_FFFF))

    bad_words =
      Enum.count(u64s, fn w ->
        bxor(w >>> 32 &&& 0xFFFF_FFFF, w &&& 0xFFFF_FFFF) != 0xFFFF_FFFF
      end)

    gaps =
      los
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.count(fn [a, b] -> band(a + 1, 0xFFFF_FFFF) != b end)

    %{gaps: gaps, bad_words: bad_words}
  end

  # ---------------------------------------------------------------------------
  # Gate 4 — counter-mode transport test (rate + continuity through the FIFO)
  # ---------------------------------------------------------------------------

  @doc """
  Counter mode, sustained rate over `ms`: bursts delta vs wall clock, plus a
  continuity spot-check. CAVEAT: the fabric burst counter is 16-bit, so the
  delta aliases once the window exceeds 65535 bursts — ~130 ms at the 64 MB/s
  radio rate. Keep `ms` at or below 100 for a truthful mb_per_s (measured:
  rate_test(500) reported 53,886 bursts where ~250,000 really happened).

  NOTE: on the hp_dma_s1 fabric BOTH producers live in the DATA_CLK domain
  (that is what made the design routable — see Hw.StreamBRAMFIFO), so the
  counter runs at DATA_CLK/4, the radio word rate, and DATA_CLK must be
  alive: run `SDR.open/1` first. This measures the whole transport at
  radio-realistic load; the V0 free-running-counter measured the bus
  ceiling instead.
  """
  def rate_test(ms \\ 100) do
    setup()
    disable()
    select(:counter)
    clear_flags()
    enable()
    Process.sleep(20)

    s0 = status()
    t0 = System.monotonic_time(:microsecond)
    Process.sleep(ms)
    s1 = status()
    t1 = System.monotonic_time(:microsecond)

    bursts = rem(s1.bursts - s0.bursts + 0x10000, 0x10000)
    mb_s = bursts * @burst_bytes / ((t1 - t0) / 1.0e6) / 1.0e6

    # Freshest 4 KB, ending one burst behind the pointer.
    tail_off = rem(wptr_offset() - 4096 - @burst_bytes + @ring_size, @ring_size)
    {:ok, words} = ring_read(tail_off, div(4096, 4))
    gaps = words |> to_u64() |> check_counter()

    disable()

    %{
      bursts_in_window: bursts,
      mb_per_s: Float.round(mb_s, 1),
      tail_4k_gaps: gaps,
      bresp_errs: s1.bresp_errs,
      overrun_sticky: s1.overrun_sticky,
      wraps_seen: s1.bursts != s0.bursts
    }
  end

  # ---------------------------------------------------------------------------
  # Gapless capture — the beacon-depth mode
  # ---------------------------------------------------------------------------

  @doc """
  Capture `bytes` (≤ ~1 MB minus slack) of GAPLESS radio stream, then stop
  and read it out. The radio must already be up (`SDR.open`, ENSM in RX) or
  the stream produces nothing and this times out.

  Returns `{:ok, %{u64: [...], seq: check, ch1: [...], ch2: [...]}}` with
  `seq.holes == 0` as the gapless proof, or `{:error, reason}`.
  """
  def capture_burst(bytes \\ 262_144, opts \\ []) when bytes <= @ring_size - 65_536 do
    timeout_ms = Keyword.get(opts, :timeout_ms, 2_000)
    decode? = Keyword.get(opts, :decode, true)

    setup()
    disable()
    select(:radio)
    clear_flags()
    start_off = wptr_offset()
    enable()

    case await_bytes(start_off, bytes, timeout_ms) do
      :ok ->
        disable()
        {:ok, words} = ring_read_wrapped(start_off, bytes)
        u64 = to_u64(words)
        seq = check_seq(u64)

        if seq.holes > 0 do
          Logger.warning("HPStream: capture_burst has #{seq.holes} SEQ holes")
        end

        base = %{u64: u64, seq: seq, bytes: bytes, start_off: start_off}

        if decode? do
          d = Enum.map(u64, &decode_word/1)
          {:ok, Map.merge(base, %{ch1: Enum.map(d, & &1.ch1), ch2: Enum.map(d, & &1.ch2)})}
        else
          {:ok, base}
        end

      err ->
        disable()
        err
    end
  end

  defp await_bytes(start_off, bytes, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_bytes_loop(start_off, bytes, 0, start_off, deadline)
  end

  defp await_bytes_loop(start_off, bytes, acc, last_off, deadline) do
    cond do
      acc >= bytes ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        {:error, {:stream_stalled, acc, bytes}}

      true ->
        off = wptr_offset()
        step = rem(off - last_off + @ring_size, @ring_size)
        await_bytes_loop(start_off, bytes, acc + step, off, deadline)
    end
  end

  # ---------------------------------------------------------------------------
  # Continuous decimated stream — the waterfall feed
  # ---------------------------------------------------------------------------

  @doc """
  Start a consumer loop delivering the newest ring window each poll.

  `dest` is a pid (receives `{:hp_stream, meta, payload}`) or a 1-arity fun.
  Options:

    * `:source`   — `:radio` (default) or `:counter`
    * `:poll_ms`  — delay between polls (default 50)
    * `:bytes`    — window per poll (default 8192 = 1024 frames)
    * `:mode`     — `:decoded` (default: payload `%{ch1:, ch2:}`) or `:raw`
      (payload is the list of 64-bit words)

  Meta per delivery: `seq` check for the window, `lapped?` (producer wrapped
  past us since last poll — expected at radio rates), stream status flags.
  """
  def stream_rx(dest, opts \\ []) do
    setup()
    stop_stream()

    pid = spawn(fn -> stream_loop(dest, stream_opts(opts), nil) end)
    Process.register(pid, __MODULE__.Stream)
    {:ok, pid}
  end

  def stop_stream do
    case Process.whereis(__MODULE__.Stream) do
      nil ->
        :ok

      pid ->
        Process.exit(pid, :kill)
        disable()
        :ok
    end
  end

  defp stream_opts(opts) do
    %{
      source: Keyword.get(opts, :source, :radio),
      poll_ms: Keyword.get(opts, :poll_ms, 50),
      bytes: Keyword.get(opts, :bytes, 8192),
      mode: Keyword.get(opts, :mode, :decoded)
    }
  end

  defp stream_loop(dest, o, last_off) do
    if last_off == nil do
      disable()
      select(o.source)
      clear_flags()
      enable()
    end

    Process.sleep(o.poll_ms)

    off = wptr_offset()
    moved = if last_off, do: rem(off - last_off + @ring_size, @ring_size), else: 0
    lapped? = last_off != nil and moved >= @ring_size - 2 * o.bytes

    # Newest complete window, ending one burst behind the producer.
    win_end = rem(off - @burst_bytes + @ring_size, @ring_size)
    win_start = rem(win_end - o.bytes + @ring_size, @ring_size)

    case ring_read_wrapped_safe(win_start, o.bytes) do
      {:ok, words} ->
        u64 = to_u64(words)
        st = status()

        meta = %{
          seq: check_seq(u64),
          lapped?: lapped?,
          moved_bytes: moved,
          overrun_sticky: st.overrun_sticky,
          sync_lost: st.sync_lost,
          bresp_errs: st.bresp_errs,
          ts: System.monotonic_time(:millisecond)
        }

        payload =
          case o.mode do
            :raw ->
              u64

            :decoded ->
              d = Enum.map(u64, &decode_word/1)
              %{ch1: Enum.map(d, & &1.ch1), ch2: Enum.map(d, & &1.ch2)}
          end

        deliver(dest, {:hp_stream, meta, payload})

      {:error, reason} ->
        Logger.warning("HPStream: ring read failed: #{inspect(reason)}")
        Process.sleep(500)
    end

    stream_loop(dest, o, off)
  end

  defp deliver(fun, msg) when is_function(fun, 1), do: fun.(msg)
  defp deliver(pid, msg) when is_pid(pid), do: send(pid, msg)

  defp ring_read_wrapped_safe(offset, bytes) do
    {:ok, ring_read_wrapped!(offset, bytes)}
  rescue
    e -> {:error, e}
  catch
    :exit, r -> {:error, r}
  end

  defp ring_read_wrapped(offset, bytes), do: {:ok, ring_read_wrapped!(offset, bytes)}

  defp ring_read_wrapped!(offset, bytes) do
    first = min(bytes, @ring_size - offset)
    {:ok, a} = ring_read(offset, div(first, 4))

    if first == bytes do
      a
    else
      {:ok, b} = ring_read(0, div(bytes - first, 4))
      a ++ b
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer: owns the two port mappings, serialises access
  # ---------------------------------------------------------------------------

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        case start_link() do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end

      _ ->
        :ok
    end
  end

  defp set_ctrl(bit, val) do
    ensure_started()
    GenServer.call(__MODULE__, {:set_ctrl, bit, val})
  end

  @impl true
  def init(_opts) do
    {:ok, gpio} = PortWire.open(@gpio_base, @gpio_len)
    {:ok, ring} = PortWire.open(@ring_base, @ring_size)
    {:ok, %{gpio: gpio, ring: ring, shadow: 0}}
  end

  @impl true
  def handle_call(:setup, _from, st) do
    # Bank-2 bits 0..2 as outputs: DIRM then OEN, read-modify-write so any
    # other EMIO outputs someone configures later survive us.
    {:ok, dirm} = PortWire.transact(st.gpio, {:read32, @dirm_2})
    :ok = PortWire.transact(st.gpio, {:write32, @dirm_2, dirm ||| 0b111})
    {:ok, oen} = PortWire.transact(st.gpio, {:read32, @oen_2})
    :ok = PortWire.transact(st.gpio, {:write32, @oen_2, oen ||| 0b111})
    {:reply, :ok, st}
  end

  def handle_call({:set_ctrl, bit, val}, _from, st) do
    shadow = (st.shadow &&& bnot(1 <<< bit)) ||| val <<< bit
    # MASK_DATA_2_LSW: [31:16] mask (1 = leave alone), [15:0] data.
    word = 0xFFF8 <<< 16 ||| (shadow &&& 0x7)
    :ok = PortWire.transact(st.gpio, {:write32, @mask_data_2_lsw, word})
    {:reply, :ok, %{st | shadow: shadow}}
  end

  def handle_call(:wptr_offset, _from, st) do
    {:ok, b2} = PortWire.transact(st.gpio, {:read32, @data_2_ro})
    {:reply, (b2 >>> 16 &&& 0xFFFF) <<< 4, st}
  end

  def handle_call(:status, _from, st) do
    {:ok, b2} = PortWire.transact(st.gpio, {:read32, @data_2_ro})
    {:ok, b3} = PortWire.transact(st.gpio, {:read32, @data_3_ro})

    {:reply,
     %{
       bursts: b2 &&& 0xFFFF,
       wptr_offset: (b2 >>> 16 &&& 0xFFFF) <<< 4,
       bresp_errs: b3 &&& 0xFF,
       heartbeat_bit: b3 >>> 8 &&& 1,
       alive: (b3 >>> 9 &&& 1) == 1,
       smoke_ok: (b3 >>> 10 &&& 1) == 1 and (b3 >>> 11 &&& 1) == 0,
       wacount: b3 >>> 12 &&& 0x3F,
       wcount: b3 >>> 18 &&& 0xFF,
       overrun_count: b3 >>> 26 &&& 0x7,
       overrun_sticky: (b3 >>> 29 &&& 1) == 1,
       sync_lost: (b3 >>> 30 &&& 1) == 1,
       src_radio?: (b3 >>> 31 &&& 1) == 1,
       ctrl_shadow: st.shadow
     }, st}
  end

  def handle_call({:ring_read, offset, count}, _from, st)
      when offset >= 0 and offset + count * 4 <= @ring_size do
    # PortWire read_block: count is 16-bit words per call; chunk large reads.
    words =
      Stream.unfold({offset, count}, fn
        {_off, 0} ->
          nil

        {off, left} ->
          n = min(left, 16_384)
          {:ok, ws} = PortWire.transact(st.ring, {:read_block, off, n}, 15_000)
          {ws, {off + n * 4, left - n}}
      end)
      |> Enum.to_list()
      |> List.flatten()

    {:reply, {:ok, words}, st}
  end

  @impl true
  def handle_info({port, {:exit_status, s}}, %{gpio: g, ring: r} = st)
      when port == g or port == r do
    {:stop, {:port_exited, s}, st}
  end

  def handle_info(_msg, st), do: {:noreply, st}
end
