defmodule Hw.Emit.Verilog.Ops.Bits do
  @moduledoc "Verilog emission for bit manipulation operations."

  alias Hw.IR.Ops.{Slice, Concat, Replicate, Cast}
  alias Hw.IR.Types.Const
  import Hw.Emit.Verilog.Ops.Value, only: [emit_value: 1, get_width: 1]

  # Slicing a constant is illegal Verilog: `32'd0[6:0]` is a syntax error (bit-select
  # is only valid on a net/reg identifier, not a sized literal). A slice of a constant
  # is itself a constant, so fold it at emit time into a correctly-sized literal.
  # This keeps `{0[6..0], x}`-style source (legal in the language, sims fine) from
  # ever producing illegal Verilog — the fix belongs in the backend, not user HDL.
  def emit(%Slice{output: out, input: %Const{value: v} = c, hi: hi, lo: lo})
      when is_integer(v) do
    hi_i = index_int(hi)
    lo_i = index_int(lo)

    if is_integer(hi_i) and is_integer(lo_i) do
      width  = hi_i - lo_i + 1
      masked = v |> Bitwise.bsr(lo_i) |> Bitwise.band(Bitwise.bsl(1, width) - 1)
      "  assign #{out.name} = #{width}'d#{masked};"
    else
      # Dynamic bit-select of a constant (variable index into a literal) has no
      # portable single-expression form. It does not arise from the current
      # elaborator, so raise rather than silently emit dialect-specific Verilog.
      unselectable!(out, c)
    end
  end

  def emit(%Slice{output: out, input: inp, hi: hi, lo: lo}) do
    ensure_selectable!(out, inp)
    "  assign #{out.name} = #{emit_value(inp)}[#{emit_index(hi)}:#{emit_index(lo)}];"
  end

  def emit(%Concat{output: out, inputs: inputs}) do
    # IR stores inputs MSB-first (matching Verilog convention).
    parts = Enum.map(inputs, &emit_value/1) |> Enum.join(", ")
    "  assign #{out.name} = {#{parts}};"
  end

  def emit(%Replicate{output: out, input: inp, count: count}) do
    "  assign #{out.name} = {#{count}{#{emit_value(inp)}}};"
  end

  def emit(%Cast{output: out, input: inp, kind: kind}) do
    cast_expr = case kind do
      :truncate -> emit_value(inp) <> "[#{out.width - 1}:0]"
      :zero_extend -> "{{#{out.width - get_width(inp)}{1'b0}}, #{emit_value(inp)}}"
      :sign_extend -> "{{#{out.width - get_width(inp)}{#{emit_value(inp)}[#{get_width(inp) - 1}]}}, #{emit_value(inp)}}"
      :reinterpret -> emit_value(inp)
    end
    "  assign #{out.name} = #{cast_expr};"
  end

  # Emit slice indices as plain integers, not sized constants like 32'd5.
  # Sized form is legal Verilog but noisy and confuses some tools.
  defp emit_index(%Hw.IR.Types.Const{value: v}), do: Integer.to_string(v)
  defp emit_index(other), do: emit_value(other)

  # Extract an integer slice index when it is a concrete constant, else :dynamic.
  defp index_int(%Const{value: v}) when is_integer(v), do: v
  defp index_int(v) when is_integer(v), do: v
  defp index_int(_), do: :dynamic

  # A Verilog bit-select `[hi:lo]` is legal ONLY on a net/reg identifier — never on a
  # literal, concat, or sub-expression — and this is true across every dialect
  # (Verilog-2001, SystemVerilog, Verilator, Icarus). The elaborator materializes
  # every non-trivial slice operand into a named signal, so a Slice input reaching
  # here should always be a Signal. If one is not, refuse to emit dialect-specific
  # code (e.g. SystemVerilog's `{...}[i]`): raise a clear backend error instead, so
  # the gap is fixed in the IR/elaborator rather than papered over with non-portable
  # Verilog. Constants are handled by folding in the Slice clause above.
  defp ensure_selectable!(_out, %Hw.IR.Types.Signal{}), do: :ok
  defp ensure_selectable!(out, inp), do: unselectable!(out, inp)

  defp unselectable!(out, inp) do
    raise """
    Verilog backend: cannot bit-select a non-identifier operand for signal \
    `#{inspect(out.name)}`. Bit-select is only portable on a net/reg identifier, \
    but the Slice input is: #{inspect(inp)}. Materialize this operand into a named \
    signal in the elaborator before slicing it (a slice of a constant should be \
    folded instead).
    """
  end
end
