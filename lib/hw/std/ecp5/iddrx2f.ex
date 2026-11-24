defmodule Hw.ECP5.IDDRX2F do
  @moduledoc """
  ECP5 `IDDRX2F`. 4:1 input gearbox: D sampled on ECLK, four bits per SCLK (SCLK = ECLK / 2 from `Hw.ECP5.CLKDIVF`).

  **Proven on the ULX3S-85F through oxibit-ecp5 (`designs/gear_probe.v`, JTAG oracle), not through this wrapper.**

  Generated from oxibit-ecp5's primitive declarations (ports) and the
  yosys Lattice cell library (parameter defaults).
  """

  use Hw.Component

  param :GSR, default: "DISABLED"

  input :d, 1
  input :sclk, 1
  input :eclk, 1
  input :rst, 1
  input :alignwd, 1
  output :q3, 1
  output :q2, 1
  output :q1, 1
  output :q0, 1

  blackbox :iddrx2f, "IDDRX2F",
    params: [
      GSR: :GSR
    ],
    ports: [
      D: :d,
      SCLK: :sclk,
      ECLK: :eclk,
      RST: :rst,
      ALIGNWD: :alignwd,
      Q3: :q3,
      Q2: :q2,
      Q1: :q1,
      Q0: :q0
    ]
end
