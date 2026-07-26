defmodule Hw.Analysis.Rules.CrossInstanceLoop do
  @moduledoc """
  Detects combinational loops that close THROUGH an instance's port
  connections — the blind spot of `Hw.Analysis.Rules.CombinationalLoop`, which
  only analyzes one component's own IR at a time.

  ## Background

  `CombinationalLoop` builds a dependency graph from a single design's ops and
  finds cycles. But a loop can span the instance boundary: a parent wire feeds
  an instance input, the instance combinationally drives an output from that
  input, and the parent feeds that output back to the input. Neither the parent
  nor the child, examined alone, contains the cycle — it only closes when the
  port connections are stitched together.

  The canonical footgun is a valid/ready handshake tied combinationally:

      # parent:
      instance :u, SomeMealyThing, in_ready: :r, out_valid: :v
      comb do r = v end          # ready driven combinationally from valid

  If `SomeMealyThing` drives `out_valid` combinationally from `in_ready`, this is
  a 0-delay loop `r -> (child) -> v -> r`. In simulation it oscillates; in
  synthesis it may be optimized away silently or produce a circuit that never
  settles. (If the instance's `out_valid` is REGISTERED from `in_ready`, there
  is no combinational loop — the register breaks it — and this rule correctly
  stays silent.)

  ## How it works

  1. For every instance, load the child module's IR and compute, via the same
     register-breaking combinational graph `CombinationalLoop` uses, which of the
     child's OUTPUT ports depend combinationally on which of its INPUT ports.
     These are the child's internal input->output combinational arcs.
  2. Build the parent's own combinational graph, then splice in, for each
     instance arc `in_port ~> out_port`, an edge
     `parent_signal(in_port) -> parent_signal(out_port)`.
  3. Run cycle detection on the spliced graph. Any cycle that uses at least one
     spliced (through-instance) edge is a cross-instance combinational loop the
     per-component checker cannot see, and is reported here.

  Loops entirely within one component are left to `CombinationalLoop` (priority
  62); this rule runs after it (priority 63) and only reports cycles that
  actually traverse an instance arc, to avoid duplicate diagnostics.

  ## Example diagnostic

      error[cross_instance_loop]: combinational loop through instance `:u`:
        `:r` -> `:u`(in_ready~>out_valid) -> `:v` -> `:r`
        │
        │ HelloBoard.Top
        │
        └─ hint: break the loop by registering one signal in the path, or drive
                 the instance input from a registered copy instead of the raw
                 combinational output.

  ## Priority

  Runs at priority 63, right after `CombinationalLoop` (62).
  """

  @behaviour Hw.Analysis.Rule

  @dialyzer {:nowarn_function, check_component: 3}
  @dialyzer {:nowarn_function, instance_arcs: 1}
  @dialyzer {:nowarn_function, reachable_comb: 2}

  alias Hw.Analysis.{Diagnostic, Location}
  alias Hw.IR.Ops.{Assign, Mux, Reg, Mem, MemWrite, MemRead, Blackbox, Tristate}
  alias Hw.IR.Types.Signal

  @impl Hw.Analysis.Rule
  def priority, do: 63

  @impl Hw.Analysis.Rule
  def run(%{components: components}) do
    Enum.flat_map(components, fn comp ->
      design = safe_design(comp.module)
      instances = safe_instances(comp.module)

      if design && instances != [] do
        check_component(design, instances, comp.module)
      else
        []
      end
    end)
  end

  defp check_component(design, instances, module) do
    # Parent's own combinational adjacency (signal -> [signal]).
    base_graph = build_comb_graph(design.ops)

    # Splice in through-instance arcs. Track which edges are "instance edges"
    # (and which instance produced them) so a found cycle can be attributed and
    # so we only report cycles that actually cross an instance.
    {graph, inst_edges} =
      Enum.reduce(instances, {base_graph, %{}}, fn inst, {g, ie} ->
        add_instance_arcs(inst, g, ie)
      end)

    graph
    |> find_cycles()
    |> Enum.flat_map(fn cycle ->
      used = cycle_instance_edges(cycle, inst_edges)

      if used == [] do
        # Pure intra-component loop — CombinationalLoop already reports it.
        []
      else
        inst_name = used |> List.first() |> elem(0)
        path = Enum.join(cycle, " -> ")

        [
          Diagnostic.error(
            :cross_instance_loop,
            "combinational loop through instance `:#{inst_name}`: #{path}. " <>
              "The loop closes across the instance's port connections (an output " <>
              "driven combinationally from an input, fed back to that input), so " <>
              "it is invisible to the per-component loop checker. Break it by " <>
              "registering one signal in the path.",
            fallback(module),
            context: %{cycle: cycle, instances: Enum.map(used, &elem(&1, 0)), module: module}
          )
        ]
      end
    end)
    |> Enum.uniq_by(& &1.context.cycle)
  end

  # For an instance, add edges parent_sig(in_port) -> parent_sig(out_port) for
  # every internal combinational input->output arc of the child module.
  defp add_instance_arcs(%{name: iname, module: cmod, ports: ports}, graph, inst_edges) do
    port_map = Map.new(ports)

    Enum.reduce(instance_arcs(cmod), {graph, inst_edges}, fn {in_port, out_port}, {g, ie} ->
      with src when not is_nil(src) <- Map.get(port_map, in_port),
           dst when not is_nil(dst) <- Map.get(port_map, out_port) do
        g2 = Map.update(g, src, [dst], &[dst | &1])
        ie2 = Map.put(ie, {src, dst}, iname)
        {g2, ie2}
      else
        _ -> {g, ie}
      end
    end)
  end

  defp add_instance_arcs(_inst, graph, inst_edges), do: {graph, inst_edges}

  # Compute a child module's internal combinational input->output arcs:
  # {input_port_name, output_port_name} for each output that is combinationally
  # reachable from that input (register-broken paths excluded).
  defp instance_arcs(cmod) do
    design = safe_design(cmod)

    if design do
      signals = safe_signals(cmod)
      inputs = for s <- signals, s.direction == :input, do: s.name
      outputs = for s <- signals, s.direction == :output, do: s.name

      cgraph = build_comb_graph(design.ops)

      for inp <- inputs,
          reach = reachable_comb(inp, cgraph),
          out <- outputs,
          MapSet.member?(reach, out) do
        {inp, out}
      end
    else
      []
    end
  end

  # Set of signals combinationally reachable from `start` in the child graph.
  defp reachable_comb(start, graph) do
    reach_dfs([start], graph, MapSet.new())
  end

  defp reach_dfs([], _graph, visited), do: visited

  defp reach_dfs([node | rest], graph, visited) do
    if MapSet.member?(visited, node) do
      reach_dfs(rest, graph, visited)
    else
      neighbors = Map.get(graph, node, [])
      reach_dfs(neighbors ++ rest, graph, MapSet.put(visited, node))
    end
  end

  # ---- combinational graph (mirrors CombinationalLoop; registers break paths) --

  defp build_comb_graph(ops) do
    Enum.reduce(ops, %{}, fn op, graph ->
      case comb_edges(op) do
        nil ->
          graph

        {output_name, input_names} ->
          Enum.reduce(input_names, graph, fn input, g ->
            Map.update(g, input, [output_name], &[output_name | &1])
          end)
      end
    end)
  end

  defp comb_edges(%Assign{output: out, input: inp}), do: {out.name, signal_names(inp)}

  defp comb_edges(%Mux{output: out, cases: cases, default: default}) do
    case_inputs =
      Enum.flat_map(cases, fn {cond, val} -> signal_names(cond) ++ signal_names(val) end)

    {out.name, case_inputs ++ signal_names(default)}
  end

  defp comb_edges(op) when is_struct(op) do
    case op do
      %{output: %Signal{name: out}, a: a, b: b} -> {out, signal_names(a) ++ signal_names(b)}
      %{output: %Signal{name: out}, input: inp} -> {out, signal_names(inp)}
      _ -> nil
    end
    |> skip_sequential(op)
  end

  defp comb_edges(_), do: nil

  defp skip_sequential(_, %Reg{}), do: nil
  defp skip_sequential(_, %Mem{}), do: nil
  defp skip_sequential(_, %MemWrite{}), do: nil
  defp skip_sequential(_, %MemRead{}), do: nil
  defp skip_sequential(_, %Blackbox{}), do: nil
  defp skip_sequential(_, %Tristate{}), do: nil
  defp skip_sequential(result, _), do: result

  defp signal_names(%Signal{name: name}), do: [name]
  defp signal_names(_), do: []

  # ---- cycle detection (mirrors CombinationalLoop) ----------------------------

  defp find_cycles(graph) do
    all_nodes = Map.keys(graph)

    {cycles, _} =
      Enum.reduce(all_nodes, {[], MapSet.new()}, fn node, {found, visited} ->
        if MapSet.member?(visited, node) do
          {found, visited}
        else
          {new_cycles, new_visited} = dfs(node, graph, [], MapSet.new(), visited)
          {found ++ new_cycles, MapSet.union(visited, new_visited)}
        end
      end)

    cycles
    |> Enum.map(&normalize_cycle/1)
    |> Enum.uniq()
  end

  defp dfs(node, graph, stack, in_stack, globally_visited) do
    cond do
      MapSet.member?(in_stack, node) ->
        cycle_start = Enum.find_index(stack, &(&1 == node))
        cycle = Enum.slice(stack, cycle_start..-1//1) ++ [node]
        {[cycle], globally_visited}

      MapSet.member?(globally_visited, node) ->
        {[], globally_visited}

      true ->
        in_stack2 = MapSet.put(in_stack, node)
        stack2 = stack ++ [node]
        neighbors = Map.get(graph, node, [])

        {cycles, visited2} =
          Enum.reduce(neighbors, {[], globally_visited}, fn neighbor, {acc_cycles, acc_visited} ->
            {new_cycles, new_visited} = dfs(neighbor, graph, stack2, in_stack2, acc_visited)
            {acc_cycles ++ new_cycles, new_visited}
          end)

        {cycles, MapSet.put(visited2, node)}
    end
  end

  defp normalize_cycle([]), do: []

  defp normalize_cycle(cycle) do
    min_node = Enum.min(cycle)
    idx = Enum.find_index(cycle, &(&1 == min_node))
    Enum.slice(cycle, idx..-1//1) ++ Enum.slice(cycle, 0..(idx - 1)//1)
  end

  # Which instance edges does this cycle traverse? Returns [{inst_name, {a,b}}].
  defp cycle_instance_edges(cycle, inst_edges) do
    cycle
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [a, b] ->
      case Map.get(inst_edges, {a, b}) do
        nil -> []
        iname -> [{iname, {a, b}}]
      end
    end)
  end

  # ---- metadata access --------------------------------------------------------

  defp safe_design(module) do
    try do
      if (Code.ensure_loaded?(module) and function_exported?(module, :__hw_design__, 0)), do: module.__hw_design__()
    rescue
      _ -> nil
    end
  end

  defp safe_instances(module) do
    try do
      if (Code.ensure_loaded?(module) and function_exported?(module, :__hw_instances__, 0)), do: module.__hw_instances__(), else: []
    rescue
      _ -> []
    end
  end

  defp safe_signals(module) do
    try do
      if (Code.ensure_loaded?(module) and function_exported?(module, :__hw_signals__, 0)), do: module.__hw_signals__(), else: []
    rescue
      _ -> []
    end
  end

  defp fallback(module), do: %Location{file: "unknown", line: 0, module: module}
end
