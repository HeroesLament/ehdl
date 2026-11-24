defmodule Hw.ECP5.OSHX2A do
  @moduledoc """
  ECP5 `OSHX2A`. Output shift x2: two bits per SCLK on ECLK, the DDR write-data path.

  **Builds through oxibit-ecp5; on the ULX3S-85F with `designs/misc_probe.v` (check the latest oracle run before relying on it).**

  Generated from oxibit-ecp5's primitive declarations (ports) and the
  yosys Lattice cell library (parameter defaults).
  """

  use Hw.Component

  param :GSR, default: "DISABLED"

  input :d1, 1
  input :d0, 1
  input :sclk, 1
  input :eclk, 1
  input :rst, 1
  output :q, 1

  blackbox :oshx2a, "OSHX2A",
    params: [
      GSR: :GSR
    ],
    ports: [
      D1: :d1,
      D0: :d0,
      SCLK: :sclk,
      ECLK: :eclk,
      RST: :rst,
      Q: :q
    ]
end
