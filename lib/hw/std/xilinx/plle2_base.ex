defmodule Hw.Xilinx.PLLE2_BASE do
  @moduledoc """
  Xilinx 7-series PLL: synthesise clocks from one input, integer ratios only.

  The smaller sibling of `Hw.Xilinx.MMCME2_BASE`. It has six outputs instead of
  seven, no fractional dividers, and no per-output fine phase shift. When an
  integer ratio will do, prefer it — `xc7z020` has four PLLs and four MMCMs, and
  spending an MMCM on a ratio a PLL can hit wastes the more capable resource.

  Everything in `Hw.Xilinx.MMCME2_BASE`'s moduledoc about global clock routing
  applies here unchanged and is the thing most likely to bite: **every output
  taken from this primitive is another global clock net, and nextpnr-xilinx's
  clock router is already at capacity on this part.** Four consecutive revisions
  of `libresdr_radio` needed seeds 2, 1, 5 and 25, the last of which failed at 23
  seeds and succeeded at one in 377. Add clocks one at a time.

  ## Toolchain support

  - **yosys** carries a blackbox stub only; instantiate explicitly.
  - **nextpnr-xilinx** upgrades `PLLE2_BASE` to `PLLE2_ADV` in
    `XC7Packer::prepare_clocking`, packs it in `XC7Packer::pack_plls`, and writes
    FASM via `write_pll` / `write_pll_clkout`. The dynamic-reconfiguration and
    phase-shift ports are deliberately left unrouted to match Vivado, which is
    fine here because `PLLE2_BASE` does not expose them.
  - **prjxray zynq7** documents 343 `PLLE2_ADV.*` features in
    `segbits_cmt_top_l_upper_t.db`, covering every feature `fasm.cc` writes.

  The two CMT features zynq7 lacks relative to artix7 are both
  `PLLE2_ADV.COMP*ZHOLD_NO_CLKIN_BUF*` — external-feedback compensation, which
  `fasm.cc` rejects with a hard error for any `COMPENSATION` other than
  `INTERNAL` or `ZHOLD`, and which `PLLE2_BASE` has no parameter for. Unreachable
  either way, so not a gap that matters.

  As with the MMCM, the loop-filter and lock tables are derived from
  `CLKFBOUT_MULT` after a hardcoded version was found to produce a PLL too
  jittery for synchronous logic. Pass the multiplier; `fasm.cc` errors above 63 or
  at 0.

  ## Feedback is closed inside this module

  `CLKFBOUT` is wired to `CLKFBIN` here, for the reason given in
  `Hw.Xilinx.MMCME2_BASE`: an open feedback path instantiates cleanly and never
  locks, and there is no configuration in which the caller would want it open.

  ## Frequencies

      f_vco = f_in / DIVCLK_DIVIDE * CLKFBOUT_MULT
      f_out = f_vco / CLKOUTn_DIVIDE

  `f_vco` must land in the part's PLL range for the `-1` speed grade. Nothing in
  this flow checks that, and there is no timing model to catch what follows.

      instance :pll, Hw.Xilinx.PLLE2_BASE,
        CLKIN1_PERIOD: 10.0,      # 100 MHz in
        DIVCLK_DIVIDE: 1,
        CLKFBOUT_MULT: 8,         # 800 MHz VCO
        CLKOUT0_DIVIDE: 4,        # 200 MHz
        clkin1: :ref_clk, rst: :zero, pwrdwn: :zero,
        clkout0: :dsp_clk_raw, locked: :pll_locked

  Each output needs a `Hw.Xilinx.BUFG` before it can clock fabric logic.

  **Never validated on hardware.** See the verification tiers in `AGENTS.md`.
  """

  use Hw.Component

  param :BANDWIDTH, default: "OPTIMIZED"

  # Input period in ns. The primitive's own default of 0.000 is not a period.
  param :CLKIN1_PERIOD, default: 10.0

  # f_vco = f_in / DIVCLK_DIVIDE * CLKFBOUT_MULT. nextpnr errors outside 1..63.
  param :DIVCLK_DIVIDE, default: 1
  param :CLKFBOUT_MULT, default: 5
  param :CLKFBOUT_PHASE, default: 0.0

  param :CLKOUT0_DIVIDE, default: 1
  param :CLKOUT0_PHASE, default: 0.0
  param :CLKOUT0_DUTY_CYCLE, default: 0.5

  param :CLKOUT1_DIVIDE, default: 1
  param :CLKOUT1_PHASE, default: 0.0
  param :CLKOUT1_DUTY_CYCLE, default: 0.5

  param :CLKOUT2_DIVIDE, default: 1
  param :CLKOUT2_PHASE, default: 0.0
  param :CLKOUT2_DUTY_CYCLE, default: 0.5

  param :CLKOUT3_DIVIDE, default: 1
  param :CLKOUT3_PHASE, default: 0.0
  param :CLKOUT3_DUTY_CYCLE, default: 0.5

  param :CLKOUT4_DIVIDE, default: 1
  param :CLKOUT4_PHASE, default: 0.0
  param :CLKOUT4_DUTY_CYCLE, default: 0.5

  param :CLKOUT5_DIVIDE, default: 1
  param :CLKOUT5_PHASE, default: 0.0
  param :CLKOUT5_DUTY_CYCLE, default: 0.5

  param :REF_JITTER1, default: 0.01
  param :STARTUP_WAIT, default: "FALSE"

  input :clkin1, 1
  input :pwrdwn, 1
  input :rst,    1

  output :clkout0, 1
  output :clkout1, 1
  output :clkout2, 1
  output :clkout3, 1
  output :clkout4, 1
  output :clkout5, 1
  output :locked,  1

  # Internal feedback. Not a port: see the moduledoc.
  wire :clkfb, 1

  blackbox :pll, "PLLE2_BASE",
    params: [
      BANDWIDTH: :BANDWIDTH,
      CLKFBOUT_MULT: :CLKFBOUT_MULT,
      CLKFBOUT_PHASE: :CLKFBOUT_PHASE,
      CLKIN1_PERIOD: :CLKIN1_PERIOD,
      CLKOUT0_DIVIDE: :CLKOUT0_DIVIDE,
      CLKOUT0_DUTY_CYCLE: :CLKOUT0_DUTY_CYCLE,
      CLKOUT0_PHASE: :CLKOUT0_PHASE,
      CLKOUT1_DIVIDE: :CLKOUT1_DIVIDE,
      CLKOUT1_DUTY_CYCLE: :CLKOUT1_DUTY_CYCLE,
      CLKOUT1_PHASE: :CLKOUT1_PHASE,
      CLKOUT2_DIVIDE: :CLKOUT2_DIVIDE,
      CLKOUT2_DUTY_CYCLE: :CLKOUT2_DUTY_CYCLE,
      CLKOUT2_PHASE: :CLKOUT2_PHASE,
      CLKOUT3_DIVIDE: :CLKOUT3_DIVIDE,
      CLKOUT3_DUTY_CYCLE: :CLKOUT3_DUTY_CYCLE,
      CLKOUT3_PHASE: :CLKOUT3_PHASE,
      CLKOUT4_DIVIDE: :CLKOUT4_DIVIDE,
      CLKOUT4_DUTY_CYCLE: :CLKOUT4_DUTY_CYCLE,
      CLKOUT4_PHASE: :CLKOUT4_PHASE,
      CLKOUT5_DIVIDE: :CLKOUT5_DIVIDE,
      CLKOUT5_DUTY_CYCLE: :CLKOUT5_DUTY_CYCLE,
      CLKOUT5_PHASE: :CLKOUT5_PHASE,
      DIVCLK_DIVIDE: :DIVCLK_DIVIDE,
      REF_JITTER1: :REF_JITTER1,
      STARTUP_WAIT: :STARTUP_WAIT
    ],
    ports: [
      CLKIN1: :clkin1,
      CLKFBIN: :clkfb,
      PWRDWN: :pwrdwn,
      RST: :rst,
      CLKFBOUT: :clkfb,
      CLKOUT0: :clkout0,
      CLKOUT1: :clkout1,
      CLKOUT2: :clkout2,
      CLKOUT3: :clkout3,
      CLKOUT4: :clkout4,
      CLKOUT5: :clkout5,
      LOCKED: :locked
    ]
end
