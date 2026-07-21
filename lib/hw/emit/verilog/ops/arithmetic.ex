defmodule Hw.Emit.Verilog.Ops.Arithmetic do
  @moduledoc "Verilog emission for arithmetic operations."

  alias Hw.IR.Ops.{Add, Sub, Mul, Neg, Div, Mod, Abs, Min, Max, MulRound, Clog2}
  alias Hw.IR.Types.Signal
  import Hw.Emit.Verilog.Ops.Value, only: [emit_value: 1, get_width: 1]

  def emit(%Add{output: out, a: a, b: b}) do
    "  assign #{out.name} = #{emit_value(a)} + #{emit_value(b)};"
  end

  def emit(%Sub{output: out, a: a, b: b}) do
    "  assign #{out.name} = #{emit_value(a)} - #{emit_value(b)};"
  end

  def emit(%Mul{output: out, a: a, b: b}) do
    "  assign #{out.name} = #{emit_value(a)} * #{emit_value(b)};"
  end

  def emit(%Neg{output: out, input: inp}) do
    "  assign #{out.name} = -#{emit_value(inp)};"
  end

  def emit(%Div{output: out, a: a, b: b}) do
    "  assign #{out.name} = #{emit_value(a)} / #{emit_value(b)};"
  end

  def emit(%Mod{output: out, a: a, b: b}) do
    "  assign #{out.name} = #{emit_value(a)} % #{emit_value(b)};"
  end

  def emit(%Abs{output: out, input: inp}) do
    width = get_width(inp)
    val = emit_value(inp)
    # abs(x) = x[MSB] ? -x : x
    "  assign #{out.name} = #{val}[#{width - 1}] ? -#{val} : #{val};"
  end

  def emit(%Min{output: out, a: a, b: b}) do
    # Use signed comparison if either operand is signed
    signed = is_signed?(a) or is_signed?(b)
    a_val = if signed, do: "$signed(#{emit_value(a)})", else: emit_value(a)
    b_val = if signed, do: "$signed(#{emit_value(b)})", else: emit_value(b)
    "  assign #{out.name} = (#{a_val} < #{b_val}) ? #{emit_value(a)} : #{emit_value(b)};"
  end

  def emit(%Max{output: out, a: a, b: b}) do
    # Use signed comparison if either operand is signed
    signed = is_signed?(a) or is_signed?(b)
    a_val = if signed, do: "$signed(#{emit_value(a)})", else: emit_value(a)
    b_val = if signed, do: "$signed(#{emit_value(b)})", else: emit_value(b)
    "  assign #{out.name} = (#{a_val} > #{b_val}) ? #{emit_value(a)} : #{emit_value(b)};"
  end

  def emit(%MulRound{output: out, a: a, b: b, shift: shift}) do
    # (a * b + (1 << (shift-1))) >>> shift
    # Use $signed for arithmetic shift
    round_val = Bitwise.bsl(1, shift - 1)
    signed = is_signed?(a) or is_signed?(b)
    if signed do
      "  assign #{out.name} = ($signed(#{emit_value(a)}) * $signed(#{emit_value(b)}) + #{round_val}) >>> #{shift};"
    else
      "  assign #{out.name} = (#{emit_value(a)} * #{emit_value(b)} + #{round_val}) >> #{shift};"
    end
  end

  def emit(%Clog2{output: out, input: input}) do
    "  assign #{out.name} = $clog2(#{emit_value(input)});"
  end

  defp is_signed?(%Signal{signed: :signed}), do: true
  defp is_signed?(_), do: false
end
