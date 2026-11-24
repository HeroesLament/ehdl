defmodule Hw.ECP5.DPR16X4C do
  @moduledoc """
  ECP5 `DPR16X4C`. 16x4 distributed RAM: async read on RAD, write on WCK when WRE.

  **Proven on the ULX3S-85F through oxibit-ecp5 (`designs/lutram_probe.v`), not through this wrapper.**

  Generated from oxibit-ecp5's primitive declarations (ports) and the
  yosys Lattice cell library (parameter defaults).
  """

  use Hw.Component

  param :INITVAL, default: "0x0000000000000000"

  input :di0, 1
  input :di1, 1
  input :di2, 1
  input :di3, 1
  input :wad0, 1
  input :wad1, 1
  input :wad2, 1
  input :wad3, 1
  input :wre, 1
  input :wck, 1
  input :rad0, 1
  input :rad1, 1
  input :rad2, 1
  input :rad3, 1
  output :do0, 1
  output :do1, 1
  output :do2, 1
  output :do3, 1

  blackbox :dpr16x4c, "DPR16X4C",
    params: [
      INITVAL: :INITVAL
    ],
    ports: [
      DI0: :di0,
      DI1: :di1,
      DI2: :di2,
      DI3: :di3,
      WAD0: :wad0,
      WAD1: :wad1,
      WAD2: :wad2,
      WAD3: :wad3,
      WRE: :wre,
      WCK: :wck,
      RAD0: :rad0,
      RAD1: :rad1,
      RAD2: :rad2,
      RAD3: :rad3,
      DO0: :do0,
      DO1: :do1,
      DO2: :do2,
      DO3: :do3
    ]
end
