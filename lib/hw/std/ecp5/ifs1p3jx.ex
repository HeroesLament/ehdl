defmodule Hw.ECP5.IFS1P3JX do
  @moduledoc """
  ECP5 `IFS1P3JX`. Input-register flop at the IOLOGIC: sync preset (PD), clock enable (SP).

  **Proven on the ULX3S-85F through oxibit-ecp5 (`designs/iol_probe.v`, JTAG oracle), not through this wrapper.**

  Generated from oxibit-ecp5's primitive declarations (ports) and the
  yosys Lattice cell library (parameter defaults).
  """

  use Hw.Component

  param :GSR, default: "ENABLED"

  input :pd, 1
  input :d, 1
  input :sp, 1
  input :sclk, 1
  output :q, 1

  blackbox :ifs1p3jx, "IFS1P3JX",
    params: [
      GSR: :GSR
    ],
    ports: [
      PD: :pd,
      D: :d,
      SP: :sp,
      SCLK: :sclk,
      Q: :q
    ]
end
