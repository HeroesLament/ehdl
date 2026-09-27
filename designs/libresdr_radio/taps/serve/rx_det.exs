# Nervezynq.RxDet: the fabric L-STF detector (ehdl Hw.StfDetector in
# LibreSDRRadio.Top, det_s30.bin). EMIO bank 2:
#   [12] EMIO status mux: 0 = DMA status (HPStream's view), 1 = detector
#   [13] detector enable (also runs the packer without the RX DMA)
#   [23:16] energy gate code: emin = code << 6 (R units: 32 x mean |y|^2, 12-bit LSBs)
# Detector view of the EMIO input word (banks 2/3 DATA_RO):
#   [63:48] det_count  [47:24] det_pr[31:8]  [23:0] det_pi[31:8]
# Values cross from DATA_CLK asynchronously: reads are repeated until two agree.
#
#   Code.compile_file("/data/rx_det.exs")
#   Nervezynq.RxDet.start(20)        # gate code, then enable
#   Nervezynq.RxDet.read()           # %{count, pr, pi, cfo_hz}
#   Nervezynq.RxDet.rate(1000)       # detections per second over 1 s
#   Nervezynq.RxDet.stop()

defmodule Nervezynq.RxDet do
  import Bitwise
  alias Nervezynq.PortWire

  @gpio_base 0xE000_A000
  @mask_data_2_lsw 0x10
  @mask_data_2_msw 0x14
  @data_ro_2 0x68
  @data_ro_3 0x6C
  @dirm_2 0x284
  @oen_2 0x288
  @bits 0x00FF_3000
  @fs 8_000_000

  defp gpio do
    case Process.get(:rx_det_gpio) do
      nil ->
        {:ok, g} = PortWire.open(@gpio_base, 0x1000)
        {:ok, d} = PortWire.transact(g, {:read32, @dirm_2})
        :ok = PortWire.transact(g, {:write32, @dirm_2, d ||| @bits})
        {:ok, o} = PortWire.transact(g, {:read32, @oen_2})
        :ok = PortWire.transact(g, {:write32, @oen_2, o ||| @bits})
        Process.put(:rx_det_gpio, g)
        g

      g ->
        g
    end
  end

  # Bits 12, 13 (low half, mask keeps the rest) and 23:16 (high half).
  defp set_lo(sel, en) do
    v = sel <<< 12 ||| en <<< 13
    :ok = PortWire.transact(gpio(), {:write32, @mask_data_2_lsw, (0xFFFF &&& bnot(0x3000)) <<< 16 ||| v})
  end

  defp set_gate(code) when code in 0..255 do
    :ok = PortWire.transact(gpio(), {:write32, @mask_data_2_msw, (0xFFFF &&& bnot(0x00FF)) <<< 16 ||| code})
  end

  @doc "Set the gate (code << 6), then enable. The detector blanks its first 1023 samples."
  def start(code \\ 20) do
    set_lo(0, 0)
    set_gate(code)
    set_lo(0, 1)
    :ok
  end

  def stop, do: set_lo(0, 0)

  defp raw do
    g = gpio()
    {:ok, lo} = PortWire.transact(g, {:read32, @data_ro_2})
    {:ok, hi} = PortWire.transact(g, {:read32, @data_ro_3})
    hi <<< 32 ||| lo
  end

  @doc "Detector snapshot (status mux switched to the detector for the read, then back)."
  def read do
    {:ok, en} = PortWire.transact(gpio(), {:read32, 0x48})
    en_bit = en >>> 13 &&& 1
    set_lo(1, en_bit)
    w = stable_read(5)
    set_lo(0, en_bit)
    s24 = fn v -> if v >= 1 <<< 23, do: v - (1 <<< 24), else: v end
    pr = s24.(w >>> 24 &&& 0xFF_FFFF)
    pi = s24.(w &&& 0xFF_FFFF)
    %{count: w >>> 48 &&& 0xFFFF, pr: pr, pi: pi, cfo_hz: :math.atan2(pi, pr) / (2 * :math.pi() * 16) * @fs}
  end

  defp stable_read(0), do: raw()

  defp stable_read(n) do
    a = raw()
    b = raw()
    if a == b, do: a, else: stable_read(n - 1)
  end

  @doc "Detections per second over `ms`, plus the last detection's coarse CFO."
  def rate(ms \\ 1000) do
    a = read()
    Process.sleep(ms)
    b = read()
    n = rem(b.count - a.count + 65_536, 65_536)
    %{detections: n, per_s: n * 1000 / ms, last_cfo_hz: Float.round(b.cfo_hz, 0), count: b.count}
  end
end
