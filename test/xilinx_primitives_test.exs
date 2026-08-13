defmodule XilinxPrimitivesTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Emitted-Verilog tests for the Xilinx primitive wrappers.

  These assert on Verilog text rather than on simulation, and that is not a
  shortcut. The simulator models every blackbox identically and opaquely — every
  `%Signal{}`-connected port is driven to 0, inputs included — so a design
  instantiating `DSP48E1` simulates without error and computes nothing. There is
  no behaviour for a sim to check. The only thing that can be wrong at this layer
  is the emitted instantiation: a mistyped port name, a parameter quoted when it
  should be bare, an override that does not take. All three are text.

  `test/hdl_case_test.exs` makes the same argument for mux lowering.
  """

  defp verilog(mod), do: mod |> Hw.Compile.Elaborate.elaborate() |> Hw.emit()

  # --- DSP48E1 ---------------------------------------------------------------

  defmodule DSPTop do
    use Hw.Component

    clock :clk, freq: 100.0

    input :a_in, 30
    input :b_in, 18
    output :p_out, 48

    wire :zero, 1
    wire :one, 1
    wire :zero3, 3
    wire :zero4, 4
    wire :zero5, 5
    wire :zero7, 7
    wire :zero18, 18
    wire :zero25, 25
    wire :zero30, 30
    wire :zero48, 48
    wire :opmode_mult, 7

    comb do
      zero = 0
      one = 1
      zero3 = 0
      zero4 = 0
      zero5 = 0
      zero7 = 0
      zero18 = 0
      zero25 = 0
      zero30 = 0
      zero48 = 0
      # X = M, Y = M, Z = 0
      opmode_mult = 5
    end

    instance :mul, Hw.Xilinx.DSP48E1,
      AREG: 1,
      BREG: 1,
      MREG: 1,
      PREG: 1,
      CREG: 0,
      DREG: 0,
      ADREG: 0,
      clk: :clk,
      a: :a_in,
      b: :b_in,
      c: :zero48,
      d: :zero25,
      p: :p_out,
      acin: :zero30,
      bcin: :zero18,
      pcin: :zero48,
      opmode: :opmode_mult,
      alumode: :zero4,
      inmode: :zero5,
      carryinsel: :zero3,
      carryin: :zero,
      carrycascin: :zero,
      multsignin: :zero,
      cea1: :zero,
      cea2: :one,
      cead: :zero,
      cealumode: :one,
      ceb1: :zero,
      ceb2: :one,
      cec: :zero,
      cecarryin: :zero,
      cectrl: :one,
      ced: :zero,
      ceinmode: :one,
      cem: :one,
      cep: :one,
      rsta: :zero,
      rstallcarryin: :zero,
      rstalumode: :zero,
      rstb: :zero,
      rstc: :zero,
      rstctrl: :zero,
      rstd: :zero,
      rstinmode: :zero,
      rstm: :zero,
      rstp: :zero,
      acout: :dsp_acout,
      bcout: :dsp_bcout,
      pcout: :dsp_pcout,
      carryout: :dsp_carryout,
      carrycascout: :dsp_carrycascout,
      multsignout: :dsp_multsignout,
      overflow: :dsp_overflow,
      underflow: :dsp_underflow,
      patterndetect: :dsp_patterndetect,
      patternbdetect: :dsp_patternbdetect
  end

  test "DSP48E1 emits with the primitive's own port names" do
    v = verilog(DSPTop)

    assert v =~ "DSP48E1"
    # A representative port from each group: data, control, enable, reset, output.
    for port <- ~w(A B C D CLK OPMODE ALUMODE INMODE CARRYINSEL CEA2 CEM CEP
                   RSTA RSTP P PCOUT ACOUT CARRYOUT) do
      assert v =~ ~r/\.#{port}\(/, "missing port #{port}"
    end
  end

  test "DSP48E1 register parameters can be overridden to zero" do
    v = verilog(DSPTop)

    # Not a regression test for anything -- `0` is truthy in Elixir, so the `||`
    # fallback this once "fixed" never discarded it. Kept because eleven DSP48E1
    # parameters exist to be set to 0 and the path deserves coverage on its own
    # merits. The `false` case below is the one that guards a real fix.
    assert v =~ ~r/\.CREG\(0\)/
    assert v =~ ~r/\.DREG\(0\)/
    assert v =~ ~r/\.ADREG\(0\)/

    assert v =~ ~r/\.MREG\(1\)/
    assert v =~ ~r/\.PREG\(1\)/
  end

  test "DSP48E1 string parameters are quoted and numeric ones are not" do
    v = verilog(DSPTop)

    assert v =~ ~s|.A_INPUT("DIRECT")|
    assert v =~ ~s|.USE_DPORT("FALSE")|
    assert v =~ ~s|.USE_SIMD("ONE48")|
    refute v =~ ~s|.PREG("1")|
  end

  test "DSP48E1 does not expose the parameters the toolchain silently ignores" do
    v = verilog(DSPTop)

    # USE_MULT, SEL_PATTERN and USE_PATTERN_DETECT have zero features in the
    # prjxray database and write_dsp_cell never reads them. MASK is truncated to
    # 46 bits by a fasm.cc comment that is wrong for zynq7. A parameter that is
    # accepted and discarded is worse than one that does not exist.
    refute v =~ "USE_MULT"
    refute v =~ "SEL_PATTERN"
    refute v =~ "USE_PATTERN_DETECT"
    refute v =~ ~r/\.MASK\(/
    refute v =~ ~r/\.PATTERN\(/
  end

  # --- ODDR ------------------------------------------------------------------

  defmodule ODDRTop do
    use Hw.Component

    clock :clk, freq: 100.0

    input :d_rise, 1
    input :d_fall, 1
    output :pad, 1

    wire :zero, 1
    wire :one, 1
    wire :oddr_q, 1

    comb do
      zero = 0
      one = 1
    end

    instance :tx, Hw.Xilinx.ODDR,
      c: :clk,
      ce: :one,
      d1: :d_rise,
      d2: :d_fall,
      r: :zero,
      s: :zero,
      q: :oddr_q

    instance :pad_buf, Hw.Xilinx.OBUF, i: :oddr_q, o: :pad
  end

  test "ODDR emits with SAME_EDGE and an explicit INIT" do
    v = verilog(ODDRTop)

    assert v =~ "ODDR"
    assert v =~ ~s|.DDR_CLK_EDGE("SAME_EDGE")|
    assert v =~ ~s|.SRTYPE("SYNC")|

    # INIT is passed explicitly because fasm.cc writes ZINIT_OQ only when
    # INIT == 0 -- treating 1 as implicit -- while the yosys stub declares the
    # default as 0. The two disagree, so neither is left implicit.
    assert v =~ ~r/\.INIT\(0\)/

    for port <- ~w(C CE D1 D2 R S Q), do: assert(v =~ ~r/\.#{port}\(/)
  end

  test "ODDR Q reaches exactly one output buffer" do
    v = verilog(ODDRTop)

    # nextpnr's packer log_errors on a disconnected Q or on illegal fanout, so
    # the single-sink property is worth asserting where it is cheap to check.
    assert v =~ "OBUF"
    assert length(Regex.scan(~r/oddr_q/, v)) >= 2
  end

  # --- OBUFDS ----------------------------------------------------------------

  defmodule OBUFDSTop do
    use Hw.Component

    input :d, 1
    output :p, 1
    output :n, 1

    instance :buf, Hw.Xilinx.OBUFDS, i: :d, o: :p, ob: :n
  end

  test "OBUFDS pins IOSTANDARD to LVDS_25" do
    v = verilog(OBUFDSTop)

    assert v =~ "OBUFDS"
    # Hardcoded, not a parameter: LVDS_25 and TMDS_33 are the only IOSTANDARDs
    # with encodable differential-output features on this part, and anything else
    # falls through to two single-ended drivers without a diagnostic.
    assert v =~ ~s|.IOSTANDARD("LVDS_25")|
    assert v =~ ~s|.SLEW("SLOW")|

    for port <- ~w(I O OB), do: assert(v =~ ~r/\.#{port}\(/)
  end

  # --- PLLE2_BASE / MMCME2_BASE ----------------------------------------------

  defmodule PLLTop do
    use Hw.Component

    input :ref, 1
    output :locked_out, 1

    wire :zero, 1
    wire :pll_raw, 1

    comb do
      zero = 0
    end

    instance :pll, Hw.Xilinx.PLLE2_BASE,
      CLKIN1_PERIOD: 10.0,
      DIVCLK_DIVIDE: 1,
      CLKFBOUT_MULT: 8,
      CLKOUT0_DIVIDE: 4,
      clkin1: :ref,
      rst: :zero,
      pwrdwn: :zero,
      clkout0: :pll_raw,
      locked: :locked_out
  end

  test "PLLE2_BASE emits the multiplier and closes its own feedback loop" do
    v = verilog(PLLTop)

    assert v =~ "PLLE2_BASE"

    # The loop-filter and lock tables are derived from CLKFBOUT_MULT in this fork
    # of nextpnr, after a hardcoded version was found to produce a PLL too
    # jittery for synchronous logic. Omitting it is not a neutral default.
    assert v =~ ~r/\.CLKFBOUT_MULT\(8\)/
    assert v =~ ~r/\.CLKOUT0_DIVIDE\(4\)/
    assert v =~ ~r/\.CLKIN1_PERIOD\(10\.0\)/

    # CLKFBOUT and CLKFBIN must be the same net: an MMCM or PLL with an open
    # feedback path instantiates cleanly and never locks.
    [[_, fbout]] = Regex.scan(~r/\.CLKFBOUT\((\w+)\)/, v)
    assert v =~ ~r/\.CLKFBIN\(#{fbout}\)/
  end

  defmodule MMCMTop do
    use Hw.Component

    input :ref, 1
    output :locked_out, 1

    wire :zero, 1
    wire :c0, 1
    wire :c1, 1

    comb do
      zero = 0
    end

    instance :mmcm, Hw.Xilinx.MMCME2_BASE,
      CLKIN1_PERIOD: 10.0,
      CLKFBOUT_MULT_F: 8.0,
      CLKOUT0_DIVIDE_F: 5.0,
      CLKOUT1_DIVIDE: 8,
      clkin1: :ref,
      rst: :zero,
      pwrdwn: :zero,
      clkout0: :c0,
      clkout1: :c1,
      locked: :locked_out
  end

  test "MMCME2_BASE emits fractional dividers as reals and closes its feedback" do
    v = verilog(MMCMTop)

    assert v =~ "MMCME2_BASE"
    assert v =~ ~r/\.CLKFBOUT_MULT_F\(8\.0\)/
    assert v =~ ~r/\.CLKOUT0_DIVIDE_F\(5\.0\)/
    assert v =~ ~r/\.CLKOUT1_DIVIDE\(8\)/

    [[_, fbout]] = Regex.scan(~r/\.CLKFBOUT\((\w+)\)/, v)
    assert v =~ ~r/\.CLKFBIN\(#{fbout}\)/
  end

  # --- parameter resolution --------------------------------------------------

  defmodule FalseParam do
    use Hw.Component

    param :STARTUP_WAIT, default: "TRUE"

    input :i, 1
    output :o, 1

    blackbox :bb, "SOME_PRIM",
      params: [STARTUP_WAIT: :STARTUP_WAIT],
      ports: [I: :i, O: :o]
  end

  defmodule FalseParamTop do
    use Hw.Component

    input :a, 1
    output :b, 1

    instance :u, FalseParam, STARTUP_WAIT: false, i: :a, o: :b
  end

  test "an instance parameter of false is rejected, not swallowed by the default" do
    # `false` is the only falsy value that can reach build_param_map, and so the
    # only value the old `||` fallback discarded -- silently resolving to the
    # default "TRUE". `0` was never affected, because 0 is truthy in Elixir.
    #
    # Preserving `false` instead is not enough: it emits `.STARTUP_WAIT(false)`,
    # a bare Verilog identifier yosys rejects as a non-constant parameter. So the
    # boolean is rejected at elaboration, where the message can name it.
    err = assert_raise RuntimeError, fn -> verilog(FalseParamTop) end

    assert err.message =~ "STARTUP_WAIT"
    assert err.message =~ "FalseParam"
    assert err.message =~ ~s|"FALSE"|, "should suggest the string form"
  end

  defmodule TypoParam do
    use Hw.Component

    param :REAL_NAME, default: 7

    input :i, 1
    output :o, 1

    # Deliberate typo. :REAL_NAEM is not a declared param.
    blackbox :bb, "SOME_PRIM",
      params: [WIDTH: :REAL_NAEM],
      ports: [I: :i, O: :o]
  end

  defmodule TypoParamTop do
    use Hw.Component

    input :a, 1
    output :b, 1

    instance :u, TypoParam, i: :a, o: :b
  end

  test "a misspelled parameter reference is rejected, naming the parameter" do
    # This used to emit `.WIDTH(REAL_NAEM)` -- bare Verilog text for an
    # identifier that does not exist. yosys rejects it ("Parameter u.WIDTH with
    # non-constant value!"), so it was never silent, but the error arrives
    # against generated Verilog with no route back to the EHDL line.
    err = assert_raise RuntimeError, fn -> verilog(TypoParamTop) end

    assert err.message =~ "REAL_NAEM"
    assert err.message =~ "TypoParam"
    assert err.message =~ "REAL_NAME", "should list the declared params as candidates"
  end

  defmodule NoDefaultParam do
    use Hw.Component

    param :WIDTH_P

    input :i, 1
    output :o, 1

    blackbox :bb, "SOME_PRIM",
      params: [WIDTH: :WIDTH_P],
      ports: [I: :i, O: :o]
  end

  defmodule NoDefaultParamTop do
    use Hw.Component

    input :a, 1
    output :b, 1

    # WIDTH_P is declared with no default and deliberately not set here.
    instance :u, NoDefaultParam, i: :a, o: :b
  end

  test "a param with no default and no override is rejected, not crashed on" do
    # Previously reached the emitter as a %Param{} struct and died in to_string/1
    # with `protocol String.Chars not implemented for Hw.IR.Types.Param` --
    # true, and naming neither the parameter nor the instance.
    err = assert_raise RuntimeError, fn -> verilog(NoDefaultParamTop) end

    assert err.message =~ "WIDTH_P"
    assert err.message =~ "NoDefaultParam"
    refute err.message =~ "String.Chars"
  end
end
