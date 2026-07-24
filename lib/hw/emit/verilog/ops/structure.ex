defmodule Hw.Emit.Verilog.Ops.Structure do
  @moduledoc "Verilog emission for structural operations."

  import Bitwise
  alias Hw.IR.Ops.{Mux, Assign}
  import Hw.Emit.Verilog.Ops.Value, only: [emit_value: 1]

  def emit(%Assign{output: out, input: inp}) do
    "  assign #{out.name} = #{emit_value(inp)};"
  end

  # Arity-1 Mux emit: priority form (casez off). Preserves existing callers.
  def emit(%Mux{} = op), do: emit_priority(op)

  # Arity-2 Mux emit: choose casez vs priority. casez only when the caller asks
  # for it AND the mux carries casez metadata AND it is a >2-arm mux (the
  # always-block form; <=2 stays a ternary, already optimal and first-match).
  def emit(%Mux{selector: sel, patterns: pats, cases: cases} = op, true)
      when not is_nil(sel) and not is_nil(pats) and length(cases) > 2 do
    emit_casez(op)
  end

  def emit(%Mux{} = op, _casez?), do: emit_priority(op)

  # --- Mux Helpers ---

  defp emit_priority(%Mux{output: out, cases: cases, default: default}) do
    if length(cases) <= 2 do
      expr = emit_mux_ternary(cases, default)
      "  assign #{out.name} = #{expr};"
    else
      emit_mux_always(out, cases, default)
    end
  end

  # casez form of a case-derived mux. Semantically identical to emit_mux_always
  # (out = default; then per-arm overrides) but expressed as one casez the
  # synthesizer decodes ONCE and parallelizes. emit_mux_always is LAST-match-wins
  # (each `if` may override an earlier one); casez is FIRST-match-wins, so the
  # arms are presented in REVERSE order to preserve identical behaviour.
  defp emit_casez(%Mux{output: out, selector: sel, cases: cases, patterns: patterns, default: default}) do
    arms =
      cases
      |> Enum.zip(patterns)
      |> Enum.reverse()
      |> Enum.map(fn {{_cond, val}, {value, care, width}} ->
        "      #{casez_bits(value, care, width)}: #{out.name} = #{emit_value(val)};"
      end)

    Enum.join(
      [
        "  always @(*) begin",
        "    #{out.name} = #{emit_value(default)};",
        "    casez (#{sel.name})"
      ] ++ arms ++ [
        "    endcase",
        "  end"
      ],
      "\n"
    )
  end

  # Render a {value, care_mask, width} pattern as a sized Verilog casez literal,
  # MSB-first: a care bit becomes its 0/1 value, a don't-care bit becomes `?`.
  defp casez_bits(value, care, width) do
    bits =
      for i <- (width - 1)..0//-1 do
        if ((care >>> i) &&& 1) == 1 do
          Integer.to_string((value >>> i) &&& 1)
        else
          "?"
        end
      end

    "#{width}'b" <> Enum.join(bits)
  end

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
