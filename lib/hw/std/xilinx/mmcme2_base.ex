defmodule Hw.Xilinx.MMCME2_BASE do
  @moduledoc """
  Xilinx 7-series mixed-mode clock manager: synthesise clocks from one input.

  Until now every clock in this repo came from the PS (`FCLKCLK[n]`) or off a pin.
  That is enough for an AXI clock and a received `DATA_CLK`, and it is not enough
  for a receiver: sample-rate conversion, an FFT that wants to run faster than the
  sample clock, and a transmit path that needs a phase-shifted output clock all
  need a ratio the PS cannot produce.

  `MMCME2_BASE` is the simpler of the two clock primitives — no dynamic
  reconfiguration port, no dynamic phase shift. `Hw.Xilinx.PLLE2_BASE` is smaller
  and cheaper still; prefer it unless fractional division or per-output phase is
  actually needed.

  ## Read this before adding a clock

  **Global clock routing is this toolchain's binding constraint, and every output
  taken from here is another global clock net.** With two `BUFG`s in
  `libresdr_radio`, four consecutive revisions needed seeds 2, 1, 5 and 25 — and
  that last revision failed on all of seeds 1..23 and succeeded on exactly one
  seed in 24..400. nextpnr-xilinx's clock router is at capacity on this part at
  this design size.

  So a third and fourth clock domain are not free, and the failure is a build that
  does not route rather than a design that runs slowly. Budget for it: add one
  output at a time, and sweep seeds. `AGENTS.md` has the log signature that lets a
  seed sweep be cut short before the router even starts.

  ## Toolchain support: the best of the four primitives added here

  - **yosys** carries a blackbox stub only. There is no inference — the primitive
    has to be instantiated, which is what this module is for.
  - **nextpnr-xilinx** upgrades `MMCME2_BASE` to `MMCME2_ADV` in
    `XC7Packer::prepare_clocking`, so the BASE variant is first class. FASM is
    written by `write_mmcm` / `write_mmcm_clkout`, including the fractional
    `CLKFBOUT`/`CLKOUT0` counters.
  - **prjxray zynq7** documents 378 `MMCME2_ADV.*` features in
    `segbits_cmt_top_l_lower_b.db`, and every feature `fasm.cc` writes is present.
    Checked individually: `IN_USE`, `ZINV_PWRDWN`, `ZINV_RST`, `INV_CLKINSEL`,
    `COMP.Z_ZHOLD`, `FILTREG1_RESERVED`, `LKTABLE`, `TABLE`, the per-output
    `HIGH_TIME`/`LOW_TIME`/`PHASE_MUX` counters and the fractional `FRAC_WF_F` /
    `FRAC_WF_R` bits.

  Against artix7 the zynq7 database is missing exactly two CMT features per tile,
  and neither is reachable: both encode external-feedback compensation, which
  `fasm.cc` rejects outright and which `MMCME2_BASE` has no parameter for anyway.

  Worth knowing: this fork of nextpnr carries hardware-verified corrections to the
  MMCM FASM writer that are not upstream, and a comment recording that the
  loop-filter and lock tables were once hardcoded and produced a PLL too jittery
  for synchronous logic. They are now derived from `CLKFBOUT_MULT`. **Pass the
  multiplier correctly and do not omit it** — a plausible clock that jitters is
  worse than one that fails to lock.

  `fasm.cc` hard-errors on `CLKFBOUT_MULT_F` above 63 or equal to 0, so those at
  least fail loudly.

  ## Feedback is closed inside this module

  `MMCME2_BASE` supports internal feedback only — it has no `COMPENSATION`
  parameter — so `CLKFBOUT` must connect to `CLKFBIN` and there is nothing to
  decide. That connection is made here rather than at the call site, because an
  MMCM with an open feedback path is a thing that instantiates fine and never
  locks, and leaving a mandatory wire to the caller is leaving a way to get it
  wrong for no benefit.

  ## Frequencies

      f_vco = f_in / DIVCLK_DIVIDE * CLKFBOUT_MULT_F
      f_out = f_vco / CLKOUTn_DIVIDE

  `f_vco` must land in the part's MMCM VCO range — consult the `-1` speed grade
  data for `xc7z020`; nothing in this vendor-free flow checks it, and there is no
  timing model to catch the consequences either.

      instance :mmcm, Hw.Xilinx.MMCME2_BASE,
        CLKIN1_PERIOD: 10.0,          # 100 MHz in
        DIVCLK_DIVIDE: 1,
        CLKFBOUT_MULT_F: 8.0,         # 800 MHz VCO
        CLKOUT0_DIVIDE_F: 5.0,        # 160 MHz
        CLKOUT1_DIVIDE: 8,            # 100 MHz
        clkin1: :ref_clk, rst: :zero, pwrdwn: :zero,
        clkout0: :fft_clk_raw, clkout1: :samp_clk_raw, locked: :mmcm_locked

  Each output still needs a `Hw.Xilinx.BUFG` before it can clock fabric logic —
  see that module for why skipping the buffer produces a "clock" on local routing
  rather than a routing failure.

  **Never validated on hardware.** No design in this repo has ever run a
  fabric-generated clock. See the verification tiers in `AGENTS.md`.
  """

  use Hw.Component

  param :BANDWIDTH, default: "OPTIMIZED"

  # Input period in ns. The default is deliberately a real 100 MHz rather than the
  # primitive's own 0.000, which is not a period.
  param :CLKIN1_PERIOD, default: 10.0

  # f_vco = f_in / DIVCLK_DIVIDE * CLKFBOUT_MULT_F. nextpnr errors outside 1..63.
  param :DIVCLK_DIVIDE, default: 1
  param :CLKFBOUT_MULT_F, default: 5.0
  param :CLKFBOUT_PHASE, default: 0.0

  # CLKOUT0 is the only fractional divider.
  param :CLKOUT0_DIVIDE_F, default: 1.0
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

  param :CLKOUT6_DIVIDE, default: 1
  param :CLKOUT6_PHASE, default: 0.0
  param :CLKOUT6_DUTY_CYCLE, default: 0.5

  param :CLKOUT4_CASCADE, default: "FALSE"
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
  output :clkout6, 1
  output :locked,  1

  # Internal feedback. Not a port: see the moduledoc.
  wire :clkfb, 1

  blackbox :mmcm, "MMCME2_BASE",
    params: [
      BANDWIDTH: :BANDWIDTH,
      CLKFBOUT_MULT_F: :CLKFBOUT_MULT_F,
      CLKFBOUT_PHASE: :CLKFBOUT_PHASE,
      CLKIN1_PERIOD: :CLKIN1_PERIOD,
      CLKOUT0_DIVIDE_F: :CLKOUT0_DIVIDE_F,
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
      CLKOUT4_CASCADE: :CLKOUT4_CASCADE,
      CLKOUT4_DIVIDE: :CLKOUT4_DIVIDE,
      CLKOUT4_DUTY_CYCLE: :CLKOUT4_DUTY_CYCLE,
      CLKOUT4_PHASE: :CLKOUT4_PHASE,
      CLKOUT5_DIVIDE: :CLKOUT5_DIVIDE,
      CLKOUT5_DUTY_CYCLE: :CLKOUT5_DUTY_CYCLE,
      CLKOUT5_PHASE: :CLKOUT5_PHASE,
      CLKOUT6_DIVIDE: :CLKOUT6_DIVIDE,
      CLKOUT6_DUTY_CYCLE: :CLKOUT6_DUTY_CYCLE,
      CLKOUT6_PHASE: :CLKOUT6_PHASE,
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
      CLKOUT6: :clkout6,
      LOCKED: :locked
    ]
end
