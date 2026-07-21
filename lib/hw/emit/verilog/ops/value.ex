defmodule Hw.Emit.Verilog.Ops.Value do
  @moduledoc "Value emission helpers for Verilog."

  alias Hw.IR.Types.{Signal, Const, ParamRef}

  def emit_value(%Signal{name: name}), do: Atom.to_string(name)

  def emit_value(%ParamRef{name: name}), do: Atom.to_string(name)

  def emit_value(%Const{value: :z, width: width}) do
    "#{width}'bz"
  end

  def emit_value(%Const{value: val, width: width, signed: signed}) do
    sign_prefix = if signed == :signed, do: "$signed(", else: ""
    sign_suffix = if signed == :signed, do: ")", else: ""
    "#{sign_prefix}#{width}'d#{val}#{sign_suffix}"
  end

  def emit_value(atom) when is_atom(atom), do: Atom.to_string(atom)

  def emit_value(other) do
    raise "Cannot emit value: #{inspect(other)}"
  end

  def get_width(%Signal{width: w}), do: w
  def get_width(%Const{width: w}), do: w
  def get_width(%ParamRef{}), do: 32  # Params are 32-bit by default
end
