defmodule Hw.Emit.Verilog.Ops.Structure do
  @moduledoc "Verilog emission for structural operations."

  alias Hw.IR.Ops.{Mux, Assign}
  import Hw.Emit.Verilog.Ops.Value, only: [emit_value: 1]

  def emit(%Assign{output: out, input: inp}) do
    "  assign #{out.name} = #{emit_value(inp)};"
  end

  def emit(%Mux{output: out, cases: cases, default: default}) do
    if length(cases) <= 2 do
      expr = emit_mux_ternary(cases, default)
      "  assign #{out.name} = #{expr};"
    else
      emit_mux_always(out, cases, default)
    end
  end

  # --- Mux Helpers ---

  defp emit_mux_ternary([], default) do
    emit_value(default)
  end
  defp emit_mux_ternary([{cond, val} | rest], default) do
    "#{emit_value(cond)} ? #{emit_value(val)} : #{emit_mux_ternary(rest, default)}"
  end

  defp emit_mux_always(out, cases, default) do
    lines = [
      "  always @(*) begin",
      "    #{out.name} = #{emit_value(default)};"
    ]

    case_lines = Enum.map(cases, fn {cond, val} ->
      "    if (#{emit_value(cond)}) #{out.name} = #{emit_value(val)};"
    end)

    Enum.join(lines ++ case_lines ++ ["  end"], "\n")
  end
end
