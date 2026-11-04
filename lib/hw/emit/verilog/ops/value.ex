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
    "#{sign_prefix}#{width}'d#{lit(val, width)}#{sign_suffix}"
  end

  @doc """
  Decimal digits of an integer constant for a sized `'d` literal. A negative
  value (e.g. a folded `0 - 17003`) becomes its two's complement at `width`:
  `32'd-17003` is not Verilog.
  """
  def lit(val, width) when is_integer(val) and val < 0 and is_integer(width) and width > 0,
    do: Bitwise.band(val, Bitwise.bsl(1, width) - 1)

  def lit(val, _width), do: val

  def emit_value(atom) when is_atom(atom), do: Atom.to_string(atom)

  def emit_value(other) do
    raise "Cannot emit value: #{inspect(other)}"
  end

  def get_width(%Signal{width: w}), do: w
  def get_width(%Const{width: w}), do: w
  def get_width(%ParamRef{}), do: 32  # Params are 32-bit by default
end
