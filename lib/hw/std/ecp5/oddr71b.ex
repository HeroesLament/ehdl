defmodule Hw.ECP5.ODDR71B do
  @moduledoc """
  ECP5 `ODDR71B`. 7:1 output gearbox (CLKDIVF DIV 3.5). A or C pads only.

  **Proven on the ULX3S-85F through oxibit-ecp5 (`designs/gear_probe.v`, JTAG oracle), not through this wrapper.**

  Generated from oxibit-ecp5's primitive declarations (ports) and the
  yosys Lattice cell library (parameter defaults).
  """

  use Hw.Component

  param :GSR, default: "DISABLED"

  input :sclk, 1
  input :eclk, 1
  input :rst, 1
  input :d6, 1
  input :d5, 1
  input :d4, 1
  input :d3, 1
  input :d2, 1
  input :d1, 1
  input :d0, 1
  output :q, 1

  blackbox :oddr71b, "ODDR71B",
    params: [
      GSR: :GSR
    ],
    ports: [
      SCLK: :sclk,
      ECLK: :eclk,
      RST: :rst,
      D6: :d6,
      D5: :d5,
      D4: :d4,
      D3: :d3,
      D2: :d2,
      D1: :d1,
      D0: :d0,
      Q: :q
    ]
end
