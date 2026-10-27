defmodule Hw.Analysis.Structure do
  @moduledoc """
  Structural views of an elaborated (flattened) `Hw.IR.Design` for the
  structural analysis rules.

  Names in the flattened IR are the names the flat Verilog emitter writes,
  so anything found here can be looked up in `mix hw.census` output for the
  synthesised netlist.
  """

  alias Hw.Analysis.Location
  alias Hw.IR.Ops.{Assign, Mux, Reg}
  alias Hw.IR.Types.{Const, Signal}

  @doc "Map of signal name to the op that drives it."
  @spec drivers(Hw.IR.Design.t()) :: %{atom() => struct()}
  def drivers(%{ops: ops}) do
    Enum.reduce(ops, %{}, fn op, acc ->
      case Map.get(op, :output) do
        %Signal{name: n} -> Map.put(acc, n, op)
        _ -> acc
      end
    end)
  end

  @doc """
  Number of op inputs that reference each signal name (a signal used twice
  by one op counts twice). Mux conditions and values both count.
  """
  @spec use_counts(Hw.IR.Design.t()) :: %{atom() => non_neg_integer()}
  def use_counts(%{ops: ops}) do
    Enum.reduce(ops, %{}, fn op, acc ->
      op
      |> inputs()
      |> Enum.reduce(acc, fn
        %Signal{name: n}, acc -> Map.update(acc, n, 1, &(&1 + 1))
        _, acc -> acc
      end)
    end)
  end

  @doc "The input values of an op (signals and constants), flattened."
  @spec inputs(struct()) :: [term()]
  def inputs(%Mux{cases: cases, default: d}) do
    Enum.flat_map(cases, fn {c, v} -> [c, v] end) ++ [d]
  end

  def inputs(op) do
    op
    |> Map.from_struct()
    |> Enum.reject(fn {k, _} -> k in [:output, :output_re, :output_im, :clock] end)
    |> Enum.flat_map(fn {_k, v} -> List.wrap(v) end)
  end

  @doc """
  The chain of muxes feeding a register: start at its D input and follow
  each mux's `default` while it is driven by another mux. Outermost first.
  Returns `{muxes, tail}` where `tail` is what the last default resolves to.
  """
  @spec reg_chain(Reg.t(), map()) :: {[Mux.t()], term()}
  def reg_chain(%Reg{input: input}, drivers), do: walk_chain(input, drivers, [], 0)

  defp walk_chain(%Signal{name: n} = s, drivers, acc, depth) when depth < 64 do
    case Map.get(drivers, n) do
      %Mux{default: d} = m -> walk_chain(d, drivers, [m | acc], depth + 1)
      %Assign{input: i} -> walk_chain(i, drivers, acc, depth + 1)
      _ -> {Enum.reverse(acc), s}
    end
  end

  defp walk_chain(other, _drivers, acc, _depth), do: {Enum.reverse(acc), other}

  @doc """
  True when a register has a reset: a reset value, an async reset, or a
  constant assigned anywhere in its input mux chain (a sync clear).
  """
  @spec reset?(Reg.t(), map()) :: boolean()
  def reset?(%Reg{reset_value: rv, async_reset: ar} = r, drivers) do
    {muxes, _tail} = reg_chain(r, drivers)

    rv != nil or ar != nil or
      Enum.any?(muxes, fn %Mux{cases: cases} -> Enum.any?(cases, &match?({_, %Const{}}, &1)) end)
  end

  @doc "Bit width of a signal or constant (0 when unknown)."
  def width(%Signal{width: w}) when is_integer(w), do: w
  def width(%Const{width: w}) when is_integer(w), do: w
  def width(_), do: 0

  @doc "Source location of a signal, or a fallback naming the design."
  @spec location(Hw.IR.Design.t(), atom()) :: Location.t()
  def location(%{signals: signals, name: design}, name) do
    Enum.find_value(signals, fn s -> if s.name == name, do: s.source_location end) ||
      %Location{file: "unknown", line: 0, module: design}
  end
end
