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

  # casez form of a case-derived mux. Semantically identical to emit_mux_always,
  # but expressed as one casez the synthesizer decodes ONCE and parallelizes.
  #
  # Arm order is preserved. casez is first-match-wins, which is now what
  # Ops.Mux means everywhere (see emit_mux_always). This used to emit the arms
  # REVERSED, to match an emit_mux_always that was last-match-wins — a
  # divergence that made the two Verilog forms of the same op disagree with each
  # other and with both simulators.
  defp emit_casez(%Mux{output: out, selector: sel, cases: cases, patterns: patterns, default: default}) do
    arms =
      cases
      |> Enum.zip(patterns)
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

  # FIRST-match-wins, as an else-if chain.
  #
  # `Ops.Mux.cases` is an ordered, priority-encoded list: the first arm whose
  # condition holds supplies the value. Every other lowering of it already
  # agreed on that — the ternary form (<=2 arms), the Elixir interpreter
  # (Enum.find_value), the Rust NIF (iter().find_map) and casez. This one did
  # not: it emitted a flat sequence of independent `if`s over a pre-assigned
  # default, so the LAST matching arm won.
  #
  # That divergence is a sim/synth split, which is the worst kind of bug this
  # compiler can produce — the design passes simulation and misbehaves on
  # silicon. A trailing always-true arm (an `<<_::N>>` catch-all) clobbered
  # every specific arm above it back to the hold value, which silently pinned
  # the whole USB CDC dispatch on real hardware while every test passed. The
  # elaborator worked around it by rerouting catch-all arms into the default
  # slot; with the semantics unified here, that workaround is no longer load
  # bearing and no longer hides a leading catch-all's shadowing.
  defp emit_mux_always(out, cases, default) do
    arms =
      cases
      |> Enum.with_index()
      |> Enum.map(fn {{cond, val}, i} ->
        keyword = if i == 0, do: "if", else: "else if"
        "    #{keyword} (#{emit_value(cond)}) #{out.name} = #{emit_value(val)};"
      end)

    Enum.join(
      ["  always @(*) begin", "    #{out.name} = #{emit_value(default)};"] ++
        arms ++ ["  end"],
      "\n"
    )
  end
end
