defmodule Hw.ECP5.IDDR71B do
  @moduledoc """
  ECP5 `IDDR71B`. 7:1 input gearbox (CLKDIVF DIV 3.5), for 7:1 LVDS video links. A or C pads only.

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
  output :q6, 1
  output :q5, 1
  output :q4, 1
  output :q3, 1
  output :q2, 1
  output :q1, 1
  output :q0, 1

  blackbox :iddr71b, "IDDR71B",
    params: [
      GSR: :GSR
    ],
    ports: [
      D: :d,
      SCLK: :sclk,
      ECLK: :eclk,
      RST: :rst,
      ALIGNWD: :alignwd,
      Q6: :q6,
      Q5: :q5,
      Q4: :q4,
      Q3: :q3,
      Q2: :q2,
      Q1: :q1,
      Q0: :q0
    ]
end
