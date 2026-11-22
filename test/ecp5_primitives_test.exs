defmodule ECP5PrimitivesTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Emitted-Verilog tests for the ECP5 primitive wrappers (`Hw.ECP5.*`), the
  board PLL built on them, the `tristate` lowering, and the Xilinx additions
  and renames that came with them. Text assertions, for the reason given in
  `test/xilinx_primitives_test.exs`: the simulator models blackboxes as
  opaque, so the emitted instantiation is the only thing to check.
  """

  defp verilog(mod), do: mod |> Hw.Compile.Elaborate.elaborate() |> Hw.emit()

  # --- EHXPLLL ---------------------------------------------------------------

  defmodule RawPLLTop do
    use Hw.Component

    input :ref, 1
    output :clk_a, 1
    output :clk_b, 1
    output :locked_out, 1

    wire :zero, 1

    comb do
      zero = 0
    end

    instance :pll, Hw.ECP5.EHXPLLL,
      CLKI_DIV: 1,
      CLKFB_DIV: 4,
      CLKOP_DIV: 6,
      CLKOP_CPHASE: 5,
      CLKOS_DIV: 12,
      CLKOS_CPHASE: 11,
      CLKOS_ENABLE: "ENABLED",
      LPF_RESISTOR: "16",
      clki: :ref,
      clkfb: :clk_a,
      clkop: :clk_a,
      clkos: :clk_b,
      lock: :locked_out,
      phasesel1: :zero,
      phasesel0: :zero,
      phasedir: :zero,
      phasestep: :zero,
      phaseloadreg: :zero,
      stdby: :zero,
      pllwakesync: :zero,
      rst: :zero,
      enclkop: :zero,
      enclkos: :zero,
      enclkos2: :zero,
      enclkos3: :zero
  end

  test "EHXPLLL emits its dividers bare and its enums quoted" do
    v = verilog(RawPLLTop)

    assert v =~ "EHXPLLL"
    assert v =~ ~r/\.CLKI_DIV\(1\)/
    assert v =~ ~r/\.CLKFB_DIV\(4\)/
    assert v =~ ~r/\.CLKOP_DIV\(6\)/
    assert v =~ ~r/\.CLKOS_DIV\(12\)/
    assert v =~ ~s|.FEEDBK_PATH("CLKOP")|
    assert v =~ ~s|.CLKOS_ENABLE("ENABLED")|
    # Unused outputs keep the primitive's own (yosys) default.
    assert v =~ ~s|.CLKOS2_ENABLE("DISABLED")|
    assert v =~ ~s|.INT_LOCK_STICKY("ENABLED")|
    refute v =~ ~s|.CLKOP_DIV("6")|
  end

  test "EHXPLLL loop-filter settings are attributes, defaults and overrides both" do
    v = verilog(RawPLLTop)

    # Attributes, not parameters: nextpnr reads them from the cell's attrs.
    assert v =~ ~s|(* ICP_CURRENT="12" *)|
    assert v =~ ~s|(* LPF_RESISTOR="16" *)|
    assert v =~ ~s|(* MFG_ENABLE_FILTEROPAMP="1" *)|
    assert v =~ ~s|(* MFG_GMCREF_SEL="2" *)|
    refute v =~ ~r/\.ICP_CURRENT\(/
    refute v =~ ~r/\.LPF_RESISTOR\(/
  end

  test "EHXPLLL feedback is whatever the caller connects to clkfb" do
    v = verilog(RawPLLTop)

    [[_, op]] = Regex.scan(~r/\.CLKOP\((\w+)\)/, v)
    assert v =~ ~r/\.CLKFB\(#{op}\)/
  end

  # --- ULX3S.PLL on top of it ------------------------------------------------

  defmodule BoardPLLTop do
    use Hw.Component

    input :clk_25mhz, 1
    output :led, 1

    wire :zero, 1

    comb do
      zero = 0
    end

    instance :pll, ULX3S.PLL,
      CLKOP_DIV: 9,
      CLKOS_DIV: 2,
      CLKOP_CPHASE: 8,
      CLKOS_CPHASE: 1,
      clk_in: :clk_25mhz,
      clk_out0: :clk_48,
      clk_out1: :clk_fast,
      locked: :led,
      phase_dir: :zero,
      phase_step: :zero
  end

  test "ULX3S.PLL still emits the exact-48 MHz configuration" do
    v = verilog(BoardPLLTop)

    assert length(Regex.scan(~r/\bEHXPLLL\b/, v)) == 1
    assert v =~ ~r/\.CLKI_DIV\(25\)/
    assert v =~ ~r/\.CLKFB_DIV\(48\)/
    # Forwarded through two levels of params.
    assert v =~ ~r/\.CLKOP_DIV\(9\)/
    assert v =~ ~r/\.CLKOS_DIV\(2\)/
    assert v =~ ~r/\.CLKOP_CPHASE\(8\)/
    assert v =~ ~r/\.CLKOS_CPHASE\(1\)/
    assert v =~ ~s|.DPHASE_SOURCE("ENABLED")|
    assert v =~ ~s|.CLKOS_ENABLE("ENABLED")|
    assert v =~ ~s|(* ICP_CURRENT="12" *)|

    [[_, op]] = Regex.scan(~r/\.CLKOP\((\w+)\)/, v)
    assert v =~ ~r/\.CLKFB\(#{op}\)/
  end

  # --- pads ------------------------------------------------------------------

  defmodule TristateTop do
    use Hw.Component

    inout :sda, 1
    input :drive, 1
    input :oe, 1
    output :seen, 1

    tristate :sda_t, io: :sda, output: :drive, enable: :oe, input: :seen
  end

  test "a tristate statement still lowers to one ECP5 BB" do
    v = verilog(TristateTop)

    assert v =~ ~r/\bBB sda_bb \(/
    assert v =~ ~r/\.B\(sda\)/
    # T is active-high release, so the enable is inverted.
    assert v =~ ~r/\.T\(~/
    for port <- ~w(I T B O), do: assert(v =~ ~r/\.#{port}\(/)
  end

  defmodule BBTop do
    use Hw.Component

    inout :pad, 1
    input :d, 1
    input :rel, 1
    output :q, 1

    instance :p, Hw.ECP5.BB, i: :d, t: :rel, o: :q, b: :pad
  end

  test "an instantiated BB takes the pad as its inout" do
    v = verilog(BBTop)

    assert v =~ ~r/\bBB\b/
    for port <- ~w(I T O B), do: assert(v =~ ~r/\.#{port}\(/)
  end

  defmodule LVDSTop do
    use Hw.Component

    input :dp, 1
    input :dn, 1
    output :diff, 1

    instance :rx, Hw.ECP5.ILVDS, a: :dp, an: :dn, z: :diff
  end

  test "the differential input is ILVDS, not the nonexistent LVDS25" do
    v = verilog(LVDSTop)

    assert v =~ ~r/\bILVDS\b/
    refute v =~ "LVDS25"
    for port <- ~w(A AN Z), do: assert(v =~ ~r/\.#{port}\(/)
  end

  defmodule DDRTop do
    use Hw.Component

    input :clk, 1
    input :rx_pad, 1
    input :d_rise, 1
    input :d_fall, 1
    output :tx_pad, 1
    output :q_rise, 1
    output :q_fall, 1

    wire :zero, 1

    comb do
      zero = 0
    end

    instance :rx, Hw.ECP5.IDDRX1F, d: :rx_pad, sclk: :clk, rst: :zero, q0: :q_rise, q1: :q_fall
    instance :tx, Hw.ECP5.ODDRX1F, sclk: :clk, rst: :zero, d0: :d_rise, d1: :d_fall, q: :tx_pad
  end

  test "IDDRX1F and ODDRX1F emit with the primitive port names" do
    v = verilog(DDRTop)

    assert v =~ "IDDRX1F"
    assert v =~ "ODDRX1F"
    assert v =~ ~s|.GSR("ENABLED")|
    for port <- ~w(D SCLK RST Q0 Q1 D0 D1 Q), do: assert(v =~ ~r/\.#{port}\(/)
  end

  # --- Xilinx ----------------------------------------------------------------

  defmodule IOBUFTop do
    use Hw.Component

    inout :pad, 1
    input :d, 1
    input :rel, 1
    output :q, 1

    instance :p, Hw.Xilinx.IOBUF, i: :d, t: :rel, o: :q, io: :pad
  end

  test "Xilinx IOBUF emits with the primitive port names" do
    v = verilog(IOBUFTop)

    assert v =~ ~r/\bIOBUF\b/
    for port <- ~w(I T O IO), do: assert(v =~ ~r/\.#{port}\(/)
  end

  test "the old PS7 names are exact aliases of the Hw.Xilinx ones" do
    for {old, new} <- [
          {Hw.PS7, Hw.Xilinx.PS7},
          {Hw.PS7AXI, Hw.Xilinx.PS7AXI},
          {Hw.PS7HP, Hw.Xilinx.PS7HP}
        ] do
      assert old.__hw_signals__() == new.__hw_signals__()
      assert old.__hw_blackboxes__() == new.__hw_blackboxes__()
      assert old.__hw_params__() == new.__hw_params__()
      assert old.__hw_logic__() == new.__hw_logic__()
    end
  end
end
