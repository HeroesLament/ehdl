defmodule Hw.Compile.KeepPolicy do
  @dialyzer {:nowarn_function, expand_forward: 3, expand_backward: 3}
  @moduledoc """
  Policy-based keep tagging for the flat Verilog emitter.

  When emitting a flattened design, downstream synthesis tools (yosys) may
  prune logic they cannot prove affects a primary output. This module computes
  a set of signal names that should be marked `(* keep *)` to prevent pruning.

  ## Policies

  - `:output_reachability` — backward fanin cone from all top-level output ports.
    Any op whose output reaches a primary output is kept.

  - `:clock_domain_preservation` — if any register in a clock domain is kept,
    keep all registers in that domain. Prevents partial pruning of state machines.

  - `:blackbox_fanout` — keep all logic fed by any blackbox output (PLL, DCCA etc.)
    since synthesis cannot see inside blackboxes to prove liveness.

  - `:cyclic_state_preservation` — detect strongly connected components (SCCs) in the
    op dataflow graph. Any SCC containing at least one `Reg` is definitionally a state
    machine — its cycle encodes persistent state. Keep all ops in such SCCs.
    Uses Tarjan's algorithm: O(V+E). Zero ambiguity — maps exactly to structural
    state machine definition with no heuristics.

  ## Manual keeps

  Individual signals can be marked with `keep: true` in the DSL (future).
  Currently, signals whose name appears in `design.keep_signals` are always kept.

  ## Usage

      kept = Hw.Compile.KeepPolicy.compute(design, policies: [:blackbox_fanout, :clock_domain_preservation])
      # kept is a MapSet of signal names (atoms)
  """

  alias Hw.IR.Design
  alias Hw.IR.Ops.{Assign, Reg, Blackbox, Mux, Eq, BitAnd, BitOr, BitNot, BitXor,
                   Add, Sub, Gt, Lt, Concat, Slice, MemRead, MemWrite, Tristate}

  @default_policies [:cyclic_state_preservation, :blackbox_fanout, :clock_domain_preservation, :output_reachability]

  @doc """
  Compute the set of signal names that should be kept.

  Returns a `MapSet` of signal name atoms.
  """
  def compute(%Design{} = design, opts \\ []) do
    policies = Keyword.get(opts, :policies, @default_policies)
    manual = MapSet.new(Map.get(design, :keep_signals, []))

    Enum.reduce(policies, manual, fn policy, acc ->
      apply_policy(policy, design, acc)
    end)
  end

  # ---------------------------------------------------------------------------
  # Policy: blackbox_fanout
  # Keep all signals that are outputs of blackbox instances, and then
  # transitively keep all logic driven by those signals.
  # ---------------------------------------------------------------------------

  defp apply_policy(:blackbox_fanout, design, acc) do
    # Collect all signal names that are direct outputs of blackboxes
    blackbox_outputs =
      Enum.reduce(design.ops, MapSet.new(), fn
        %Blackbox{ports: ports}, set ->
          Enum.reduce(ports, set, fn {_port, connection}, s ->
            case connection do
              %{name: name} -> MapSet.put(s, name)
              _ -> s
            end
          end)
        _, set -> set
      end)

    # Also keep clock signals — they're always driven by PLL/DCCA blackboxes
    clock_names = MapSet.new(design.clocks, & &1.name)
    seeds = MapSet.union(blackbox_outputs, clock_names)

    # Transitively expand: keep anything driven by a kept signal
    transitively_expand(seeds, design.ops, acc)
  end

  # ---------------------------------------------------------------------------
  # Policy: output_reachability
  # Backward fanin cone from all top-level output ports.
  # ---------------------------------------------------------------------------

  defp apply_policy(:output_reachability, design, acc) do
    # Seed with all top-level output signal names
    output_names =
      design.signals
      |> Enum.filter(&(&1.direction in [:output, :inout]))
      |> MapSet.new(& &1.name)

    # Build a reverse map: signal name -> list of ops that READ it
    # Then walk backward from outputs
    fanin_expand(output_names, design.ops, acc)
  end

  # ---------------------------------------------------------------------------
  # Policy: clock_domain_preservation
  # If any Reg in a clock domain is kept, keep all Regs in that domain.
  # Prevents partial state machine preservation.
  # ---------------------------------------------------------------------------

  defp apply_policy(:clock_domain_preservation, design, acc) do
    regs = Enum.filter(design.ops, &match?(%Reg{}, &1))

    # Group regs by clock domain
    by_clock = Enum.group_by(regs, & &1.clock.name)

    # For each clock domain, if any reg output is in acc, keep all regs in domain
    Enum.reduce(by_clock, acc, fn {_clock_name, domain_regs}, kept ->
      any_kept = Enum.any?(domain_regs, fn reg ->
        MapSet.member?(kept, reg.output.name)
      end)

      if any_kept do
        Enum.reduce(domain_regs, kept, fn reg, k ->
          MapSet.put(k, reg.output.name)
        end)
      else
        kept
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Policy: cyclic_state_preservation
  # Detect SCCs in the op dataflow graph. Any SCC containing a Reg is a state
  # machine. Keep all ops in such SCCs by adding their output signal names.
  # Uses Tarjan's algorithm for SCC detection: O(V+E).
  # ---------------------------------------------------------------------------

  defp apply_policy(:cyclic_state_preservation, design, acc) do
    ops = design.ops

    # Build a node list — each op gets an integer index
    indexed = ops |> Enum.with_index() |> Enum.map(fn {op, i} -> {i, op} end)
    op_by_index = Map.new(indexed)
    count = length(ops)

    # Build adjacency: signal name -> list of op indices that OUTPUT that signal
    output_index =
      Enum.reduce(indexed, %{}, fn {i, op}, m ->
        case op_output_name(op) do
          nil -> m
          name -> Map.put(m, name, i)
        end
      end)

    # Edges: op i -> op j if op i reads a signal that op j outputs
    # i.e. for each input signal of op i, find the op j that produces it
    adjacency =
      Enum.reduce(indexed, %{}, fn {i, op}, adj ->
        targets =
          op_input_names(op)
          |> Enum.flat_map(fn sig_name ->
            case Map.get(output_index, sig_name) do
              nil -> []
              j -> [j]
            end
          end)
          |> Enum.uniq()
        Map.put(adj, i, targets)
      end)

    # Tarjan's SCC algorithm
    state = %{
      index: 0,
      stack: [],
      on_stack: MapSet.new(),
      indices: %{},
      lowlinks: %{},
      sccs: []
    }

    state =
      Enum.reduce(0..(count - 1), state, fn v, s ->
        if Map.has_key?(s.indices, v), do: s, else: tarjan_strongconnect(v, s, adjacency)
      end)

    # Filter SCCs that contain at least one Reg op
    reg_indices = MapSet.new(indexed, fn {i, op} ->
      if match?(%Reg{}, op), do: i, else: nil
    end) |> MapSet.delete(nil)

    kept_signal_names =
      state.sccs
      |> Enum.filter(fn scc ->
        # SCC must have >1 node OR contain a self-loop (Reg feeds back to itself)
        # AND contain at least one Reg
        _scc_set = MapSet.new(scc)
        has_reg = Enum.any?(scc, &MapSet.member?(reg_indices, &1))
        is_cycle = length(scc) > 1 or has_self_loop(hd(scc), adjacency)
        has_reg and is_cycle
      end)
      |> List.flatten()
      |> Enum.flat_map(fn i ->
        op = Map.get(op_by_index, i)
        # Include both the op's output AND all its input signal names
        [op_output_name(op) | op_input_names(op)]
      end)
      |> Enum.reject(&is_nil/1)

    Enum.reduce(kept_signal_names, acc, &MapSet.put(&2, &1))
  end

  defp has_self_loop(v, adjacency) do
    adjacency |> Map.get(v, []) |> Enum.member?(v)
  end

  # Tarjan's algorithm — iterative to avoid stack overflow on large designs
  defp tarjan_strongconnect(v, state, adjacency) do
    state = %{state |
      indices:  Map.put(state.indices, v, state.index),
      lowlinks: Map.put(state.lowlinks, v, state.index),
      index:    state.index + 1,
      stack:    [v | state.stack],
      on_stack: MapSet.put(state.on_stack, v)
    }

    state =
      Enum.reduce(Map.get(adjacency, v, []), state, fn w, s ->
        cond do
          not Map.has_key?(s.indices, w) ->
            # w not yet visited — recurse
            s = tarjan_strongconnect(w, s, adjacency)
            %{s | lowlinks: Map.put(s.lowlinks, v, min(s.lowlinks[v], s.lowlinks[w]))}

          MapSet.member?(s.on_stack, w) ->
            # w is on stack — it's in the current SCC
            %{s | lowlinks: Map.put(s.lowlinks, v, min(s.lowlinks[v], s.indices[w]))}

          true ->
            s
        end
      end)

    # If v is a root node, pop the SCC
    if state.lowlinks[v] == state.indices[v] do
      {scc, remaining_stack} = pop_until(state.stack, v)
      on_stack = Enum.reduce(scc, state.on_stack, &MapSet.delete(&2, &1))
      %{state | stack: remaining_stack, on_stack: on_stack, sccs: [scc | state.sccs]}
    else
      state
    end
  end

  defp pop_until(stack, v) do
    pop_until(stack, v, [])
  end
  defp pop_until([v | rest], v, acc), do: {[v | acc], rest}
  defp pop_until([h | rest], v, acc), do: pop_until(rest, v, [h | acc])

  # ---------------------------------------------------------------------------
  # Transitive expansion helpers
  # ---------------------------------------------------------------------------

  # Forward expansion: given a set of kept signal names, find all ops whose
  # INPUT is a kept signal, and add their OUTPUT to the kept set. Repeat.
  defp transitively_expand(seeds, ops, acc) do
    initial = MapSet.union(seeds, acc)
    expand_forward(initial, ops, MapSet.new())
  end

  defp expand_forward(kept, ops, visited) do
    newly_kept =
      Enum.reduce(ops, MapSet.new(), fn op, new ->
        inputs = op_input_names(op)
        output = op_output_name(op)

        if output != nil and
           not MapSet.member?(kept, output) and
           not MapSet.member?(visited, output) and
           Enum.any?(inputs, &MapSet.member?(kept, &1)) do
          MapSet.put(new, output)
        else
          new
        end
      end)

    if MapSet.size(newly_kept) == 0 do
      kept
    else
      expand_forward(MapSet.union(kept, newly_kept), ops, MapSet.union(visited, newly_kept))
    end
  end

  # Backward expansion: given a set of output signal names, find all ops that
  # PRODUCE those signals and add their inputs to the kept set. Repeat.
  defp fanin_expand(seeds, ops, acc) do
    initial = MapSet.union(seeds, acc)
    expand_backward(initial, ops, MapSet.new())
  end

  defp expand_backward(kept, ops, visited) do
    newly_kept =
      Enum.reduce(ops, MapSet.new(), fn op, new ->
        output = op_output_name(op)
        inputs = op_input_names(op)

        if output != nil and
           MapSet.member?(kept, output) and
           not MapSet.member?(visited, output) do
          Enum.reduce(inputs, new, fn inp, n -> MapSet.put(n, inp) end)
        else
          new
        end
      end)

    # Only add names not already in kept
    truly_new = MapSet.difference(newly_kept, kept)

    if MapSet.size(truly_new) == 0 do
      kept
    else
      expand_backward(
        MapSet.union(kept, truly_new),
        ops,
        MapSet.union(visited, MapSet.new(Enum.filter(kept, fn n ->
          Enum.any?(ops, fn op -> op_output_name(op) == n end)
        end)))
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Op input/output name extraction
  # ---------------------------------------------------------------------------

  defp op_output_name(%Assign{output: %{name: n}}), do: n
  defp op_output_name(%Reg{output: %{name: n}}), do: n
  defp op_output_name(%Mux{output: %{name: n}}), do: n
  defp op_output_name(%Eq{output: %{name: n}}), do: n
  defp op_output_name(%BitAnd{output: %{name: n}}), do: n
  defp op_output_name(%BitOr{output: %{name: n}}), do: n
  defp op_output_name(%BitNot{output: %{name: n}}), do: n
  defp op_output_name(%BitXor{output: %{name: n}}), do: n
  defp op_output_name(%Add{output: %{name: n}}), do: n
  defp op_output_name(%Sub{output: %{name: n}}), do: n
  defp op_output_name(%Gt{output: %{name: n}}), do: n
  defp op_output_name(%Lt{output: %{name: n}}), do: n
  defp op_output_name(%Concat{output: %{name: n}}), do: n
  defp op_output_name(%Slice{output: %{name: n}}), do: n
  defp op_output_name(%MemRead{output: %{name: n}}), do: n
  defp op_output_name(_), do: nil

  defp op_input_names(%Assign{input: input}), do: signal_names([input])
  defp op_input_names(%Reg{input: input, enable: en}), do: signal_names([input, en])
  defp op_input_names(%Mux{cases: cases, default: default}) do
    case_sigs = Enum.flat_map(cases, fn {cond, val} -> signal_names([cond, val]) end)
    case_sigs ++ signal_names([default])
  end
  defp op_input_names(%Eq{a: a, b: b}), do: signal_names([a, b])
  defp op_input_names(%BitAnd{a: a, b: b}), do: signal_names([a, b])
  defp op_input_names(%BitOr{a: a, b: b}), do: signal_names([a, b])
  defp op_input_names(%BitNot{input: i}), do: signal_names([i])
  defp op_input_names(%BitXor{a: a, b: b}), do: signal_names([a, b])
  defp op_input_names(%Add{a: a, b: b}), do: signal_names([a, b])
  defp op_input_names(%Sub{a: a, b: b}), do: signal_names([a, b])
  defp op_input_names(%Gt{a: a, b: b}), do: signal_names([a, b])
  defp op_input_names(%Lt{a: a, b: b}), do: signal_names([a, b])
  defp op_input_names(%Concat{inputs: inputs}), do: signal_names(inputs)
  defp op_input_names(%Slice{input: i}), do: signal_names([i])
  defp op_input_names(%MemRead{addr: a}), do: signal_names([a])
  defp op_input_names(%MemWrite{addr: a, data: d, enable: en}), do: signal_names([a, d, en])
  defp op_input_names(%Blackbox{ports: ports}) do
    ports |> Enum.map(fn {_, v} -> v end) |> signal_names()
  end
  defp op_input_names(%Tristate{output_value: v, output_enable: en}), do: signal_names([v, en])
  defp op_input_names(_), do: []

  defp signal_names(list) do
    list
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(fn
      %{name: name} -> [name]
      _ -> []
    end)
  end
end
