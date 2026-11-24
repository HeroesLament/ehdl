defmodule Hw.ECP5.IDDRX2DQA do
  @moduledoc """
  ECP5 `IDDRX2DQA`. DDR memory DQ input gearbox, read on the DQS group's DQSR90 with its read / write pointers.

  **Proven on the ULX3S-85F through oxibit-ecp5 (`designs/dqs_probe.v`: strobe and DQ drive, DATAVALID / BURSTDET, DQ loopback), not through this wrapper. The DDR tristates reach the pad only with the PIO TRIMUX_TSREG on IOLTO, which oxibit sets (nextpnr does not). Bring-up as LiteDRAM ECP5DDRPHYInit: DLL lock, freeze, stop ECLK, reset, release, pause, DLL update, release pause.**

  Generated from oxibit-ecp5's primitive declarations (ports) and the
  yosys Lattice cell library (parameter defaults).
  """

  use Hw.Component

  param :GSR, default: "DISABLED"

  input :sclk, 1
  input :eclk, 1
  input :dqsr90, 1
  input :d, 1
  input :rst, 1
  input :rdpntr2, 1
  input :rdpntr1, 1
  input :rdpntr0, 1
  input :wrpntr2, 1
  input :wrpntr1, 1
  input :wrpntr0, 1
  output :q3, 1
  output :q2, 1
  output :q1, 1
  output :q0, 1
  output :qwl, 1

  blackbox :iddrx2dqa, "IDDRX2DQA",
    params: [
      GSR: :GSR
    ],
    ports: [
      SCLK: :sclk,
      ECLK: :eclk,
      DQSR90: :dqsr90,
      D: :d,
      RST: :rst,
      RDPNTR2: :rdpntr2,
      RDPNTR1: :rdpntr1,
      RDPNTR0: :rdpntr0,
      WRPNTR2: :wrpntr2,
      WRPNTR1: :wrpntr1,
      WRPNTR0: :wrpntr0,
      Q3: :q3,
      Q2: :q2,
      Q1: :q1,
      Q0: :q0,
      QWL: :qwl
    ]
end
