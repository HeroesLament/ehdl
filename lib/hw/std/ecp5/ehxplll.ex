defmodule Hw.ECP5.EHXPLLL do
  @moduledoc """
  ECP5 PLL hard macro, every parameter and port exposed.

  The raw primitive. Board wrappers (`ULX3S.PLL`) pick the dividers and tie the
  ports they do not use; reach for this directly when a design needs CLKOS2/3,
  a feedback path other than CLKOP, or the standby / reset controls.

  ## Frequencies

  With `FEEDBK_PATH: "CLKOP"` (the default) the loop locks CLKOP to the
  reference:

      f_pfd   = f_clki / CLKI_DIV
      f_clkop = f_pfd  * CLKFB_DIV
      f_vco   = f_clkop * CLKOP_DIV
      f_clkos = f_vco  / CLKOS_DIV        (same for CLKOS2, CLKOS3)

  The datasheet ranges are f_vco 400..800 MHz and f_pfd 10..400 MHz. A phase
  detector run below its range can still produce a clock, but LOCK is not
  trustworthy there (Microwatt found it stuck at 0 at 2 MHz). Nothing in
  this module checks either range.

  ## Feedback is a port

  Unlike `Hw.Xilinx.PLLE2_BASE`, the feedback is not closed inside: which net
  CLKFB must see depends on `FEEDBK_PATH`. For `"CLKOP"`, connect `clkfb` to the
  same signal as `clkop`. An open CLKFB instantiates cleanly and never locks.

  ## Phase

  `*_CPHASE` is in VCO cycles and `*_FPHASE` in eighths of one. yosys's
  `ecppll` writes `CPHASE = DIV - 1` for a zero-phase output and so does
  `ULX3S.PLL`; nextpnr writes the number as given.

  ## Loop filter

  `ICP_CURRENT`, `LPF_RESISTOR`, `MFG_ENABLE_FILTEROPAMP` and `MFG_GMCREF_SEL`
  are synthesis *attributes* on the yosys/nextpnr side, not Verilog
  parameters, and are emitted as `(* ... *)`. The defaults are the values
  `ecppll` writes for every configuration. nextpnr's own default for an absent
  attribute is 0.

  ## Ports

  Every input must be connected (tie unused ones to a zero wire). Outputs may
  be left open. `phasesel*`, `phasedir`, `phasestep`, `phaseloadreg` are the
  dynamic phase controls and do nothing unless `DPHASE_SOURCE: "ENABLED"`.
  `Hw.USB.ClockTrim` drives `phasedir` / `phasestep`.

  Parameter set and defaults: yosys `share/ecp5/cells_bb.v` (oss-cad-suite).
  """

  use Hw.Component

  param :CLKI_DIV, default: 1
  param :CLKFB_DIV, default: 1
  param :CLKOP_DIV, default: 8
  param :CLKOS_DIV, default: 8
  param :CLKOS2_DIV, default: 8
  param :CLKOS3_DIV, default: 8
  param :CLKOP_ENABLE, default: "ENABLED"
  param :CLKOS_ENABLE, default: "DISABLED"
  param :CLKOS2_ENABLE, default: "DISABLED"
  param :CLKOS3_ENABLE, default: "DISABLED"
  param :CLKOP_CPHASE, default: 0
  param :CLKOS_CPHASE, default: 0
  param :CLKOS2_CPHASE, default: 0
  param :CLKOS3_CPHASE, default: 0
  param :CLKOP_FPHASE, default: 0
  param :CLKOS_FPHASE, default: 0
  param :CLKOS2_FPHASE, default: 0
  param :CLKOS3_FPHASE, default: 0
  param :FEEDBK_PATH, default: "CLKOP"
  param :CLKOP_TRIM_POL, default: "RISING"
  param :CLKOP_TRIM_DELAY, default: 0
  param :CLKOS_TRIM_POL, default: "RISING"
  param :CLKOS_TRIM_DELAY, default: 0
  param :OUTDIVIDER_MUXA, default: "DIVA"
  param :OUTDIVIDER_MUXB, default: "DIVB"
  param :OUTDIVIDER_MUXC, default: "DIVC"
  param :OUTDIVIDER_MUXD, default: "DIVD"
  param :PLL_LOCK_MODE, default: 0
  param :PLL_LOCK_DELAY, default: 200
  param :STDBY_ENABLE, default: "DISABLED"
  param :REFIN_RESET, default: "DISABLED"
  param :SYNC_ENABLE, default: "DISABLED"
  param :INT_LOCK_STICKY, default: "ENABLED"
  param :DPHASE_SOURCE, default: "DISABLED"
  param :PLLRST_ENA, default: "DISABLED"
  param :INTFB_WAKE, default: "DISABLED"

  # Emitted as attributes (see moduledoc).
  param :ICP_CURRENT, default: "12"
  param :LPF_RESISTOR, default: "8"
  param :MFG_ENABLE_FILTEROPAMP, default: "1"
  param :MFG_GMCREF_SEL, default: "2"

  input :clki, 1
  input :clkfb, 1
  input :phasesel1, 1
  input :phasesel0, 1
  input :phasedir, 1
  input :phasestep, 1
  input :phaseloadreg, 1
  input :stdby, 1
  input :pllwakesync, 1
  input :rst, 1
  input :enclkop, 1
  input :enclkos, 1
  input :enclkos2, 1
  input :enclkos3, 1

  output :clkop, 1
  output :clkos, 1
  output :clkos2, 1
  output :clkos3, 1
  output :lock, 1
  output :intlock, 1
  output :refclk, 1
  output :clkintfb, 1

  blackbox :pll, "EHXPLLL",
    attrs: [
      ICP_CURRENT: :ICP_CURRENT,
      LPF_RESISTOR: :LPF_RESISTOR,
      MFG_ENABLE_FILTEROPAMP: :MFG_ENABLE_FILTEROPAMP,
      MFG_GMCREF_SEL: :MFG_GMCREF_SEL
    ],
    params: [
      CLKI_DIV: :CLKI_DIV,
      CLKFB_DIV: :CLKFB_DIV,
      CLKOP_DIV: :CLKOP_DIV,
      CLKOS_DIV: :CLKOS_DIV,
      CLKOS2_DIV: :CLKOS2_DIV,
      CLKOS3_DIV: :CLKOS3_DIV,
      CLKOP_ENABLE: :CLKOP_ENABLE,
      CLKOS_ENABLE: :CLKOS_ENABLE,
      CLKOS2_ENABLE: :CLKOS2_ENABLE,
      CLKOS3_ENABLE: :CLKOS3_ENABLE,
      CLKOP_CPHASE: :CLKOP_CPHASE,
      CLKOS_CPHASE: :CLKOS_CPHASE,
      CLKOS2_CPHASE: :CLKOS2_CPHASE,
      CLKOS3_CPHASE: :CLKOS3_CPHASE,
      CLKOP_FPHASE: :CLKOP_FPHASE,
      CLKOS_FPHASE: :CLKOS_FPHASE,
      CLKOS2_FPHASE: :CLKOS2_FPHASE,
      CLKOS3_FPHASE: :CLKOS3_FPHASE,
      FEEDBK_PATH: :FEEDBK_PATH,
      CLKOP_TRIM_POL: :CLKOP_TRIM_POL,
      CLKOP_TRIM_DELAY: :CLKOP_TRIM_DELAY,
      CLKOS_TRIM_POL: :CLKOS_TRIM_POL,
      CLKOS_TRIM_DELAY: :CLKOS_TRIM_DELAY,
      OUTDIVIDER_MUXA: :OUTDIVIDER_MUXA,
      OUTDIVIDER_MUXB: :OUTDIVIDER_MUXB,
      OUTDIVIDER_MUXC: :OUTDIVIDER_MUXC,
      OUTDIVIDER_MUXD: :OUTDIVIDER_MUXD,
      PLL_LOCK_MODE: :PLL_LOCK_MODE,
      PLL_LOCK_DELAY: :PLL_LOCK_DELAY,
      STDBY_ENABLE: :STDBY_ENABLE,
      REFIN_RESET: :REFIN_RESET,
      SYNC_ENABLE: :SYNC_ENABLE,
      INT_LOCK_STICKY: :INT_LOCK_STICKY,
      DPHASE_SOURCE: :DPHASE_SOURCE,
      PLLRST_ENA: :PLLRST_ENA,
      INTFB_WAKE: :INTFB_WAKE
    ],
    ports: [
      CLKI: :clki,
      CLKFB: :clkfb,
      PHASESEL1: :phasesel1,
      PHASESEL0: :phasesel0,
      PHASEDIR: :phasedir,
      PHASESTEP: :phasestep,
      PHASELOADREG: :phaseloadreg,
      STDBY: :stdby,
      PLLWAKESYNC: :pllwakesync,
      RST: :rst,
      ENCLKOP: :enclkop,
      ENCLKOS: :enclkos,
      ENCLKOS2: :enclkos2,
      ENCLKOS3: :enclkos3,
      CLKOP: :clkop,
      CLKOS: :clkos,
      CLKOS2: :clkos2,
      CLKOS3: :clkos3,
      LOCK: :lock,
      INTLOCK: :intlock,
      REFCLK: :refclk,
      CLKINTFB: :clkintfb
    ]
end
