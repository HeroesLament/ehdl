defmodule Hw.Analysis.Rules.DeadRegister do
  @moduledoc """
  Detects a register whose value can never be observed at the module boundary —
  it is computed every cycle but its transitive fan-out never reaches an output
  port, an inout port, or a submodule/tristate input.

  ## Why this is a bug

  This is the structural dual of `Hw.Analysis.Rules.UndrivenOutput`. That rule
  asks "does every output have a driver?"; this one asks "can every register's
  value reach a pin?". A register that only feeds *itself* (a shift register that
  shifts into its own next-value) and combinational logic that loops back into
  the same dead cluster is unobservable: deleting it would change nothing at any
  boundary signal.

  This is exactly the defect that wedged USB enumeration. The SIE computed a
  correct transmit CRC into `tx_crc_buf` and shifted it every cycle in the
  `:tx_crc` state — but the serial-output selector `phy_tx_data` was hardwired to
  `tx_shift[0]` and never selected `tx_crc_buf`. So `tx_crc_buf` was a *staged
  parcel with no courier*: an FSM state existed to emit it, the value was
  prepared correctly, and the wire that would carry it to the pin was missing.
  Every DATA packet went out with no CRC, the host rejected all of them, and the
  failure surfaced far away as an intermittent "control-IN never completes."

  A value-over-time tool (waveform, dashboard) cannot see this — `tx_crc_buf`
  held perfectly correct bits the whole time. The defect lives only in
  *connectivity*, a graph property, so it belongs in the rule layer.

  ## What is checked

  Build the transitive fan-out of every `Ops.Reg` output by walking op inputs.
  A register is observable if that fan-out reaches an output/inout port, or a
  tristate, or a submodule (`Blackbox`) input connection. Reaching *another
  register* does NOT by itself count — that register may be dead too — so the
  walk continues *through* reg-to-reg edges and only declares observability at a
  genuine boundary sink. A register whose fan-out reaches no boundary sink is
  reported dead.

  Signals beginning with `_` (compiler-generated intermediates) are never
  reported as the dead register itself, though they are traversed for fan-out.

  ## The affine "must-terminate" framing (and its escape hatch)

  This is the sink half of a borrow-checker-style discipline for hardware. The
  ownership half — one driver per net — is already enforced by
  `Hw.Analysis.Rules.MultipleDrivers`. This rule adds the *affine obligation*:
  every produced value must be **consumed** (reach a boundary sink) or explicitly
  discarded. It is the exact dual of Rust's unused-value / `#[must_use]` lint,
  and the FSM state that stages a value is that value's lifetime scope.

  Like Rust's `let _ = expr`, intentional exceptions get an explicit escape
  hatch: **name a deliberately-unobservable register with a leading `_`** (e.g.
  scratch/instrumentation/sweep-tap registers). Such names are skipped. Designs
  that carry a lot of intentional dead scaffolding (debug latches, unused
  synchronizer taps) will otherwise light up here — that is the rule working, not
  failing; annotate those registers or run this rule as advisory.

  ## Scope and honesty caveat

  Observability is computed **per module** (per `__hw_design__/0`). A submodule
  input is treated as an observable sink — conservatively, so a register that
  feeds a submodule is never called dead even if that submodule's use of it is
  itself dead. This is the safe failure mode for a lint (false negatives, not
  false positives), but it means this rule cannot see a dead cluster that hides
  entirely behind a live-elsewhere shared submodule. Catching that would require
  a whole-design, per-context liveness pass; this rule deliberately stays local.

  ## The fix

  Route the register to where its value is meant to be observed. For the CRC
  case, that was the missing mux arm on the output selector:

      # WRONG — the serial output never selects the CRC register:
      tx_cur_bit = tx_shift[0..0]

      # RIGHT — during the CRC state, drive the CRC register onto the wire:
      tx_cur_bit = if tx_state == 4, do: tx_crc_buf[0..0], else: tx_shift[0..0]

  If the register really is scratch state with no observable effect, delete it.

  ## Priority

  Runs at priority 55 — after the connectivity checks (undriven/unconnected at
  50) and before the loop checks, so a "computed but unobservable" register is
  reported as its own actionable finding.
  """

  @behaviour Hw.Analysis.Rule

  alias Hw.Analysis.{Diagnostic, Location}
  alias Hw.IR.Ops.{Reg, Tristate, Blackbox}
  alias Hw.IR.Types.{Signal, Const}

  @impl Hw.Analysis.Rule
  def priority, do: 55

  @impl Hw.Analysis.Rule
  def run(%{components: components}) do
    Enum.flat_map(components, fn comp ->
      case safe_design(comp.module) do
        nil -> []
        design -> check_design(design, comp.module)
      end
    end)
  end

  defp check_design(design, module) do
    regs = Enum.filter(design.ops, &match?(%Reg{}, &1))

    port_sinks =
      design.signals
      |> Enum.filter(&(&1.direction in [:output, :inout]))
      |> MapSet.new(& &1.name)

    fanout = build_fanout_graph(design.ops)

    Enum.flat_map(regs, fn %Reg{output: out} ->
      name = sig_name(out)

      cond do
        name == nil -> []
        compiler_generated?(name) -> []
        observable?(name, fanout, port_sinks) -> []
        true -> [dead_diagnostic(name, out, design, module, fanout)]
      end
    end)
  end

  defp dead_diagnostic(name, out, design, module, fanout) do
    loc = signal_loc(out, design) || fallback(module)
    states = staging_states(name, fanout, design)

    staged =
      case states do
        [] -> ""
        ss -> " It is staged under FSM state(s) #{Enum.join(ss, ", ")} but no output is driven from it there — the emit path was likely never wired."
      end

    Diagnostic.warning(
      :dead_register,
      "register `:#{name}` on #{inspect(module)} is computed every cycle but its " <>
        "value never reaches an output port, a tristate, or a submodule input — " <>
        "it is unobservable (dead).#{staged}",
      loc,
      context: %{signal: name, module: module, staging_states: states},
      related: [
        %{
          location: loc,
          message:
            "route `#{name}` to where it should be observed (e.g. add the missing " <>
              "mux arm on the output selector), or delete it if genuinely unused"
        }
      ]
    )
  end

  # --- observability walk ----------------------------------------------------

  # A register is observable iff its value transitively reaches a boundary sink:
  # an output/inout port name (in `ports`) or the :__sink__ marker (submodule /
  # tristate input). Reaching another register just continues the walk.
  defp observable?(start, fanout, ports) do
    # A register whose own name IS an output/inout port drives a pin directly —
    # it is trivially observable, regardless of whether anything else reads it.
    MapSet.member?(ports, start) or do_bfs([start], MapSet.new([start]), fanout, ports)
  end

  defp do_bfs([], _seen, _fanout, _ports), do: false

  defp do_bfs([node | rest], seen, fanout, ports) do
    readers = Map.get(fanout, node, [])

    if Enum.any?(readers, fn r -> r == :__sink__ or MapSet.member?(ports, r) end) do
      true
    else
      next = Enum.reject(readers, &(&1 == :__sink__ or MapSet.member?(seen, &1)))
      do_bfs(rest ++ next, MapSet.union(seen, MapSet.new(next)), fanout, ports)
    end
  end

  # --- fan-out graph ---------------------------------------------------------

  # name -> [reader-name | :__sink__].
  #
  # Robust to every op struct WITHOUT enumerating op types: any struct field
  # whose key starts with "output" is an output; every other field (except
  # :clock) is a read. Each read signal name gets an edge to each output name.
  # Tristate and Blackbox (submodule) connections carry the value out of this
  # module's visibility, so *all* their signal fields edge to :__sink__.
  defp build_fanout_graph(ops) do
    Enum.reduce(ops, %{}, fn op, acc ->
      case op do
        %Tristate{} -> add_edges(acc, all_signal_names(op), :__sink__)
        %Blackbox{} -> add_edges(acc, all_signal_names(op), :__sink__)
        _ ->
          outs = output_names(op)
          reads = read_names(op)

          if outs == [] do
            add_edges(acc, reads, :__sink__)
          else
            Enum.reduce(outs, acc, fn o, a -> add_edges(a, reads, o) end)
          end
      end
    end)
  end

  defp add_edges(acc, [], _reader), do: acc

  defp add_edges(acc, read_names, reader) do
    Enum.reduce(read_names, acc, fn rn, a ->
      Map.update(a, rn, [reader], &[reader | &1])
    end)
  end

  # --- staging-state attribution (narrative only) ----------------------------

  # Best-effort: the FSM state constants under which this dead register is
  # written. We look at the register's next-value cone for `Eq(state_reg, k)`
  # decode nodes that gate it. Purely for a legible diagnostic; never affects
  # whether the register is flagged.
  defp staging_states(name, _fanout, design) do
    # Collect Eq(reg, const) nodes: candidate state decodes -> {eq_out_name, k}.
    eqs =
      Enum.flat_map(design.ops, fn op ->
        if op.__struct__ |> Module.split() |> List.last() == "Eq" do
          fields = op |> Map.from_struct()
          out = fields[:output]
          vals = fields |> Map.drop([:output]) |> Map.values() |> List.flatten()
          consts = Enum.flat_map(vals, fn %Const{} = c -> [const_val(c)]; _ -> [] end)

          case {out, consts} do
            {%Signal{name: on}, [k]} -> [{on, k}]
            _ -> []
          end
        else
          []
        end
      end)
      |> Map.new()

    # Find the Reg for `name`; scan its input cone (one hop of mux conditions)
    # for those eq nodes.
    reg = Enum.find(design.ops, &(match?(%Reg{}, &1) and sig_name(&1.output) == name))

    case reg do
      %Reg{input: inp} ->
        cone = cone_names(inp, design, MapSet.new(), 0)

        cone
        |> Enum.flat_map(fn n -> if Map.has_key?(eqs, n), do: [eqs[n]], else: [] end)
        |> Enum.uniq()
        |> Enum.sort()

      _ ->
        []
    end
  end

  # Shallow backward cone of a value: the names it is built from, following
  # Assign/Mux/Slice/etc. inputs a bounded number of hops. Bounded to keep it
  # cheap; this is only for the diagnostic string.
  defp cone_names(_v, _design, acc, depth) when depth > 6, do: acc

  defp cone_names(v, design, acc, depth) do
    names = value_names(v)

    Enum.reduce(names, acc, fn n, a ->
      if MapSet.member?(a, n) do
        a
      else
        a = MapSet.put(a, n)
        # find the op that drives n and recurse into its reads
        drv =
          Enum.find(design.ops, fn op ->
            n in output_names(op)
          end)

        case drv do
          nil -> a
          op -> cone_names_list(read_values(op), design, a, depth + 1)
        end
      end
    end)
  end

  defp cone_names_list(vs, design, acc, depth) do
    Enum.reduce(vs, acc, fn v, a -> cone_names(v, design, a, depth) end)
  end

  # --- name / value extraction -----------------------------------------------

  defp output_names(op) do
    op
    |> Map.from_struct()
    |> Enum.filter(fn {k, _} -> String.starts_with?(Atom.to_string(k), "output") end)
    |> Enum.flat_map(fn {_k, v} -> value_names(v) end)
  end

  defp read_names(op) do
    op
    |> Map.from_struct()
    |> Enum.reject(fn {k, _} ->
      ks = Atom.to_string(k)
      k == :clock or String.starts_with?(ks, "output")
    end)
    |> Enum.flat_map(fn {_k, v} -> value_names(v) end)
  end

  # Raw read *values* (not just names), for cone recursion.
  defp read_values(op) do
    op
    |> Map.from_struct()
    |> Enum.reject(fn {k, _} ->
      ks = Atom.to_string(k)
      k == :clock or String.starts_with?(ks, "output")
    end)
    |> Enum.map(fn {_k, v} -> v end)
  end

  defp all_signal_names(op) do
    op |> Map.from_struct() |> Map.values() |> Enum.flat_map(&value_names/1)
  end

  defp value_names(%Signal{name: n}), do: [n]
  defp value_names(%Const{}), do: []
  defp value_names(nil), do: []
  defp value_names(list) when is_list(list), do: Enum.flat_map(list, &value_names/1)
  defp value_names(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.flat_map(&value_names/1)
  # Do NOT recurse into arbitrary nested structs: IR operands are flattened to
  # named Signals, so any other struct here (e.g. a Location) is metadata, not a
  # dependency. Recursing was pulling in spurious edges that made dead registers
  # look observable.
  defp value_names(_), do: []

  defp sig_name(%Signal{name: n}), do: n
  defp sig_name(n) when is_atom(n), do: n
  defp sig_name(_), do: nil

  defp const_val(%Const{} = c), do: Map.get(c, :value)

  defp compiler_generated?(name) do
    name |> Atom.to_string() |> String.starts_with?("_")
  end

  defp signal_loc(%Signal{source_location: %Location{} = loc}, _design), do: loc

  defp signal_loc(signal, design) do
    Enum.find_value(design.signals, fn s ->
      if s.name == sig_name(signal), do: s.source_location
    end)
  end

  defp safe_design(module) do
    try do
      # Code.ensure_loaded?/1 forces the module to load; function_exported?/3
      # alone returns false for a not-yet-loaded module (e.g. in a standalone
      # `mix run` script), which silently yielded an empty design.
      if Code.ensure_loaded?(module) and function_exported?(module, :__hw_design__, 0),
        do: module.__hw_design__()
    rescue
      _ -> nil
    end
  end

  defp fallback(module),
    do: %Location{file: "unknown", line: 0, module: module}
end
