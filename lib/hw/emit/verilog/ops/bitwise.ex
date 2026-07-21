defmodule Hw.Emit.Verilog.Ops.Bitwise do
  @moduledoc "Verilog emission for bitwise operations."

  alias Hw.IR.Ops.{BitAnd, BitOr, BitNot, BitXor, Shl, Shr, Shra,
                   ReduceAnd, ReduceOr, ReduceXor, Popcount,
                   SignExtend, ZeroExtend, ReverseBits}
  import Hw.Emit.Verilog.Ops.Value, only: [emit_value: 1, get_width: 1]

  def emit(%BitAnd{output: out, a: a, b: b}) do
    "  assign #{out.name} = #{emit_value(a)} & #{emit_value(b)};"
  end

  def emit(%BitOr{output: out, a: a, b: b}) do
    "  assign #{out.name} = #{emit_value(a)} | #{emit_value(b)};"
  end

  def emit(%BitNot{output: out, input: inp}) do
    "  assign #{out.name} = ~#{emit_value(inp)};"
  end

  def emit(%BitXor{output: out, a: a, b: b}) do
    "  assign #{out.name} = #{emit_value(a)} ^ #{emit_value(b)};"
  end

  def emit(%Shl{output: out, a: a, b: b}) do
    "  assign #{out.name} = #{emit_value(a)} << #{emit_value(b)};"
  end

  # Logical shift right
  def emit(%Shr{output: out, a: a, b: b}) do
    "  assign #{out.name} = #{emit_value(a)} >> #{emit_value(b)};"
  end

  # Arithmetic shift right (sign-extending)
  def emit(%Shra{output: out, a: a, b: b}) do
    "  assign #{out.name} = $signed(#{emit_value(a)}) >>> #{emit_value(b)};"
  end

  # Reduction operations
  def emit(%ReduceAnd{output: out, input: inp}) do
    "  assign #{out.name} = &#{emit_value(inp)};"
  end

  def emit(%ReduceOr{output: out, input: inp}) do
    "  assign #{out.name} = |#{emit_value(inp)};"
  end

  def emit(%ReduceXor{output: out, input: inp}) do
    "  assign #{out.name} = ^#{emit_value(inp)};"
  end

  # Population count - sum of all bits
  def emit(%Popcount{output: out, input: inp}) do
    width = get_width(inp)
    val = emit_value(inp)
    # Generate: input[0] + input[1] + ... + input[N-1]
    bit_refs = Enum.map(0..(width - 1), fn i -> "#{val}[#{i}]" end)
    sum = Enum.join(bit_refs, " + ")
    "  assign #{out.name} = #{sum};"
  end

  # Sign extend - replicate sign bit to fill upper bits
  def emit(%SignExtend{output: out, input: inp, width: target_width}) do
    input_width = get_width(inp)
    val = emit_value(inp)
    extend_bits = target_width - input_width

    if extend_bits <= 0 do
      # No extension needed (or truncation - just assign)
      "  assign #{out.name} = #{val};"
    else
      # {{extend_bits{val[MSB]}}, val}
      "  assign #{out.name} = {{#{extend_bits}{#{val}[#{input_width - 1}]}}, #{val}};"
    end
  end

  # Zero extend - pad with zeros
  def emit(%ZeroExtend{output: out, input: inp, width: target_width}) do
    input_width = get_width(inp)
    val = emit_value(inp)
    extend_bits = target_width - input_width

    if extend_bits <= 0 do
      "  assign #{out.name} = #{val};"
    else
      "  assign #{out.name} = {#{extend_bits}'b0, #{val}};"
    end
  end

  # Reverse bits - flip bit order
  def emit(%ReverseBits{output: out, input: inp}) do
    width = get_width(inp)
    val = emit_value(inp)
    # Generate: {val[0], val[1], ..., val[N-1]} (LSB first = reversed)
    bit_refs = Enum.map(0..(width - 1), fn i -> "#{val}[#{i}]" end)
    reversed = Enum.join(bit_refs, ", ")
    "  assign #{out.name} = {#{reversed}};"
  end
end
