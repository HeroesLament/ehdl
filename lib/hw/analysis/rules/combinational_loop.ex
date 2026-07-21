defmodule Hw.Analysis.Rules.CombinationalLoop do
  @moduledoc """
  Detects cycles in the combinational assignment graph — wires that
  directly or transitively depend on themselves without a register
  breaking the loop.

  ## Background

  A combinational loop is a path through combinational logic (assigns,
  muxes, arithmetic ops) where the output of a computation feeds back
  into one of its own inputs. In simulation this causes infinite
  oscillation or X propagation. In synthesis the tool may:
  - Optimize the loop away (breaking functionality silently)
  - Fail with an error
  - Produce a circuit that oscillates at GHz speeds

  The only legitimate "loop" in synchronous design is through a
  register — which is not a combinational loop.

  ## What is checked

  This rule builds a directed graph of combinational dependencies from
  the elaborated IR:
  - Every `Ops.Assign`, `Ops.Mux`, and arithmetic/bitwise op contributes
    edges from its input signals to its output signal
  - `Ops.Reg` ops are **not** included — they break the combinational
    path (the output depends on a clock edge, not directly on the input)
  - `Ops.Mem`, `Ops.MemRead` are not included for the same reason

  A cycle in this graph is a combinational loop.

  ## Cycle detection

  Uses iterative DFS with a visited/in-stack set. Reports the full
  cycle path so the user can see exactly which signals form the loop.

  ## Example diagnostic

      error[E071]: combinational loop detected: `:rx_state` → `:_eq_1234`
                   → `:_mux_5678` → `:rx_state`
        │
        │ Hw.USB.FSPhy
        │
        └─ hint: break the loop by registering one signal in the path:
                 `on :clk do rx_state <= next_rx_state end`

  ## Priority

  Runs at priority 62, after latch inference.
  """

  @behaviour Hw.Analysis.Rule

  # Dialyzer false positives: recursive MapSet passing in dfs/5 triggers
  # opaqueness warnings; the anonymous fn accumulator in find_cycles/1 likewise.
  @dialyzer {:nowarn_function, dfs: 5}
  @dialyzer {:nowarn_function, find_cycles: 1}
  @dialyzer {:nowarn_function, check_design: 2}

  alias Hw.Analysis.{Diagnostic, Location}
  alias Hw.IR.Ops.{Assign, Mux, Reg, Mem, MemWrite, MemRead, Blackbox, Tristate}
  alias Hw.IR.Types.Signal

  @impl Hw.Analysis.Rule
  def priority, do: 62

  @impl Hw.Analysis.Rule
  def run(%{components: components}) do
    Enum.flat_map(components, fn comp ->
      design = safe_design(comp.module)
      if design, do: check_design(design, comp.module), else: []
    end)
  end

  defp check_design(design, module) do
    graph = build_comb_graph(design.ops)
    cycles = find_cycles(graph)

    Enum.map(cycles, fn cycle ->
      path = Enum.join(cycle, " → ")
      loc = fallback(module)
      Diagnostic.error(
        :combinational_loop,
        "combinational loop detected: #{path}",
        loc,
        context: %{cycle: cycle, module: module}
      )
    end)
  end

  # Build adjacency map: signal_name -> [signal_name] for combinational ops only
  defp build_comb_graph(ops) do
    Enum.reduce(ops, %{}, fn op, graph ->
      case comb_edges(op) do
        nil -> graph
        {output_name, input_names} ->
          # For each input, add edge input -> output
          Enum.reduce(input_names, graph, fn input, g ->
            Map.update(g, input, [output_name], &[output_name | &1])
          end)
      end
    end)
  end

  # Returns {output_name, [input_names]} for combinational ops, nil for sequential
  defp comb_edges(%Assign{output: out, input: inp}) do
    {out.name, signal_names(inp)}
  end

  defp comb_edges(%Mux{output: out, cases: cases, default: default}) do
    case_inputs = Enum.flat_map(cases, fn {cond, val} ->
      signal_names(cond) ++ signal_names(val)
    end)
    {out.name, case_inputs ++ signal_names(default)}
  end

  # Arithmetic and bitwise ops — extract via struct fields
  defp comb_edges(op) when is_struct(op) do
    case op do
      %{output: %Signal{name: out}, a: a, b: b} ->
        {out, signal_names(a) ++ signal_names(b)}
      %{output: %Signal{name: out}, input: inp} ->
        {out, signal_names(inp)}
      _ -> nil
    end
    |> skip_sequential(op)
  end

  defp comb_edges(_), do: nil

  # Exclude sequential and IO ops from the combinational graph
  defp skip_sequential(_, %Reg{}),      do: nil
  defp skip_sequential(_, %Mem{}),      do: nil
  defp skip_sequential(_, %MemWrite{}), do: nil
  defp skip_sequential(_, %MemRead{}),  do: nil
  defp skip_sequential(_, %Blackbox{}), do: nil
  defp skip_sequential(_, %Tristate{}), do: nil
  defp skip_sequential(result, _),      do: result

  defp signal_names(%Signal{name: name}), do: [name]
  defp signal_names(_), do: []

  # Iterative DFS cycle detection — returns list of cycles (each a list of signal names)
  defp find_cycles(graph) do
    all_nodes = Map.keys(graph)

    {cycles, _} = Enum.reduce(all_nodes, {[], MapSet.new()}, fn node, {found, visited} ->
      if MapSet.member?(visited, node) do
        {found, visited}
      else
        {new_cycles, new_visited} = dfs(node, graph, [], MapSet.new(), visited)
        {found ++ new_cycles, MapSet.union(visited, new_visited)}
      end
    end)

    # Deduplicate cycles (same set of nodes, different start)
    cycles
    |> Enum.map(&normalize_cycle/1)
    |> Enum.uniq()
  end

  defp dfs(node, graph, stack, in_stack, globally_visited) do
    if MapSet.member?(in_stack, node) do
      # Found a cycle — extract it from the stack
      cycle_start = Enum.find_index(stack, &(&1 == node))
      cycle = Enum.slice(stack, cycle_start..-1//1) ++ [node]
      {[cycle], globally_visited}
    else
      if MapSet.member?(globally_visited, node) do
        {[], globally_visited}
      else
        in_stack2 = MapSet.put(in_stack, node)
        stack2 = stack ++ [node]
        neighbors = Map.get(graph, node, [])

        {cycles, visited2} = Enum.reduce(neighbors, {[], globally_visited}, fn neighbor, {acc_cycles, acc_visited} ->
          {new_cycles, new_visited} = dfs(neighbor, graph, stack2, in_stack2, acc_visited)
          {acc_cycles ++ new_cycles, new_visited}
        end)

        {cycles, MapSet.put(visited2, node)}
      end
    end
  end

  # Normalize cycle to start from the lexicographically smallest node
  defp normalize_cycle([]), do: []
  defp normalize_cycle(cycle) do
    min_node = Enum.min(cycle)
    idx = Enum.find_index(cycle, &(&1 == min_node))
    Enum.slice(cycle, idx..-1//1) ++ Enum.slice(cycle, 0..(idx - 1)//1)
  end

  defp safe_design(module) do
    try do
      if function_exported?(module, :__hw_design__, 0), do: module.__hw_design__()
    rescue
      _ -> nil
    end
  end

  defp fallback(module),
    do: %Location{file: "unknown", line: 0, module: module}
end
