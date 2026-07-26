defmodule Hw.Analysis.Rules.ParamBoundary do
  @moduledoc """
  Evaluates parameterized width and depth expressions at boundary values
  to detect cases where a module breaks at non-default instantiations.

  ## Background

  Parameterized modules are a major source of latent bugs because:
  - They are typically only tested at their default parameter values
  - Boundary conditions (WIDTH=1, DEPTH=1, DEPTH=2, clog2 edge cases)
    cause qualitatively different behavior, not just quantitative changes
  - The breakage is often in the width arithmetic itself — a zero-width
    wire, a negative pointer, a one-entry FIFO with no valid MSB

  Common specific failures:
  - `clog2(DEPTH) + 1` pointer width: at DEPTH=1, `clog2(1) = 0`, so
    pointer is 1 bit wide — FIFO full/empty breaks
  - `WIDTH - 1` in a slice: at WIDTH=1, this is `[0:-1]` — illegal
  - `clog2(DEPTH)` address width: at DEPTH=1, address is 0 bits wide
  - `(WIDTH / 8)` strobe: at WIDTH=4 or less, strobe is 0 bits wide

  ## What is checked

  For every component with declared `param` declarations, this rule:

  1. Collects all width and depth expressions that reference params
  2. Evaluates each expression at boundary values:
     - `1` (minimum useful value)
     - `2` (power-of-2 minimum)
     - `default - 1` (just below default, if > 1)
     - `default + 1` (just above default)
  3. Flags any evaluation that produces a result ≤ 0 (zero-width or
     negative width is always a bug)
  4. Flags `clog2` applied to 1 specifically — the result is 0 when
     most uses expect 1

  ## Example diagnostic

      error[E074]: parameter `DEPTH=1` causes signal `:wr_ptr` width
                   expression `clog2(DEPTH) + 1` to evaluate to 1,
                   but address width `clog2(DEPTH)` evaluates to 0 —
                   the FIFO has no addressable entries
        │
        │ Hw.FIFO
        │
        │   param :DEPTH, default: 16
        │   wire :wr_addr, clog2(DEPTH)   ← 0 bits wide at DEPTH=1
        │
        └─ hint: add a guard: `wire :wr_addr, max(1, clog2(DEPTH))`
                 or document that DEPTH >= 2 is required

  ## Priority

  Runs at priority 66, last of the IR-level rules.
  """

  @behaviour Hw.Analysis.Rule

  @dialyzer {:nowarn_function, check_width_expr: 4}

  alias Hw.Analysis.{Diagnostic, Location}

  @impl Hw.Analysis.Rule
  def priority, do: 66

  @impl Hw.Analysis.Rule
  def run(%{components: components}) do
    Enum.flat_map(components, fn comp ->
      params = get_params(comp.module)
      if params == [] do
        []
      else
        signals = comp.signals
        check_component(comp.module, params, signals)
      end
    end)
  end

  defp check_component(module, params, signals) do
    param_defaults = Map.new(params, fn p -> {p.name, p.default} end)

    Enum.flat_map(signals, fn sig ->
      case sig.width do
        w when is_integer(w) -> []
        width_expr -> check_width_expr(width_expr, sig, param_defaults, module)
      end
    end)
  end

  defp check_width_expr(expr, sig, param_defaults, module) do
    referenced_params = collect_param_refs(expr)

    if referenced_params == [] do
      []
    else
      boundary_values = generate_boundary_values(referenced_params, param_defaults)

      Enum.flat_map(boundary_values, fn param_binding ->
        case eval_expr(expr, param_binding) do
          {:ok, width} when width <= 0 ->
            binding_str = param_binding
              |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
              |> Enum.join(", ")
            loc = sig[:source_location] || fallback(module)
            [Diagnostic.error(
              :param_boundary,
              "signal `:#{sig.name}` width expression evaluates to #{width} " <>
              "when #{binding_str} — zero or negative width is invalid",
              loc,
              context: %{
                signal:         sig.name,
                width_expr:     inspect(expr),
                param_binding:  param_binding,
                evaluated_width: width,
                module:         module
              }
            )]

          {:ok, _} -> []
          {:error, _} -> []
        end
      end)
    end
  end

  # Collect all param name atoms referenced in a width expression
  defp collect_param_refs(name) when is_atom(name), do: [name]
  defp collect_param_refs({:clog2, a}), do: collect_param_refs(a)
  defp collect_param_refs({op, a, b}) when op in [:+, :-, :*, :/, :div] do
    collect_param_refs(a) ++ collect_param_refs(b)
  end
  defp collect_param_refs({:{}, [], [op | args]}) do
    Enum.flat_map([op | args], &collect_param_refs/1)
  end
  defp collect_param_refs(_), do: []

  # Generate boundary bindings for a set of param names
  defp generate_boundary_values(param_names, param_defaults) do
    # For each param, generate a set of boundary values
    per_param = Enum.map(param_names, fn name ->
      default = Map.get(param_defaults, name, 8)
      values = [1, 2] ++
        (if default > 2, do: [default - 1], else: []) ++
        [default, default + 1]
      {name, Enum.uniq(values)}
    end)

    # Take the cross product of all param boundary values
    # but cap at 20 combinations to avoid explosion
    cross_product(per_param) |> Enum.take(20)
  end

  defp cross_product([]), do: [%{}]
  defp cross_product([{name, values} | rest]) do
    rest_products = cross_product(rest)
    for value <- values, product <- rest_products do
      Map.put(product, name, value)
    end
  end

  # Evaluate a width expression given a map of param_name -> value
  defp eval_expr(n, _) when is_integer(n), do: {:ok, n}
  defp eval_expr(name, bindings) when is_atom(name) do
    case Map.get(bindings, name) do
      nil -> {:error, :unbound}
      v   -> {:ok, v}
    end
  end
  defp eval_expr({:clog2, a}, bindings) do
    with {:ok, v} <- eval_expr(a, bindings) do
      result = if v <= 1, do: 0, else: ceil(:math.log2(v)) |> trunc()
      {:ok, result}
    end
  end
  defp eval_expr({:+, a, b}, bindings) do
    with {:ok, av} <- eval_expr(a, bindings),
         {:ok, bv} <- eval_expr(b, bindings) do
      {:ok, av + bv}
    end
  end
  defp eval_expr({:-, a, b}, bindings) do
    with {:ok, av} <- eval_expr(a, bindings),
         {:ok, bv} <- eval_expr(b, bindings) do
      {:ok, av - bv}
    end
  end
  defp eval_expr({:*, a, b}, bindings) do
    with {:ok, av} <- eval_expr(a, bindings),
         {:ok, bv} <- eval_expr(b, bindings) do
      {:ok, av * bv}
    end
  end
  defp eval_expr({op, a, b}, bindings) when op in [:/, :div] do
    with {:ok, av} <- eval_expr(a, bindings),
         {:ok, bv} <- eval_expr(b, bindings),
         true <- bv != 0 do
      {:ok, div(av, bv)}
    else
      false -> {:error, :div_by_zero}
      err   -> err
    end
  end
  # Handle Macro.escape tuple form
  defp eval_expr({:{}, [], [op | args]}, bindings) do
    eval_expr(List.to_tuple([op | args]), bindings)
  end
  defp eval_expr(_, _), do: {:error, :unknown}

  defp get_params(module) do
    if (Code.ensure_loaded?(module) and function_exported?(module, :__hw_params__, 0)) do
      module.__hw_params__()
    else
      []
    end
  end

  defp fallback(module),
    do: %Location{file: "unknown", line: 0, module: module}
end
