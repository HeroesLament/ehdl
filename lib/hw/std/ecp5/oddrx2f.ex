defmodule Hw.ECP5.ODDRX2F do
  @moduledoc """
  ECP5 `ODDRX2F`. 1:4 output gearbox: four bits per SCLK shifted out on ECLK.

  **Proven on the ULX3S-85F through oxibit-ecp5 (`designs/gear_probe.v`, JTAG oracle), not through this wrapper.**

  Generated from oxibit-ecp5's primitive declarations (ports) and the
  yosys Lattice cell library (parameter defaults).
  """

  use Hw.Component

  param :GSR, default: "DISABLED"

  input :sclk, 1
  input :eclk, 1
  input :rst, 1
  input :d3, 1
  input :d2, 1
  input :d1, 1
  input :d0, 1
  output :q, 1

  blackbox :oddrx2f, "ODDRX2F",
    params: [
      GSR: :GSR
    ],
    ports: [
      SCLK: :sclk,
      ECLK: :eclk,
      RST: :rst,
      D3: :d3,
      D2: :d2,
      D1: :d1,
      D0: :d0,
      Q: :q
    ]
end
