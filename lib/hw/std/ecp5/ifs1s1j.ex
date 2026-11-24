defmodule Hw.ECP5.IFS1S1J do
  @moduledoc """
  ECP5 `IFS1S1J`. Input latch at the IOLOGIC (transparent while SCLK is high), sync preset.

  **Proven on the ULX3S-85F through oxibit-ecp5 (`designs/iol_probe.v`, JTAG oracle), not through this wrapper.**

  Generated from oxibit-ecp5's primitive declarations (ports) and the
  yosys Lattice cell library (parameter defaults).
  """

  use Hw.Component

  input :pd, 1
  input :d, 1
  input :sclk, 1
  output :q, 1

  blackbox :ifs1s1j, "IFS1S1J",
    ports: [
      PD: :pd,
      D: :d,
      SCLK: :sclk,
      Q: :q
    ]
end
