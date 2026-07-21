defmodule ULX3S.PLL do
  @moduledoc """
  ECP5 PLL for ULX3S: 25 MHz oscillator -> two configurable output clocks.

  Wraps EHXPLLL + two DCCAs. Both outputs are buffered onto the ECP5 global
  clock network.

  ## ECP5 Clock Architecture

  **EHXPLLL — the PLL hard macro.** With `FEEDBK_PATH="CLKOP"`, the loop
  equation is:

      CLKOP = CLKI × CLKFB_DIV / CLKI_DIV
      VCO   = CLKOP × CLKOP_DIV
      CLKOS = VCO   / CLKOS_DIV

  VCO must stay within 400–800 MHz.

  ## Exact 48 MHz solution

  For USB full-speed the primary output must be within ±2500 ppm of 48 MHz.
  The exact integer solution from 25 MHz is:

      CLKI_DIV=25, CLKFB_DIV=48  →  CLKOP = 25 × 48/25 = 48.000 MHz exactly
      CLKOP_DIV=9                 →  VCO   = 432 MHz  (within 400–800 ✓)
      CLKOS_DIV=2                 →  CLKOS = 216 MHz  (fast internal domain)

  Previous coefficients (CLKI_DIV=8, CLKFB_DIV=15) produced 46.875 MHz —
  24,000 ppm error, far outside USB spec.

  ## Dynamic Phase Control

  The `PHASEDIR` and `PHASESTEP` ports allow runtime phase adjustment of the
  CLKOP output in steps of `T_VCO / 8`:

      step_size = 1 / (VCO_freq × 8) = 1 / (432e6 × 8) ≈ 289 ps

  These are connected to the `phase_dir` and `phase_step` input ports and are
  intended for use with `Hw.USB.ClockTrim` for SOF-disciplined frequency
  correction on boards where an exact integer solution is not available.
  On ULX3S with the coefficients above, these can be left tied to 0.

  ## Parameters

  - `CLKOP_DIV`    — primary output divider (CLKOP = VCO / CLKOP_DIV)
  - `CLKOS_DIV`    — secondary output divider (CLKOS = VCO / CLKOS_DIV)
  - `CLKOP_CPHASE` — primary output coarse phase shift (0..CLKOP_DIV-1)
  - `CLKOS_CPHASE` — secondary output coarse phase shift (0..CLKOS_DIV-1)

  ## Example (exact USB 48 MHz + 216 MHz fast clock)

      instance :pll, ULX3S.PLL,
        CLKOP_DIV:    9,
        CLKOS_DIV:    2,
        CLKOP_CPHASE: 8,   # CLKOP_DIV - 1
        CLKOS_CPHASE: 1,   # CLKOS_DIV - 1
        clk_in:       :clk_25mhz,
        clk_out0:     :clk_48,
        clk_out1:     :clk_fast,
        locked:       :pll_locked,
        phase_dir:    0,
        phase_step:   0
  """

  use Hw.Component

  param :CLKOP_DIV
  param :CLKOS_DIV
  param :CLKOP_CPHASE
  param :CLKOS_CPHASE

  input  :clk_in,     1
  output :clk_out0,   1
  output :clk_out1,   1
  output :locked,     1

  # Dynamic phase control — connect to Hw.USB.ClockTrim or tie to 0
  input  :phase_dir,  1
  input  :phase_step, 1

  blackbox :pll, "EHXPLLL",
    attrs: [
      ICP_CURRENT:            "12",
      LPF_RESISTOR:           "8",
      MFG_ENABLE_FILTEROPAMP: "1",
      MFG_GMCREF_SEL:         "2"
    ],
    params: [
      PLLRST_ENA:      "DISABLED",
      INTFB_WAKE:      "DISABLED",
      STDBY_ENABLE:    "DISABLED",
      DPHASE_SOURCE:   "ENABLED",   # enable dynamic phase control
      OUTDIVIDER_MUXA: "DIVA",
      OUTDIVIDER_MUXB: "DIVB",
      OUTDIVIDER_MUXC: "DIVC",
      OUTDIVIDER_MUXD: "DIVD",
      CLKOP_ENABLE:    "ENABLED",
      CLKOS_ENABLE:    "ENABLED",
      CLKOP_DIV:       :CLKOP_DIV,
      CLKOP_CPHASE:    :CLKOP_CPHASE,
      CLKOP_FPHASE:    0,
      CLKOS_DIV:       :CLKOS_DIV,
      CLKOS_CPHASE:    :CLKOS_CPHASE,
      CLKOS_FPHASE:    0,
      CLKFB_DIV:       48,          # exact 48 MHz: 25 × 48/25 = 48.000
      CLKI_DIV:        25,          # exact 48 MHz
      FEEDBK_PATH:     "CLKOP"
    ],
    ports: [
      CLKI:         :clk_in,
      CLKOP:        :clk_out0,
      CLKOS:        :clk_out1,
      LOCK:         :locked,
      CLKFB:        :clk_out0,
      PHASESEL0:    0,
      PHASESEL1:    0,
      PHASEDIR:     :phase_dir,
      PHASESTEP:    :phase_step,
      PHASELOADREG: 0,
      STDBY:        0,
      RST:          0,
      PLLWAKESYNC:  0,
      ENCLKOP:      0,
      ENCLKOS:      0
    ]
end
