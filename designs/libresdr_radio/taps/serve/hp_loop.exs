# Nervezynq.HPLoop: board side of the HP0 loopback gate (TX direction).
#
# Fabric: ehdl designs/libresdr_radio/hp_loop.ex (LibreSDRRadio.HPLoop.Top),
# served as hp_loop_s0.bin. DDR TX ring -> Hw.AXIHPReader -> BRAM FIFO ->
# Hw.AXIHPWriter -> DDR RX ring. Pass = RX ring is a byte-exact copy of what
# this script wrote into the TX ring, error counters 0, burst counts equal.
# Verified first in iverilog (ehdl test/support/verilog/tb_hp_loop.v).
#
#   :inets.start()
#   {:ok, {{_, 200, _}, _, b}} = :httpc.request(:get,
#     {~c"http://<peer>:8101/hp_loop.exs", []}, [], body_format: :binary)
#   File.write!("/data/hp_loop.exs", b)
#   Code.compile_file("/data/hp_loop.exs")
#   Nervezynq.HPLoop.bringup("http://<peer>:8101")   # fetch + PlLoad bracket
#   Nervezynq.HPLoop.smoke()                         # EMIO bits 61..63
#   Nervezynq.HPLoop.once(256)                       # 256 bursts = 32 KB
#   Nervezynq.HPLoop.soak(8704)                      # wraps both 1 MB rings
#
# !! THIS BITSTREAM HAS NO GP0 SLAVE. Do not call Nervezynq.SDR, Fabric, or
# anything that touches 0x4000_0000 while hp_loop is loaded: the access never
# completes and wedges the CPU (power cycle). Everything here is EMIO + DDR.
# Reload hp_dma_s1.bin (LsdrBringup.run) to get the radio back.
#
# EMIO map (mirror of hp_loop.ex's moduledoc):
#   out bank 2 [0] reader enable  [1] writer enable  [2] run (0 = reset)
#   out bank 3 [31:0] head_addr (absolute)
#   in  bank 2 [15:0] reader bursts   [31:16] writer bursts
#   in  bank 3 [15:0] read_ptr[19:4]  [19:16] rresp_errs  [23:20] rlast_errs
#              [27:24] bresp_errs     [28] heartbeat  [29] alive=1  [30]=1  [31]=0

defmodule Nervezynq.HPLoop do
  import Bitwise
  alias Nervezynq.PortWire

  @bitstream "hp_loop_s0.bin"
  @support ~w(silicon_sweep.exs rb_check.exs pl_load.exs)

  @gpio_base 0xE000_A000
  @gpio_len 0x1000
  @tx_base 0x3FD0_0000
  @rx_base 0x3FF0_0000
  @ring 0x0010_0000
  @ring_mask 0x000F_FFFF
  @burst 128

  # Zynq GPIO (UG585 ch. 14). Banks 2/3 are EMIO.
  @mask_data_2_lsw 0x10
  @data_3 0x4C
  @data_2_ro 0x68
  @data_3_ro 0x6C
  @dirm_2 0x284
  @oen_2 0x288
  @dirm_3 0x2C4
  @oen_3 0x2C8

  # --- bring-up -------------------------------------------------------------
  def bringup(host) do
    for f <- @support ++ [@bitstream, "hp_loop.exs"] do
      {:ok, {{_, 200, _}, _, b}} =
        :httpc.request(:get, {~c"#{host}/#{f}", []}, [{:timeout, 30_000}], body_format: :binary)
      File.write!("/data/" <> f, b)
    end

    for f <- @support, do: Code.compile_file("/data/" <> f)
    ensure(SiliconSweep.Devcfg)
    ensure(SiliconSweep.DmaBuf)
    load = PlLoad.load("/data/" <> @bitstream)
    thr = release_fclk()
    r = %{load_ok: load[:ok?], pcfg_done: PlLoad.pcfg_done?(), fclk_throttle: thr}
    IO.puts("HPLOOP BRINGUP " <> inspect(r))
    r
  end

  # FPGA0/1_THR_CNT = 1 halts every PL clock on this firmware while the
  # divisor registers still read as configured (2026-08-02, HPDMA_SESSION.md).
  # Same idempotent release SDR.open/1 performs; SLCR only, never GP0.
  @thr_cnt [0x178, 0x188]
  def release_fclk do
    case Process.whereis(Nervezynq.SLCR) do
      nil -> {:ok, _} = Nervezynq.SLCR.start_link()
      _ -> :ok
    end

    before = for off <- @thr_cnt, do: elem(Nervezynq.SLCR.read32(off), 1)

    if Enum.any?(before, &(&1 != 0)) do
      Nervezynq.SLCR.unlock()
      Enum.each(@thr_cnt, &Nervezynq.SLCR.write32(&1, 0))
      Nervezynq.SLCR.lock()
    end

    %{thr_cnt_before: before, thr_cnt_after: for(off <- @thr_cnt, do: elem(Nervezynq.SLCR.read32(off), 1))}
  end

  defp ensure(mod) do
    case Process.whereis(mod) do
      nil -> {:ok, _} = mod.start_link()
      pid -> {:ok, pid}
    end
  end

  # --- ports ------------------------------------------------------------------
  defp ports do
    case Process.get(:hp_loop_ports) do
      nil ->
        {:ok, gpio} = PortWire.open(@gpio_base, @gpio_len)
        {:ok, tx} = PortWire.open(@tx_base, @ring)
        {:ok, rx} = PortWire.open(@rx_base, @ring)
        p = %{gpio: gpio, tx: tx, rx: rx}
        Process.put(:hp_loop_ports, p)
        setup_dirs(gpio)
        p

      p ->
        p
    end
  end

  defp setup_dirs(g) do
    {:ok, d2} = PortWire.transact(g, {:read32, @dirm_2})
    :ok = PortWire.transact(g, {:write32, @dirm_2, d2 ||| 0b111})
    {:ok, o2} = PortWire.transact(g, {:read32, @oen_2})
    :ok = PortWire.transact(g, {:write32, @oen_2, o2 ||| 0b111})
    :ok = PortWire.transact(g, {:write32, @dirm_3, 0xFFFF_FFFF})
    :ok = PortWire.transact(g, {:write32, @oen_3, 0xFFFF_FFFF})
  end

  defp ctrl(bits) do
    %{gpio: g} = ports()
    :ok = PortWire.transact(g, {:write32, @mask_data_2_lsw, 0xFFF8 <<< 16 ||| (bits &&& 7)})
  end

  # DATA_3 is one 32-bit write: all head bits change on the same APB cycle.
  defp head(addr) do
    %{gpio: g} = ports()
    :ok = PortWire.transact(g, {:write32, @data_3, addr})
  end

  def status do
    %{gpio: g} = ports()
    {:ok, b2} = PortWire.transact(g, {:read32, @data_2_ro})
    {:ok, b3} = PortWire.transact(g, {:read32, @data_3_ro})

    %{
      rd_bursts: b2 &&& 0xFFFF,
      wr_bursts: b2 >>> 16 &&& 0xFFFF,
      read_ptr_off: (b3 &&& 0xFFFF) <<< 4,
      rresp_errs: b3 >>> 16 &&& 0xF,
      rlast_errs: b3 >>> 20 &&& 0xF,
      bresp_errs: b3 >>> 24 &&& 0xF,
      heartbeat: b3 >>> 28 &&& 1,
      smoke_ok: (b3 >>> 29 &&& 7) == 0b011
    }
  end

  @doc "EMIO read path proof: alive=1, one=1, zero=0, heartbeat toggling."
  def smoke do
    hbs = for _ <- 1..8, do: (Process.sleep(60); status().heartbeat)
    s = status()
    r = %{smoke_ok: s.smoke_ok, heartbeat_toggles: length(Enum.dedup(hbs)) > 1, status: s}
    IO.puts("HPLOOP SMOKE " <> inspect(r))
    r
  end

  # --- data -------------------------------------------------------------------
  # Word i as two little-endian u32s at byte offset 8i: lo = i, hi = ~i ^ salt.
  defp pat(i, salt), do: {i &&& 0xFFFF_FFFF, bxor(bnot(i) &&& 0xFFFF_FFFF, salt)}

  defp write_words(port, first, n, salt) do
    first..(first + n - 1)
    |> Enum.chunk_every(2048)
    |> Enum.each(fn chunk ->
      i0 = hd(chunk)
      off = i0 * 8 &&& @ring_mask
      vals = Enum.flat_map(chunk, fn i -> Tuple.to_list(pat(i, salt)) end)
      # chunks never straddle the ring end: 2048 words = 16 KB divides 1 MB
      :ok = PortWire.transact(port, {:write_block, off, vals}, 15_000)
    end)
  end

  defp read_words(port, first, n) do
    first..(first + n - 1)
    |> Enum.chunk_every(2048)
    |> Enum.flat_map(fn chunk ->
      off = hd(chunk) * 8 &&& @ring_mask
      {:ok, ws} = PortWire.transact(port, {:read_block, off, length(chunk) * 2}, 15_000)
      Enum.chunk_every(ws, 2) |> Enum.map(&List.to_tuple/1)
    end)
  end

  defp fill_rx(n_words) do
    %{rx: rx} = ports()
    vals = List.duplicate(0xDEAD_BEEF, 4096)
    for off <- 0..(min(n_words * 8, @ring) - 1)//16_384 do
      :ok = PortWire.transact(rx, {:write_block, off, vals}, 15_000)
    end
    :ok
  end

  defp wait_writer(target, timeout_ms) do
    t0 = System.monotonic_time(:millisecond)
    Stream.repeatedly(fn -> status() end)
    |> Enum.reduce_while(nil, fn s, _ ->
      cond do
        s.wr_bursts == (target &&& 0xFFFF) -> {:halt, {:ok, s}}
        System.monotonic_time(:millisecond) - t0 > timeout_ms -> {:halt, {:timeout, s}}
        true -> {:cont, nil}
      end
    end)
  end

  defp start_clean do
    ctrl(0)
    head(@tx_base)
    Process.sleep(5)
    ctrl(0b100)
  end

  defp stop do
    ctrl(0b100)
    Process.sleep(5)
    ctrl(0)
  end

  @doc "One doorbell of `bursts` x 128 B; verify byte-exact. bursts <= 8191."
  def once(bursts \\ 256, salt \\ 0x5A5A_A5A5) when bursts in 1..8191 do
    %{tx: tx, rx: rx} = ports()
    n = bursts * 16
    fill_rx(n)
    write_words(tx, 0, n, salt)
    start_clean()
    ctrl(0b111)
    t0 = System.monotonic_time(:microsecond)
    head(@tx_base + (bursts * @burst &&& @ring_mask))
    {res, _} = wait_writer(bursts, 3_000)
    dt = System.monotonic_time(:microsecond) - t0
    # Snapshot BEFORE stop/0: dropping `run` resets both engines' counters.
    s = status()
    stop()
    got = read_words(rx, 0, n)
    bad = mismatches(got, 0, salt)
    r = verdict(:once, bursts, res, s, bad, dt)
    IO.puts("HPLOOP ONCE " <> inspect(r))
    r
  end

  @doc "Chunked stream past a full wrap of both rings (default 8704 bursts)."
  def soak(total \\ 8704, chunk \\ 256, salt \\ 0x1234_5678) do
    %{tx: tx, rx: rx} = ports()
    fill_rx(div(@ring, 8))
    start_clean()
    ctrl(0b111)
    t0 = System.monotonic_time(:microsecond)

    {bad, last} =
      Enum.reduce_while(Stream.iterate(0, &(&1 + chunk)), {0, nil}, fn done, {bad, _} ->
        if done >= total do
          {:halt, {bad, :ok}}
        else
          write_words(tx, done * 16, chunk * 16, salt)
          head(@tx_base + ((done + chunk) * @burst &&& @ring_mask))
          case wait_writer(done + chunk, 3_000) do
            {:ok, _s} ->
              got = read_words(rx, done * 16, chunk * 16)
              {:cont, {bad + length(mismatches(got, done * 16, salt)), :ok}}
            {:timeout, s} ->
              {:halt, {bad, {:timeout_at, done, s}}}
          end
        end
      end)

    dt = System.monotonic_time(:microsecond) - t0
    # Snapshot BEFORE stop/0: dropping `run` resets both engines' counters.
    s = status()
    stop()
    r = %{gate: :soak, bursts: total, result: last, bad_words: bad, status: s,
          pass: last == :ok and bad == 0 and s.rd_bursts == (total &&& 0xFFFF) and
                  s.wr_bursts == (total &&& 0xFFFF) and s.rresp_errs == 0 and s.rlast_errs == 0 and s.bresp_errs == 0,
          wall_ms: div(dt, 1000)}
    IO.puts("HPLOOP SOAK " <> inspect(r))
    r
  end

  defp mismatches(got, first, salt) do
    got
    |> Enum.with_index(first)
    |> Enum.reject(fn {w, i} -> w == pat(i, salt) end)
  end

  defp verdict(gate, bursts, res, s, bad, dt_us) do
    %{
      gate: gate,
      bursts: bursts,
      result: res,
      bad_words: length(bad),
      first_bad: Enum.take(bad, 4),
      status: s,
      mb_per_s: if(res == :ok and dt_us > 0, do: Float.round(bursts * @burst / dt_us, 1), else: nil),
      pass: res == :ok and bad == [] and s.rd_bursts == (bursts &&& 0xFFFF) and
              s.rresp_errs == 0 and s.rlast_errs == 0 and s.bresp_errs == 0
    }
  end
end
