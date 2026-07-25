defmodule Hw.Compile.InferWidths do
  @moduledoc """
  Resolve `:infer`-width signals to concrete integer widths.

  A signal declared with width `:infer` (e.g. `wire :sum, :infer`, or a
  pipeline stage output) takes the width of its single driving expression.
  Resolution runs *before* the main logic elaboration so that by the time
  registers/assignments are built, every width is a concrete integer and the
  existing width-match validation never sees an `:infer` sentinel.

  Widths are computed by **reusing** `Hw.Compile.Elaborate.Expr.build_expr/5`
  on each driver expression — the exact inference the elaborator applies
  everywhere else — so there is no parallel set of width rules to drift out of
  sync. Because a driver may reference another `:infer` signal (a pipeline
  `noise` reading `noise_sum`), resolution proceeds in dataflow (topological)
  order; a cyclic `:infer` dependency is an error.

  This is a no-op with zero cost for designs that declare no `:infer` signals.
  """

  alias Hw.IR.Design
  alias Hw.IR.Types.{Signal, Const}
  alias Hw.Compile.Elaborate.Expr
  alias Hw.Compile.Elaborate.ElabError

  @doc """
  Return `signal_map` with every `:infer` width replaced by a concrete integer.

  `param_const_map` supplies resolved parameters as `%Const{}` so driver
  expressions that reference params (e.g. `noise * ALPHA`) size correctly.
  `logic` is the list of parsed `@hw_logic` blocks (the drivers live here).
  """
  def resolve(signal_map, param_const_map, logic, memory_map \\ %{}) do
    infer_names = for {name, %Signal{width: :infer}} <- signal_map, do: name

    if infer_names == [] do
      signal_map
    else
      infer_set = MapSet.new(infer_names)
      drivers   = collect_drivers(logic, infer_set)

      Enum.each(infer_names, fn n ->
        unless Map.has_key?(drivers, n) do
          raise ElabError,
            message: ":infer signal `#{n}` has no expression to size it from " <>
                     "(it needs exactly one driving assignment)",
            context: n
        end
      end)

      {resolved, _} =
        Enum.reduce(infer_names, {signal_map, MapSet.new()}, fn n, {map, done} ->
          resolve_one(n, map, done, drivers, infer_set, param_const_map, memory_map, MapSet.new())
        end)

      resolved
    end
  end

  # Depth-first resolve with cycle detection. `done` memoises finished names.
  defp resolve_one(name, map, done, drivers, infer_set, param_const_map, memory_map, visiting) do
    cond do
      MapSet.member?(done, name) ->
        {map, done}

      MapSet.member?(visiting, name) ->
        raise ElabError,
          message: "cyclic :infer width dependency involving `#{name}`",
          context: name

      true ->
        %Signal{} = sig = Map.fetch!(map, name)
        driver = Map.fetch!(drivers, name)
        visiting = MapSet.put(visiting, name)

        # Resolve this driver's :infer dependencies first (dataflow order).
        deps = driver |> referenced_signals() |> Enum.filter(&MapSet.member?(infer_set, &1))

        {map, done} =
          Enum.reduce(deps, {map, done}, fn d, {m, dn} ->
            resolve_one(d, m, dn, drivers, infer_set, param_const_map, memory_map, visiting)
          end)

        lookup = Map.merge(map, param_const_map)
        {value, _scratch} =
          Expr.build_expr(driver, lookup, %{}, memory_map, Design.new(:__infer_scratch__))

        width = value_width(value)

        unless is_integer(width) do
          raise ElabError,
            message: "could not infer a concrete width for :infer signal `#{name}` " <>
                     "— driver resolved to width #{inspect(width)}",
            context: name
        end

        {Map.put(map, name, %Signal{sig | width: width}), MapSet.put(done, name)}
    end
  end

  defp value_width(%Signal{width: w}), do: w
  defp value_width(%Const{width: w}),  do: w
  defp value_width(_),                 do: nil

  # --- driver extraction: infer signal name -> its driving value expression ---

  defp collect_drivers(logic, infer_set) do
    Enum.reduce(logic, %{}, fn block, acc ->
      collect_body(Map.get(block, :body, []), infer_set, acc)
    end)
  end

  defp collect_body(stmts, infer_set, acc) when is_list(stmts) do
    Enum.reduce(stmts, acc, fn stmt, a -> collect_stmt(stmt, infer_set, a) end)
  end

  defp collect_body(_, _infer_set, acc), do: acc

  defp collect_stmt(%{type: :assign, target: name, value: value}, infer_set, acc) do
    if MapSet.member?(infer_set, name) do
      # Prefer a real driver over a reset-const; keep the first real driver.
      case {Map.get(acc, name), value} do
        {nil, _}               -> Map.put(acc, name, value)
        {{:const, _}, _}       -> Map.put(acc, name, value)
        {_existing, {:const, _}} -> acc
        _                      -> acc
      end
    else
      acc
    end
  end

  defp collect_stmt(%{type: :if, then_body: t, else_body: e}, infer_set, acc) do
    acc = collect_body(t || [], infer_set, acc)
    collect_body(e || [], infer_set, acc)
  end

  defp collect_stmt(%{type: :case, clauses: clauses}, infer_set, acc) do
    Enum.reduce(clauses, acc, fn c, a -> collect_body(Map.get(c, :body, []), infer_set, a) end)
  end

  defp collect_stmt(_stmt, _infer_set, acc), do: acc

  # --- signals referenced by a parsed expression ---

  defp referenced_signals(expr), do: expr |> refs([]) |> Enum.uniq()

  defp refs({:signal, name}, acc) when is_atom(name), do: [name | acc]
  defp refs({:const, _}, acc), do: acc
  defp refs({:concat, elems}, acc) when is_list(elems), do: Enum.reduce(elems, acc, &refs/2)
  defp refs(tuple, acc) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.reduce(acc, fn el, a -> refs(el, a) end)
  end
  defp refs(list, acc) when is_list(list), do: Enum.reduce(list, acc, &refs/2)
  defp refs(_other, acc), do: acc
end
