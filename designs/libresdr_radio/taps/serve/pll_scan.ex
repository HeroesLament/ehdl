defmodule Nervezynq.PllScan do
  @moduledoc """
  Does PLLE2_BASE, as configured by openXC7, lock on this silicon?

  One bitstream per `CLKFBOUT_MULT`. With a measured 99.99 MHz input and
  `DIVCLK_DIVIDE=1` the VCO runs at MULT x 100 MHz, and PLLE2's VCO range is
  800..1600 MHz, so MULT 8..16 is the whole legal space. Each build sets
  `CLKOUT0_DIVIDE=5`, so a locked PLL should read VCO/5.

  The sweep discriminates two hypotheses that a single failing build cannot:

    * NO mult locks -> CLKIN1 is not receiving the fabric clock at all, and the
      problem is routing, not configuration.
    * SOME mults lock -> the configuration is mult-dependent, and the suspect is
      nextpnr's `write_pll`, which computes `LKTABLE[39:0]` from
      `CLKFBOUT_MULT` (correctly -- verified against the emitted FASM for
      MULT=10) but leaves `TABLE[9:0]` hardcoded at 0x1FC. `TABLE` carries the
      loop-filter setting, which Vivado computes per mult; one fixed value
      cannot be right for all nine.

  STATUS1 bit 24 is LOCKED, synchronised into the AXI domain. STATUS2 is the
  divide-by-512 edge counter, retargeted in this bitstream from DATA_CLK to the
  PLL output, so `mhz/0` reads CLKOUT0 directly.
  """

  import Bitwise
  alias Nervezynq.{PL, Fabric}

  @status1 0x20
  @status2 0x24

  def measure(mult) do
    gz = "/root/pll/mult#{mult}.bin.gz"

    with {:ok, body} <- File.read(gz),
         :ok <- File.write("/root/pllscan.bin", :zlib.gunzip(body)),
         {:ok, _} <- PL.reload("/root/pllscan.bin") do
      # A PLL is allowed time to lock; the datasheet worst case is well under
      # this, and reading LOCKED too early would report a false negative.
      Process.sleep(100)
      {:ok, s1} = Fabric.read32(@status1)
      %{mult: mult, locked: s1 >>> 24 &&& 1, mhz: mhz(), expect_mhz: mult * 100 / 5}
    else
      other -> %{mult: mult, error: other}
    end
  end

  def mhz(ms \\ 100) do
    {:ok, a} = Fabric.read32(@status2)
    t0 = System.monotonic_time(:microsecond)
    Process.sleep(ms)
    {:ok, b} = Fabric.read32(@status2)
    t1 = System.monotonic_time(:microsecond)
    Float.round((b - a) * 512 / (t1 - t0), 2)
  end

  def run(mults \\ [8, 9, 10, 11, 12, 13, 14, 15, 16]) do
    r = Enum.map(mults, &measure/1)
    IO.puts("\n  MULT   VCO(MHz)  LOCKED  measured  expected")
    IO.puts("  ----   --------  ------  --------  --------")

    Enum.each(r, fn
      %{error: e, mult: m} ->
        :io.format("  ~4B   ~8s  ~6s  ~8s  ~8s   ERROR ~s~n", [m, "-", "-", "-", "-", inspect(e)])

      x ->
        :io.format("  ~4B   ~8B  ~6B  ~8.2f  ~8.1f~n", [
          x.mult,
          x.mult * 100,
          x.locked,
          x.mhz * 1.0,
          x.expect_mhz * 1.0
        ])
    end)

    r
  end
end
