defmodule Hw.Emit.Verilog.Ops.Compare do
  @moduledoc "Verilog emission for comparison operations."

  alias Hw.IR.Ops.{Eq, Neq, Lt, Gt, Lte, Gte}
  import Hw.Emit.Verilog.Ops.Value, only: [emit_value: 1]

  def emit(%Eq{output: out, a: a, b: b}) do
    "  assign #{out.name} = #{emit_value(a)} == #{emit_value(b)};"
  end

  def emit(%Neq{output: out, a: a, b: b}) do
    "  assign #{out.name} = #{emit_value(a)} != #{emit_value(b)};"
  end

  def emit(%Lt{output: out, a: a, b: b}) do
    "  assign #{out.name} = #{emit_value(a)} < #{emit_value(b)};"
  end

  def emit(%Gt{output: out, a: a, b: b}) do
    "  assign #{out.name} = #{emit_value(a)} > #{emit_value(b)};"
  end

  def emit(%Lte{output: out, a: a, b: b}) do
    "  assign #{out.name} = #{emit_value(a)} <= #{emit_value(b)};"
  end

  def emit(%Gte{output: out, a: a, b: b}) do
    "  assign #{out.name} = #{emit_value(a)} >= #{emit_value(b)};"
  end
end
