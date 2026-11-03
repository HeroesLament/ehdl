defmodule Hw.DSL.Generate do
  @moduledoc ~S"""
  Compile-time unrolling behind `generate`.

      generate k <- 0..3 do
        wire :"cstate#{k}", 5, init: 0
      end

      on :clk do
        generate k <- 0..3 do
          if band(x_en_r, x_seat_r == k) == 1 do
            cstate[[k]] = 17
          end
        end
      end

  For each value of the range the body is copied with the loop variable
  replaced by the integer, then two folds run on the copy:

    * **signal families**: `name[[e]]` (double brackets: a list index,
      which a bit select never is) becomes the signal `name<e>`, with `e`
      folded to an integer. `cstate[[k]]` at `k = 2` is `cstate2`;
      `pc_h[[k]]` is `pc_h2`. A single bracket keeps its meaning, so
      `out[k] = in[7 - k]` is still a bit select by the loop index.
    * **interpolated names**: `:"cstate#{k}"` folds to the atom `:cstate2`,
      so declaration macros see a literal name.

  Integer arithmetic on the loop variable (`[[k + 1]]`, `[[rem(k + 1, 4)]]`)
  is folded at compile time; an index that still names a signal after
  substitution is an error, because a family member must be known when the
  module compiles.
  """

  # Module-level macros whose presence makes a generate body declarative: the
  # unrolled copies are spliced into the module and expand as written.
  @declarative [
    :wire, :input, :output, :inout, :memory, :complex, :blackbox, :fanout,
    :tristate, :on, :comb, :instance, :interface, :connect, :fsm, :pipeline,
    :generate, :provides, :consumes
  ]

  @doc "The integer values of a `lo..hi` or `lo..hi//step` range literal."
  def range_values({:.., _, [lo, hi]}), do: Enum.to_list(int!(lo, :lo)..int!(hi, :hi)//1)

  def range_values({:"..//", _, [lo, hi, step]}),
    do: Enum.to_list(int!(lo, :lo)..int!(hi, :hi)//int!(step, :step))

  def range_values(other) do
    raise ArgumentError,
          "generate requires a range literal like 0..3, got: #{Macro.to_string(other)}"
  end

  defp int!(ast, what) do
    case fold_int(ast) do
      {:ok, n} ->
        n

      :error ->
        raise ArgumentError,
              "generate range #{what} must be an integer known at compile time, got: " <>
                Macro.to_string(ast)
    end
  end

  @doc "One body per range value: substituted, families and names folded."
  def unroll(var, range, body) do
    for v <- range_values(range) do
      body
      |> substitute(var, v)
      |> fold()
    end
  end

  @doc "True when the body declares or contains module-level logic blocks."
  def declarative?({:__block__, _, stmts}), do: Enum.any?(stmts, &declarative_stmt?/1)
  def declarative?(stmt), do: declarative_stmt?(stmt)

  @doc "True when the body also holds bare statements (assignments, if, case)."
  def has_statements?({:__block__, _, stmts}), do: Enum.any?(stmts, &(not declarative_stmt?(&1)))
  def has_statements?(stmt), do: not declarative_stmt?(stmt)

  defp declarative_stmt?({name, _, args}) when is_atom(name) and is_list(args),
    do: name in @declarative

  defp declarative_stmt?(_), do: false

  # ---------------------------------------------------------------------------

  # Replace the loop variable with its value everywhere it is read. A nested
  # `generate` that rebinds the same name keeps its own variable.
  defp substitute({:generate, m, [{:<-, am, [{var, _, _} = v, range]}, opts]}, var, val) do
    {:generate, m, [{:<-, am, [v, substitute(range, var, val)]}, opts]}
  end

  defp substitute({var, _, ctx}, var, val) when is_atom(var) and is_atom(ctx), do: val

  defp substitute({op, meta, args}, var, val) when is_list(args) do
    {substitute(op, var, val), meta, Enum.map(args, &substitute(&1, var, val))}
  end

  defp substitute({a, b}, var, val), do: {substitute(a, var, val), substitute(b, var, val)}
  defp substitute(list, var, val) when is_list(list), do: Enum.map(list, &substitute(&1, var, val))
  defp substitute(other, _var, _val), do: other

  # Families and interpolated names, bottom-up so an index is folded before
  # the reference around it.
  defp fold(ast) do
    Macro.postwalk(ast, fn
      {{:., _, [Access, :get]}, _, [{name, meta, ctx}, [idx]]} = node
      when is_atom(name) and is_atom(ctx) ->
        case fold_int(idx) do
          {:ok, n} ->
            {:"#{name}#{n}", meta, ctx}

          :error ->
            raise ArgumentError,
                  "generate: family index in #{Macro.to_string(node)} must fold to an " <>
                    "integer at compile time"
        end

      {{:., _, [:erlang, :binary_to_atom]}, _, [{:<<>>, _, _}, :utf8]} = node ->
        case eval_closed(node) do
          {:ok, atom} when is_atom(atom) -> atom
          _ -> node
        end

      node ->
        node
    end)
  end

  defp fold_int(n) when is_integer(n), do: {:ok, n}

  defp fold_int(ast) do
    case eval_closed(ast) do
      {:ok, n} when is_integer(n) -> {:ok, n}
      _ -> :error
    end
  end

  # Evaluate an expression that reads no variables (after substitution);
  # anything that still names a signal is left alone, unevaluated.
  defp eval_closed(ast) do
    if closed?(ast) do
      try do
        {value, _} = Code.eval_quoted(ast, [], __ENV__)
        {:ok, value}
      rescue
        _ -> :error
      end
    else
      :error
    end
  end

  # No variable anywhere, except the type side of a binary segment
  # (`x :: binary` in an interpolation).
  defp closed?({:"::", _, [expr, _type]}), do: closed?(expr)
  defp closed?({name, meta, ctx}) when is_atom(name) and is_list(meta) and is_atom(ctx), do: false
  defp closed?({op, _, args}) when is_list(args), do: closed?(op) and Enum.all?(args, &closed?/1)
  defp closed?({a, b}), do: closed?(a) and closed?(b)
  defp closed?(list) when is_list(list), do: Enum.all?(list, &closed?/1)
  defp closed?(_), do: true
end
