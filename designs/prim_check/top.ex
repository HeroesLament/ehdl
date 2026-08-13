defmodule PrimCheck.Top do
  @moduledoc """
  A build-and-encode check for the Xilinx primitive wrappers. **Not for loading.**

  This design does nothing useful. It exists so that `DSP48E1`, `PLLE2_BASE`,
  `ODDR` and `OBUFDS` each get taken through yosys, nextpnr-xilinx and
  `fasm2frames`, and so that the resulting FASM can be checked for the
  configuration features each primitive is supposed to produce.

  That second half is the point. "It builds" is the standard this repo has been
  burned by three times — `DIFF_TERM`, `SAME_EDGE_PIPELINED` and tristate `ODDR`
  all place and route cleanly and then do nothing on silicon, because the bits
  never get written. Grepping the FASM for `DSP48`, `PLLE2_ADV`, `ODDR` and
  `LVDS_25.OUT` is a weak test compared with a measurement, but it is a strictly
  stronger one than a zero exit status, and it catches exactly that failure mode.

  It does **not** establish that any of these works on hardware. Nothing here has
  been on hardware. See the verification tiers in `AGENTS.md`.

  Pins are borrowed from the AD9363 receive bus, which is safe only because this
  bitstream is never loaded: it drives pads the transceiver also drives.

  The DSP operands come from a counter rather than from pads. Thirty plus eighteen
  input bits would be 48 pads to constrain, and a counter is enough to stop
  `opt_clean` folding the multiplier away — which is the only thing the operands
  have to achieve here.
  """

  use Hw.Component

  # The `wire` must come before the `clock`, and without it `clk` becomes a
  # top-level input port rather than an internal net driven by the BUFG --
  # nextpnr then rejects it for having no IOSTANDARD. `libresdr_radio` does the
  # same thing for `axi_clk`.
  wire :clk, 1
  clock :clk, freq: 100.0

  input :clk_pad, 1
  output :p_hi, 1

  input :ref_clk, 1
  output :pll_locked, 1

  input :d_rise, 1
  input :d_fall, 1
  output :ddr_p, 1
  output :ddr_n, 1

  wire :clk_raw, 1
  wire :count, 30, init: 0
  wire :a_in, 30
  wire :b_in, 18

  wire :zero, 1
  wire :one, 1
  wire :zero3, 3
  wire :zero4, 4
  wire :zero5, 5
  wire :zero18, 18
  wire :zero25, 25
  wire :zero30, 30
  wire :zero48, 48
  wire :opmode_mult, 7

  wire :p_full, 48
  wire :pll_out, 1
  wire :oddr_q, 1

  comb do
    zero = 0
    one = 1
    zero3 = 0
    zero4 = 0
    zero5 = 0
    zero18 = 0
    zero25 = 0
    zero30 = 0
    zero48 = 0
    # X = M, Y = M, Z = 0 -- a plain registered multiply.
    opmode_mult = 5

    clk_raw = clk_pad

    a_in = count
    b_in = count[17..0]

    # One bit out so the DSP has an observable sink and survives opt_clean.
    p_hi = p_full[47..47]
  end

  on :clk do
    count = count + 1
  end

  instance :clkbuf, Hw.Xilinx.BUFG, i: :clk_raw, o: :clk

  instance :mul, Hw.Xilinx.DSP48E1,
    CREG: 0,
    DREG: 0,
    ADREG: 0,
    clk: :clk,
    a: :a_in,
    b: :b_in,
    c: :zero48,
    d: :zero25,
    p: :p_full,
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

  instance :pll, Hw.Xilinx.PLLE2_BASE,
    CLKIN1_PERIOD: 10.0,
    DIVCLK_DIVIDE: 1,
    CLKFBOUT_MULT: 8,
    CLKOUT0_DIVIDE: 4,
    clkin1: :ref_clk,
    rst: :zero,
    pwrdwn: :zero,
    clkout0: :pll_out,
    locked: :pll_locked

  # ODDR on the fabric clock, feeding a differential pad pair. Not the PLL
  # output: that would add a global clock net, and this design is a build check,
  # not a test of how many clocks nextpnr's router will tolerate.
  instance :tx_ddr, Hw.Xilinx.ODDR,
    c: :clk,
    ce: :one,
    d1: :d_rise,
    d2: :d_fall,
    r: :zero,
    s: :zero,
    q: :oddr_q

  instance :tx_buf, Hw.Xilinx.OBUFDS, i: :oddr_q, o: :ddr_p, ob: :ddr_n
end
