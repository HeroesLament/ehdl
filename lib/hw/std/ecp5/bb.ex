defmodule Hw.ECP5.BB do
  @moduledoc """
  ECP5 bidirectional pad buffer.

  `i` drives the pad, `t` high releases it (Z), `o` reads it back, `b` is the
  pad itself and must be an `inout` of the top. The drive and read-back paths
  are separate wires through the PIO; a plain `assign pad = oe ? d : 'bz`
  loop does not survive on silicon.

  Every `tristate` statement lowers to this primitive (the Verilog emitter
  calls `verilog_lines/5`), so most designs never instantiate it. Instantiate
  it directly to get at the pad from a component that does its own enable
  logic. Pull-ups and pull-downs go in the `.lpf` (`IOBUF PORT ...
  PULLMODE=UP`), not on the primitive.

      instance :sda_pad, Hw.ECP5.BB, i: :sda_out, t: :sda_release, o: :sda_in, b: :sda
  """

  use Hw.Component

  input :i, 1
  input :t, 1
  output :o, 1
  inout :b, 1

  blackbox :bb, "BB",
    ports: [
      I: :i,
      T: :t,
      O: :o,
      B: :b
    ]

  @doc """
  Verilog lines for one BB instance, used by the `tristate` lowering in
  `Hw.Emit.Verilog.Sequential`. Arguments are Verilog expressions.
  """
  @spec verilog_lines(String.t(), String.t(), String.t(), String.t(), String.t()) :: [String.t()]
  def verilog_lines(inst, i, t, b, o) do
    [
      "  BB #{inst} (",
      "    .I(#{i}),",
      "    .T(#{t}),",
      "    .B(#{b}),",
      "    .O(#{o})",
      "  );"
    ]
  end
end
