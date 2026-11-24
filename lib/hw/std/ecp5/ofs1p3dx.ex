defmodule Hw.ECP5.OFS1P3DX do
  @moduledoc """
  ECP5 `OFS1P3DX`. Output-register flop at the IOLOGIC (output or tristate by where Q goes): async clear.

  **Proven on the ULX3S-85F through oxibit-ecp5 (`designs/iol_probe.v`, JTAG oracle), not through this wrapper.**

  Generated from oxibit-ecp5's primitive declarations (ports) and the
  yosys Lattice cell library (parameter defaults).
  """

  use Hw.Component

  param :GSR, default: "ENABLED"

  input :cd, 1
  input :d, 1
  input :sp, 1
  input :sclk, 1
  output :q, 1

  blackbox :ofs1p3dx, "OFS1P3DX",
    params: [
      GSR: :GSR
    ],
    ports: [
      CD: :cd,
      D: :d,
      SP: :sp,
      SCLK: :sclk,
      Q: :q
    ]
end
