defmodule Hw.Sim.DefhwInterpreter do
  @moduledoc """
  Interprets `defhw` bodies against a live simulation.

  Combinational defhws (no `on` blocks) execute as a batch of force_reg/set
  calls — zero clock cycles consumed.

  Sequential defhws (contain `on` blocks) tick the component's clock until
  each condition is true, then execute the body. The clock is resolved from
  the component's declared clock domain.

  ## Prefix resolution

  Signal names in defhw bodies are the component's own port names (unprefixed).
  The interpreter resolves the correct prefix by looking up which entity in the
  sim's schedule corresponds to the given module.

  If the module appears as a standalone design (e.g. `Hw.Sim.start(Hw.UART.TX)`),
  no prefix is applied. If it appears as a child instance in a larger design
  (e.g. `instance :uart_tx, Hw.UART.TX`), the entity prefix (`uart_tx_`) is
  applied automatically.

  ## Ambiguity

  If a module is instantiated multiple times, pass `as: :instance_name` to
  disambiguate. Raises if ambiguous and no `as:` is given.
  """

  alias Hw.Sim.State

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Apply a defhw by name against a live simulation.

  Resolves the signal prefix from the schedule topology, evaluates all
  assignments, and for sequential defhws ticks the clock until `on` conditions
  are satisfied.

  Returns the last evaluated value, or `:ok` for void defhws.

  ## Options

  - `as:` — instance name to use when the module appears multiple times
  - `clock:` — override the clock to use for sequential ticking
  """
  def apply(sim, module, name, args \\ [], opts \\ []) do
    defhw = find_defhw!(module, name, length(args))
    prefix = resolve_prefix!(sim, module, opts)
    clock  = Keyword.get(opts, :clock, resolve_clock(sim, module, opts))

    if defhw.sequential do
      run_sequential(sim, defhw, args, prefix, clock)
    else
      run_combinational(sim, defhw, args, prefix)
    end
  end

  @doc """
  Resolve the signal prefix for a module in the given sim.

  Returns `""` for standalone designs, `"uart_tx_"` etc. for instances.
  Raises if the module appears multiple times and no `as:` disambiguator given.
  """
  def resolve_prefix(sim, module, opts \\ []) do
    resolve_prefix!(sim, module, opts)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp find_defhw!(module, name, arity) do
    defhws = if function_exported?(module, :__hw_defhw__, 0) do
      module.__hw_defhw__()
    else
      []
    end

    case Enum.find(defhws, fn d -> d.name == name and length(d.params) == arity end) do
      nil ->
        raise ArgumentError, "#{inspect(module)} has no defhw #{name}/#{arity}"
      defhw ->
        defhw
    end
  end

  defp resolve_prefix!(sim, module, opts) do
    case Keyword.get(opts, :as) do
      nil ->
        # Auto-resolve from schedule topology
        matches = sim.schedule.entities
          |> Enum.filter(fn {_, e} -> e.module == module end)
          |> Enum.map(fn {_, e} -> e.prefix end)

        case matches do
          [] ->
            # Check if this IS the top-level module (standalone sim)
            if sim.schedule.entities[:_top_] != nil and
               Enum.all?(sim.schedule.entities, fn {_, e} -> e.module == module or e.name == :_top_ end) do
              ""
            else
              # Module not found — try empty prefix (standalone)
              ""
            end
          [prefix] ->
            prefix
          multiple ->
            raise ArgumentError,
              "#{inspect(module)} appears #{length(multiple)} times in this design. " <>
              "Use `as: :instance_name` to disambiguate."
        end

      instance_name ->
        case sim.schedule.entities[instance_name] do
          nil -> raise ArgumentError, "No entity :#{instance_name} in this simulation"
          entity -> entity.prefix
        end
    end
  end

  defp resolve_clock(sim, module, opts) do
    case Keyword.get(opts, :as) do
      nil ->
        matches = sim.schedule.entities
          |> Enum.filter(fn {_, e} -> e.module == module end)
          |> Enum.map(fn {_, e} -> e.domain end)
          |> Enum.reject(&is_nil/1)
        case matches do
          [clock | _] -> clock
          [] ->
            # Standalone — find the first clock in the schedule
            sim.schedule.clocks |> List.first() |> then(fn c -> c && c.name end)
        end
      instance_name ->
        sim.schedule.entities[instance_name].domain
    end
  end

  defp run_combinational(sim, defhw, args, prefix) do
    bindings = build_bindings(defhw.params, args)
    env = %{bindings: bindings, prefix: prefix, sim: sim}
    {result, _env} = exec_stmts(defhw.body, env)
    result || :ok
  end

  defp run_sequential(sim, defhw, args, prefix, clock) do
    bindings = build_bindings(defhw.params, args)
    env = %{bindings: bindings, prefix: prefix, sim: sim, clock: clock}
    {result, _env} = exec_stmts(defhw.body, env)
    result || :ok
  end

  defp build_bindings(params, args) do
    Enum.zip(params, args) |> Map.new()
  end

  # ---------------------------------------------------------------------------
  # Statement executor
  # ---------------------------------------------------------------------------

  defp exec_stmts(stmts, env) do
    Enum.reduce(stmts, {nil, env}, fn stmt, {_last, e} ->
      {val, new_e} = exec_stmt(stmt, e)
      {val, new_e}
    end)
  end

  defp exec_stmt(%{type: :assign, target: target, value: value_expr}, env) do
    value = eval_expr(value_expr, env)
    prefixed = prefix_signal(target, env.prefix)
    Hw.Sim.force_reg_raw(env.sim, prefixed, value)
    {value, env}
  end

  defp exec_stmt(%{type: :if, condition: cond_expr, then_body: then_body, else_body: else_body}, env) do
    cond_val = eval_expr(cond_expr, env)
    if cond_val != 0 do
      exec_stmts(then_body, env)
    else
      if else_body do
        exec_stmts(else_body, env)
      else
        {nil, env}
      end
    end
  end

  defp exec_stmt(%{type: :sequential, body: body}, env) do
    # `on :clk do` inside a defhw — tick once then execute body
    Hw.Sim.tick(env.sim, env.clock, 1)
    exec_stmts(body, env)
  end

  defp exec_stmt(%{type: :defhw_call, name: name, args: arg_exprs}, env) do
    args = Enum.map(arg_exprs, &eval_expr(&1, env))
    module = find_module_for_defhw(name, env)
    result = apply(env.sim, module, name, args)
    {result, env}
  end

  defp exec_stmt(_stmt, env), do: {nil, env}

  # ---------------------------------------------------------------------------
  # Expression evaluator
  # ---------------------------------------------------------------------------

  defp eval_expr({:signal, name}, env) do
    case Map.get(env.bindings, name) do
      nil ->
        prefixed = prefix_signal(name, env.prefix)
        Hw.Sim.get(env.sim, prefixed)
      val ->
        val
    end
  end

  defp eval_expr({:const, n}, _env), do: n

  defp eval_expr({:add, a, b}, env), do: eval_expr(a, env) + eval_expr(b, env)
  defp eval_expr({:sub, a, b}, env), do: eval_expr(a, env) - eval_expr(b, env)
  defp eval_expr({:eq,  a, b}, env), do: if(eval_expr(a, env) == eval_expr(b, env), do: 1, else: 0)
  defp eval_expr({:neq, a, b}, env), do: if(eval_expr(a, env) != eval_expr(b, env), do: 1, else: 0)
  defp eval_expr({:lt,  a, b}, env), do: if(eval_expr(a, env) <  eval_expr(b, env), do: 1, else: 0)
  defp eval_expr({:lte, a, b}, env), do: if(eval_expr(a, env) <= eval_expr(b, env), do: 1, else: 0)
  defp eval_expr({:band, a, b}, env), do: Bitwise.band(eval_expr(a, env), eval_expr(b, env))
  defp eval_expr({:bor,  a, b}, env), do: Bitwise.bor(eval_expr(a, env),  eval_expr(b, env))
  defp eval_expr({:bxor, a, b}, env), do: Bitwise.bxor(eval_expr(a, env), eval_expr(b, env))
  defp eval_expr({:bnot, a},    env), do: Bitwise.bnot(eval_expr(a, env)) |> Bitwise.band(1)
  defp eval_expr({:land, a, b}, env), do: if(eval_expr(a, env) != 0 and eval_expr(b, env) != 0, do: 1, else: 0)
  defp eval_expr({:lor,  a, b}, env), do: if(eval_expr(a, env) != 0 or  eval_expr(b, env) != 0, do: 1, else: 0)
  defp eval_expr({:lnot, a},    env), do: if(eval_expr(a, env) == 0, do: 1, else: 0)
  defp eval_expr(n, _env) when is_integer(n), do: n
  defp eval_expr(other, _env), do: raise "DefhwInterpreter: cannot evaluate #{inspect(other)}"

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp prefix_signal(name, ""), do: name
  defp prefix_signal(name, prefix) do
    name_str = Atom.to_string(name)
    if String.starts_with?(name_str, prefix) do
      name
    else
      :"#{prefix}#{name}"
    end
  end

  defp find_module_for_defhw(_name, _env) do
    # TODO: resolve which module owns this defhw call
    # For now caller must use apply/5 directly
    raise "Nested defhw calls not yet supported in interpreter"
  end
end
