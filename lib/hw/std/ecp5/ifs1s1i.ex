defmodule Hw.ECP5.IFS1S1I do
  @moduledoc """
  ECP5 `IFS1S1I`. Input latch at the IOLOGIC (transparent while SCLK is high), sync clear.

  **Proven on the ULX3S-85F through oxibit-ecp5 (`designs/iol_probe.v`, JTAG oracle), not through this wrapper.**

  Generated from oxibit-ecp5's primitive declarations (ports) and the
  yosys Lattice cell library (parameter defaults).
  """

  use Hw.Component

  input :cd, 1
  input :d, 1
  input :sclk, 1
  output :q, 1

  blackbox :ifs1s1i, "IFS1S1I",
    ports: [
      CD: :cd,
      D: :d,
      SCLK: :sclk,
      Q: :q
    ]
end
