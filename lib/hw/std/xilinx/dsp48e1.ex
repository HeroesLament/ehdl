defmodule Hw.Xilinx.DSP48E1 do
  @moduledoc """
  Xilinx 7-series DSP slice: a 25x18 signed multiplier, a 48-bit accumulator, a
  pre-adder, and cascade paths between neighbours.

  This is the primitive that makes an FFT affordable on this part. `xc7z020` has
  **220 of them** (`DSP_L` x40 + `DSP_R` x70 in the tilegrid), each capable of a
  registered multiply-accumulate per clock. The alternative is LUT arithmetic —
  and on this toolchain `-nocarry` is mandatory, which replaces hardware carry
  chains with LUT logic on exactly the paths a butterfly is made of. So the DSP
  slices are not an optimisation here, they are the difference between a receiver
  that fits and one that does not.

  ## Toolchain support

  Better than most of what this repo has touched:

  - **yosys** carries a full behavioural model (`cells_xtra`-adjacent
    `cells_sim.v`), blackboxed for synthesis, and infers `DSP48E1` from `*` by
    default for operands within 25x18.
  - **nextpnr-xilinx** has a dedicated packer (`pack_dsp_xc7.cc`,
    `XC7Packer::pack_dsps`) including cascade chaining with absolute-Z
    constraints, and a FASM writer (`write_dsp_cell`).
  - **prjxray zynq7** documents 436 features per `DSP_L`/`DSP_R` tile, a set
    byte-identical to artix7.

  The `IDDR` failure mode — prjxray documenting only 2 of 14 site muxes — does
  **not** recur here. That was checked rather than assumed.

  ## What this wrapper deliberately does not expose

  Three parameters build cleanly and are then **silently ignored**, because they
  have zero features in the prjxray database and `write_dsp_cell` never reads
  them: `USE_MULT`, `SEL_PATTERN` and `USE_PATTERN_DETECT`. `MASK` and `PATTERN`
  are reachable but `fasm.cc` truncates `MASK` to 46 bits with a comment claiming
  prjxray only recognises 46 — which is wrong for zynq7, where `MASK[46]` and
  `MASK[47]` both exist. A mask with either top bit set is mis-encoded.

  So none of them is a parameter here. The pattern detector is off and stays off,
  and **`PATTERNDETECT`, `PATTERNBDETECT`, `OVERFLOW` and `UNDERFLOW` must not be
  relied on** — they are declared so the port list matches the primitive, not
  because they work. The same applies to `AUTORESET_PATDET`.

  This is a deliberate choice about where a silent wrong answer gets caught. A
  parameter that is accepted and discarded is worse than one that does not exist,
  and this repo has been burned by `DIFF_TERM` and `SAME_EDGE_PIPELINED` doing
  precisely that. If pattern detection is ever wanted, the fix is upstream in
  prjxray and nextpnr, not here.

  `IS_*_INVERTED` is likewise not exposed. nextpnr has the invertible-pin
  machinery, but `pack_dsp_xc7.cc:126-128` comments `INMODE`, `ALUMODE2` and
  `ALUMODE3` out of the constant-tie path — "these seem to be inverted for
  unknown reasons" — so constant control pins must route from fabric GND/VCC.
  Tie them to named zero/one wires in the design rather than reaching for the
  inversion parameters.

  ## Datapath, transcribed from the behavioural model

  The ALU computes `Z +/- (X + Y + CIN)`, where three muxes choose the operands.
  `OPMODE` selects them (values are of the registered `OPMODE`, so add a cycle
  when `OPMODEREG` is 1):

      OPMODE[1:0]  X mux      OPMODE[3:2]  Y mux        OPMODE[6:4]  Z mux
      00           0          00           0            000          0
      01           M          01           M            001          PCIN
      10           P          10           all ones     010          P
      11           A:B        11           C            011          C
                                                        100          P    (see below)
                                                        101          PCIN >> 17
                                                        110          P >> 17

  Constraints the model enforces with `$fatal`, worth knowing before they show up
  as silence in hardware:

  - `X = M` and `Y = M` must be selected together — `OPMODE[3:0] = 4'b0101`.
    Either alone is illegal.
  - `X = P`, `Z = P` and `Z = P >> 17` all require `PREG = 1`.
  - `Z` mux `100` additionally requires `OPMODE[3:0] = 4'b1000`. It is the
    MACC-extension path, not a second way to select P.
  - `CARRYINSEL` `100` and `101` also require `PREG = 1`.

  `ALUMODE` then chooses the operation: bit 0 inverts Z, bit 1 inverts the sum,
  bit 2 gates the majority term, bit 3 swaps XOR for majority. The two that
  matter in practice are `4'b0000` for `Z + X + Y + CIN` and `4'b0011` for
  `Z - (X + Y + CIN)`.

  `INMODE` controls the pre-adder and the A/B register selects:

      INMODE[0]  A1 (1) or A2 (0) into the pre-adder
      INMODE[1]  gate A to zero
      INMODE[2]  admit D
      INMODE[3]  pre-adder subtracts (D - A) rather than adds
      INMODE[4]  B1 (1) or B2 (0) into the multiplier

  ## Pipelining

  `AREG`, `BREG`, `CREG`, `DREG`, `ADREG`, `MREG` and `PREG` each add a register
  stage and are the whole reason to prefer this over LUT arithmetic — they are
  what lets the slice run fast. `MREG = 1, PREG = 1` is the usual fully-pipelined
  multiply, three cycles from A/B to P.

  All of them default to 1 and are meant to be set to 0, which is safe: in Elixir
  `0` is truthy, so `build_param_map`'s `||` fallback never discarded it. An
  earlier version of this paragraph claimed otherwise; see `AGENTS.md` on
  `false`-vs-`0` for the retraction. `false` is the only value a `param` override
  can lose, and no Verilog parameter takes a boolean.

  ## Usage

  A plain registered 25x18 signed multiply, `P = A * B`. Note that every unused
  control input still has to be tied — `zero` and `one` are ordinary wires
  assigned in a `comb` block, because a bare integer literal on a multi-bit port
  emits as a 1-bit constant and relies on Verilog's implicit widening:

      instance :mul, Hw.Xilinx.DSP48E1,
        # X = M, Y = M, Z = 0; ALU adds
        opmode: :opmode_mult, alumode: :alu_add, inmode: :inmode_b2,
        carryinsel: :zero3,
        a: :a_ext, b: :b_in, c: :zero48, d: :zero25,
        p: :product,
        clk: :dsp_clk,
        cea1: :zero, cea2: :one, ceb1: :zero, ceb2: :one, cec: :zero,
        ced: :zero, cead: :zero, cealumode: :one, cectrl: :one,
        ceinmode: :one, cem: :one, cep: :one, cecarryin: :zero,
        rsta: :zero, rstb: :zero, rstc: :zero, rstd: :zero,
        rstm: :zero, rstp: :zero, rstctrl: :zero, rstalumode: :zero,
        rstinmode: :zero, rstallcarryin: :zero,
        carryin: :zero, carrycascin: :zero, multsignin: :zero,
        acin: :zero30, bcin: :zero18, pcin: :zero48

  with `opmode_mult = 0b0000101`, `alu_add = 0b0000`, `inmode_b2 = 0b00000`.

  Cascading is what `ACOUT -> ACIN`, `BCOUT -> BCIN` and `PCOUT -> PCIN` are for,
  and `A_INPUT`/`B_INPUT` set to `"CASCADE"` selects them. nextpnr's packer
  chains cascaded slices with absolute-Z constraints, so a chain must fit one
  DSP column — 20 slices on this part.

  **Never validated on hardware.** As of writing this builds and nothing more;
  see the verification tiers in `AGENTS.md` and do not upgrade that claim without
  a measurement.
  """

  use Hw.Component

  # Pipeline registers. Every one of these is meant to be overridable to 0.
  param :AREG, default: 1
  param :BREG, default: 1
  param :CREG, default: 1
  param :DREG, default: 1
  param :ADREG, default: 1
  param :MREG, default: 1
  param :PREG, default: 1
  param :ACASCREG, default: 1
  param :BCASCREG, default: 1

  # Control-input registers.
  param :ALUMODEREG, default: 1
  param :INMODEREG, default: 1
  param :OPMODEREG, default: 1
  param :CARRYINREG, default: 1
  param :CARRYINSELREG, default: 1

  # "DIRECT" takes A/B from the fabric, "CASCADE" from the neighbour's ACOUT/BCOUT.
  param :A_INPUT, default: "DIRECT"
  param :B_INPUT, default: "DIRECT"

  # "TRUE" routes D through the pre-adder. "ONE48" | "TWO24" | "FOUR12".
  param :USE_DPORT, default: "FALSE"
  param :USE_SIMD, default: "ONE48"

  # --- outputs ---------------------------------------------------------------
  output :acout,          30
  output :bcout,          18
  output :carrycascout,    1
  output :carryout,        4
  output :multsignout,     1
  output :overflow,        1
  output :p,              48
  output :patternbdetect,  1
  output :patterndetect,   1
  output :pcout,          48
  output :underflow,       1

  # --- data inputs -----------------------------------------------------------
  input :a,    30
  input :acin, 30
  input :b,    18
  input :bcin, 18
  input :c,    48
  input :d,    25
  input :pcin, 48

  # --- control inputs --------------------------------------------------------
  input :alumode,     4
  input :carryinsel,  3
  input :inmode,      5
  input :opmode,      7
  input :carrycascin, 1
  input :carryin,     1
  input :multsignin,  1
  input :clk,         1

  # --- clock enables ---------------------------------------------------------
  input :cea1,      1
  input :cea2,      1
  input :cead,      1
  input :cealumode, 1
  input :ceb1,      1
  input :ceb2,      1
  input :cec,       1
  input :cecarryin, 1
  input :cectrl,    1
  input :ced,       1
  input :ceinmode,  1
  input :cem,       1
  input :cep,       1

  # --- resets ----------------------------------------------------------------
  input :rsta,          1
  input :rstallcarryin, 1
  input :rstalumode,    1
  input :rstb,          1
  input :rstc,          1
  input :rstctrl,       1
  input :rstd,          1
  input :rstinmode,     1
  input :rstm,          1
  input :rstp,          1

  blackbox :dsp48e1, "DSP48E1",
    params: [
      ACASCREG: :ACASCREG,
      ADREG: :ADREG,
      ALUMODEREG: :ALUMODEREG,
      AREG: :AREG,
      A_INPUT: :A_INPUT,
      BCASCREG: :BCASCREG,
      BREG: :BREG,
      B_INPUT: :B_INPUT,
      CARRYINREG: :CARRYINREG,
      CARRYINSELREG: :CARRYINSELREG,
      CREG: :CREG,
      DREG: :DREG,
      INMODEREG: :INMODEREG,
      MREG: :MREG,
      OPMODEREG: :OPMODEREG,
      PREG: :PREG,
      USE_DPORT: :USE_DPORT,
      USE_SIMD: :USE_SIMD
    ],
    ports: [
      A: :a,
      ACIN: :acin,
      ALUMODE: :alumode,
      B: :b,
      BCIN: :bcin,
      C: :c,
      CARRYCASCIN: :carrycascin,
      CARRYIN: :carryin,
      CARRYINSEL: :carryinsel,
      CEA1: :cea1,
      CEA2: :cea2,
      CEAD: :cead,
      CEALUMODE: :cealumode,
      CEB1: :ceb1,
      CEB2: :ceb2,
      CEC: :cec,
      CECARRYIN: :cecarryin,
      CECTRL: :cectrl,
      CED: :ced,
      CEINMODE: :ceinmode,
      CEM: :cem,
      CEP: :cep,
      CLK: :clk,
      D: :d,
      INMODE: :inmode,
      MULTSIGNIN: :multsignin,
      OPMODE: :opmode,
      PCIN: :pcin,
      RSTA: :rsta,
      RSTALLCARRYIN: :rstallcarryin,
      RSTALUMODE: :rstalumode,
      RSTB: :rstb,
      RSTC: :rstc,
      RSTCTRL: :rstctrl,
      RSTD: :rstd,
      RSTINMODE: :rstinmode,
      RSTM: :rstm,
      RSTP: :rstp,
      ACOUT: :acout,
      BCOUT: :bcout,
      CARRYCASCOUT: :carrycascout,
      CARRYOUT: :carryout,
      MULTSIGNOUT: :multsignout,
      OVERFLOW: :overflow,
      P: :p,
      PATTERNBDETECT: :patternbdetect,
      PATTERNDETECT: :patterndetect,
      PCOUT: :pcout,
      UNDERFLOW: :underflow
    ]
end
