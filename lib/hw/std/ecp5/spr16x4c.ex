defmodule Hw.ECP5.SPR16X4C do
  @moduledoc """
  ECP5 `SPR16X4C`. 16x4 single-port distributed RAM: async read on AD, write on CK when WRE.

  **Proven on the ULX3S-85F through oxibit-ecp5 (`designs/lutram_probe.v`), not through this wrapper.**

  Generated from oxibit-ecp5's primitive declarations (ports) and the
  yosys Lattice cell library (parameter defaults).
  """

  use Hw.Component

  input :di0, 1
  input :di1, 1
  input :di2, 1
  input :di3, 1
  input :ad0, 1
  input :ad1, 1
  input :ad2, 1
  input :ad3, 1
  input :wre, 1
  input :ck, 1
  output :do0, 1
  output :do1, 1
  output :do2, 1
  output :do3, 1

  blackbox :spr16x4c, "SPR16X4C",
    ports: [
      DI0: :di0,
      DI1: :di1,
      DI2: :di2,
      DI3: :di3,
      AD0: :ad0,
      AD1: :ad1,
      AD2: :ad2,
      AD3: :ad3,
      WRE: :wre,
      CK: :ck,
      DO0: :do0,
      DO1: :do1,
      DO2: :do2,
      DO3: :do3
    ]
end
