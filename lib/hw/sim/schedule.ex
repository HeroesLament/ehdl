defmodule Hw.Sim.Schedule do
  @moduledoc """
  Builds the simulation schedule from an elaborated design.

  Two outputs:
  1. `entities` — a map of entity_prefix => %Entity{} containing the ops,
     regs, and clock domain for that instance.
  2. `eval_order` — topologically sorted list of ops across the whole design,
     used by the evaluator. Comb ops are ordered so every op's inputs are
     computed before its output.

  Entity partitioning uses signal name prefixes — all signals/ops whose
  names start with `phy_` belong to the :phy entity, etc. The `_top_` prefix
  is used for ops declared directly in the top-level design (comb blocks in
  HelloBoard.Top itself).

  Cross-entity signals are those whose producing entity differs from at least
  one consuming entity — these are the signals that go into ETS.
  """

  alias Hw.IR.Ops.{Assign, Add, Sub, Mux, Eq, Lt, Gt, BitAnd, BitOr, BitXor,
                   BitNot, Slice, Concat, Reg, Blackbox, Tristate, Mem, MemRead}
  alias Hw.IR.Types.{Signal, Const, Clock}

  defstruct [
    :entities,              # %{atom => %Entity{}}
    :eval_order,            # [op] topologically sorted comb ops
    :cross_signals,         # MapSet of signal names that cross entity boundaries
    :cross_settle_ops,      # [op] minimal ops to propagate cross-entity signals
    :cross_settle_inputs,   # [atom] ETS signal names read by cross_settle_ops
    :top_signal_closures,   # %{atom => {[op], [atom]}} per-signal minimal closure for lazy _top_ eval
    :signal_widths,         # %{atom => integer} for mask computation
    :clocks,                # [%Clock{}]
    :signal_inits,          # %{atom => integer} initial register values (from wire init: / Reg reset_value)
    :memories,              # %{atom => list} memory initial contents
  ]

  defmodule Entity do
    @moduledoc "A single simulated entity (maps to one EHDL instance)."
    defstruct [
      :name,          # :phy, :sie, :uart_rx, :_top_, etc.
      :prefix,        # "phy_", "sie_", "" for top
      :domain,        # :clk_48 | :clk_fast | nil
      :module,        # Hw.USB.FSPhy, Hw.UART.RX, etc. — nil for :_top_
      :ops,           # [op] all ops belonging to this entity
      :regs,          # [%Reg{}] sequential ops only
      :inputs,        # [atom] signal names this entity reads
      :outputs,       # [atom] signal names this entity writes
      :edge_ops,      # [op] | nil — _top_ only (hierarchical designs): minimal
                      #   comb closure feeding _top_'s own regs, evaluated per edge
                      #   instead of the full comb set
      :edge_inputs,   # [atom] | nil — external ETS reads needed by edge_ops
      :settle_ops,    # [op] | nil — _top_ only: comb/tristate closure for
                      #   everything the rest of the design sees of _top_ (official
                      #   cross signals + op-level hidden-prefix consumers +
                      #   tristate line resolution). Promoted to the schedule's
                      #   cross_settle_ops, evaluated by the CLOCK after all
                      #   commits — deterministic last-writer ordering.
      :settle_inputs, # [atom] | nil — external ETS reads needed by settle_ops
      :env_inputs,    # [atom] | nil — _top_ only: external ETS reads needed by the
                      #   FULL comb set (targeted build_env for eval_now/force_reg)
    ]
  end

  @doc """
  Build a Schedule from an elaborated design.
  Raises if a combinational loop is detected.
  """
  def build(design, top_module \\ nil) do
    signal_widths = build_signal_widths(design.signals)

    # Build instance name -> module map from top module's instance declarations
    instance_modules = if top_module && (Code.ensure_loaded?(top_module) and function_exported?(top_module, :__hw_instances__, 0)) do
      top_module.__hw_instances__()
      |> Enum.map(fn inst -> {inst.name, inst.module} end)
      |> Map.new()
    else
      %{}
    end

    # Partition ops into entities by prefix
    entities = partition_entities(design.ops, design.clocks, instance_modules)

    # Topological sort of ALL comb ops across the whole design
    eval_order = topo_sort(design.ops)

    # Reorder each entity's ops to match global topo order so that
    # within-entity comb chains evaluate in dependency order.
    eval_index = eval_order
      |> Enum.with_index()
      |> Map.new(fn {op, i} -> {:erlang.phash2(op), i} end)

    entities = Map.new(entities, fn {name, entity} ->
      sorted_ops = Enum.sort_by(entity.ops, fn op ->
        Map.get(eval_index, :erlang.phash2(op), 999_999)
      end)
      {name, %{entity | ops: sorted_ops}}
    end)

    # Identify signals that cross entity boundaries
    cross_signals = find_cross_signals(entities)

    # Compute the minimal set of _top_ ops needed to propagate cross-entity signals
    # after each commit. This is the transitive dependency closure of the ops that
    # produce cross_signals, walked backwards through _top_'s comb op graph.
    # Only ~9 ops for HelloBoard vs 4799 total — negligible settle cost per tick.
    top_comb = Enum.reject(
      Map.get(entities, :_top_, %{ops: []}).ops,
      &match?(%Reg{}, &1)
    )
    cross_settle_ops = compute_cross_settle_ops(top_comb, cross_signals)

    # Precompute the external ETS inputs needed by cross_settle_ops
    produced = MapSet.new(cross_settle_ops, fn op -> op.output.name end)
    cross_settle_inputs = cross_settle_ops
      |> Enum.flat_map(&op_input_names/1)
      |> Enum.reject(&MapSet.member?(produced, &1))
      |> Enum.uniq()

    # Precompute per-signal minimal op closures for lazy _top_ evaluation.
    # When testbench calls get(:wifi_rxd), we run only the ~3 ops needed for
    # that signal rather than all 4799 _top_ ops. Each entry is {ops, inputs}
    # where inputs are the external ETS signals those ops need to read.
    top_outputs = Map.get(entities, :_top_, %{outputs: []}).outputs
    top_signal_closures = build_top_signal_closures(top_comb, top_outputs)

    # Build signal initial values from wire init: declarations and Reg reset_values.
    # Reg reset_value takes precedence over wire init: 0 defaults.
    signal_inits = Map.new(design.signals, fn sig -> {sig.name, sig.init || 0} end)
    signal_inits = design.ops
      |> Enum.filter(&match?(%Reg{reset_value: %{value: _}}, &1))
      |> Enum.reduce(signal_inits, fn reg, acc ->
        name = reg.output.name
        if Map.get(acc, name, 0) == 0, do: Map.put(acc, name, reg.reset_value.value), else: acc
      end)

    memories = design.ops
      |> Enum.filter(&match?(%Mem{}, &1))
      |> Map.new(fn mem -> {mem.name, mem.init} end)

    # M0: precompute _top_'s per-edge op restriction and targeted env read sets.
    # See enrich_top_entity/2 for the reasoning. When the restriction is active,
    # the settle closure it computes REPLACES cross_settle_ops: it is a superset
    # of the old top-comb cross closure (same expansion, wider seed) and runs in
    # the clock AFTER all commits — which also resolves, deterministically, the
    # multi-writer races legacy resolved by _top_'s slowness (e.g. a Tristate in
    # _top_ and an Assign in phy both writing phy_dp_tx every edge; the Tristate
    # resolution must land last).
    entities = enrich_top_entity(entities, cross_signals)

    {cross_settle_ops, cross_settle_inputs} =
      case Map.get(entities, :_top_) do
        %{settle_ops: ops, settle_inputs: inputs} when is_list(ops) -> {ops, inputs}
        _ -> {cross_settle_ops, cross_settle_inputs}
      end

    %__MODULE__{
      entities:             entities,
      eval_order:           eval_order,
      cross_signals:        cross_signals,
      cross_settle_ops:     cross_settle_ops,
      cross_settle_inputs:  cross_settle_inputs,
      top_signal_closures:  top_signal_closures,
      signal_widths:        signal_widths,
      clocks:               design.clocks,
      signal_inits:         signal_inits,
      memories:             memories,
    }
  end

  # ---------------------------------------------------------------------------
  # Entity partitioning
  # ---------------------------------------------------------------------------

  # Known instance prefixes derived from HelloBoard.Top instance names.
  # In future this could be derived from the design IR directly if instance
  # metadata is preserved post-elaboration.
  # Instance prefix table for HelloBoard.Top.
  # Maps signal prefix -> {entity_atom, clock_domain}.
  # All subsystems run on clk_48 (single-domain design).
  # pll_ has domain nil — it's combinational logic with no registers.
  @instance_prefixes [
    {"pll_",       :pll,      nil},
    {"rst_sync_",  :rst_sync, :clk_48},
    {"phy_",       :phy,      :clk_48},
    {"sie_",       :sie,      :clk_48},
    {"cdc_",       :cdc,      :clk_48},
    {"uart_tx_",   :uart_tx,  :clk_48},
    {"uart_rx_",   :uart_rx,  :clk_48},
    {"prog_",      :prog,     :clk_48},
    {"diag_",      :diag,     :clk_48},
  ]

  defp partition_entities(ops, clocks, instance_modules \\ %{}) do
    clock_map = Map.new(clocks, &{&1.name, &1})

    # Group ops by entity
    grouped = Enum.group_by(ops, &entity_for_op/1)

    # Build a map of signal_name -> producing op for _top_ ops
    top_ops = Map.get(grouped, :_top_, [])
    top_output_map = Map.new(top_ops, fn op ->
      case output_signal(op) do
        %Signal{name: n} -> {n, op}
        nil -> {nil, op}
      end
    end)

    # For each non-_top_ entity, transitively copy _top_ ops that are needed
    # to compute the entity's own reg-next values. We COPY (not move) so that
    # multiple entities can share the same intermediate signal computation.
    # _top_ retains all its ops so it can still settle cross-entity comb.
    updated_grouped = Enum.reduce(grouped, grouped, fn
      {:_top_, _}, grp -> grp
      {entity_name, entity_ops}, grp ->
        copy_needed_ops(grp, entity_name, entity_ops, top_output_map)
    end)

    # Build Entity structs
    Map.new(updated_grouped, fn {entity_name, entity_ops} ->
      prefix = prefix_for_entity(entity_name)
      regs   = Enum.filter(entity_ops, &match?(%Reg{}, &1))
      domain = domain_for_entity(entity_name, clock_map, regs)
      mod    = Map.get(instance_modules, entity_name)

      # Recompute inputs/outputs after pull-in so spec.inputs includes
      # external signals needed by pulled-in ops (e.g. rst, uart_tx_valid)
      inputs  = entity_inputs(entity_ops, prefix)
      outputs = entity_outputs(entity_ops, prefix)

      entity = %Entity{
        name:    entity_name,
        prefix:  prefix,
        domain:  domain,
        module:  mod,
        ops:     entity_ops,
        regs:    regs,
        inputs:  inputs,
        outputs: outputs,
      }

      {entity_name, entity}
    end)
  end

  # Transitively copy _top_ ops into an entity until fixed point.
  # Only copies anonymous intermediate signals (starting with _).
  # Named signals (rst, led etc.) stay in ETS and are read via spec.inputs.
  # Ops are copied not moved — _top_ retains all its ops.
  defp copy_needed_ops(grp, entity_name, entity_ops, top_output_map) do
    entity_produced = entity_ops
      |> Enum.flat_map(&output_signal_names/1)
      |> MapSet.new()

    needed = entity_ops
      |> Enum.flat_map(&op_input_signal_names/1)
      |> MapSet.new()

    copyable = needed
      |> Enum.flat_map(fn name ->
        name_str = Atom.to_string(name)
        cond do
          MapSet.member?(entity_produced, name) -> []
          not String.starts_with?(name_str, "_") -> []
          true ->
            case Map.get(top_output_map, name) do
              nil -> []
              op  -> [op]
            end
        end
      end)
      |> Enum.uniq_by(&output_signal_names/1)

    if Enum.empty?(copyable) do
      grp
    else
      updated_entity = entity_ops ++ copyable
      new_grp = Map.put(grp, entity_name, updated_entity)
      # Recurse with the expanded entity ops (transitive copy)
      copy_needed_ops(new_grp, entity_name, updated_entity, top_output_map)
    end
  end
  defp op_input_signal_names(op) do
    case op do
      %Assign{input: %Signal{name: n}} -> [n]
      %Assign{input: _} -> []
      %{a: %Signal{name: a}, b: %Signal{name: b}} -> [a, b]
      %{a: %Signal{name: a}, b: _} -> [a]
      %{a: _, b: %Signal{name: b}} -> [b]
      %{input: %Signal{name: n}} -> [n]
      %Mux{cases: cases, default: default} ->
        cond_sigs = Enum.flat_map(cases, fn {c, v} ->
          [if(match?(%Signal{}, c), do: c.name, else: nil),
           if(match?(%Signal{}, v), do: v.name, else: nil)]
        end)
        def_sig = if match?(%Signal{}, default), do: [default.name], else: []
        Enum.reject(cond_sigs, &is_nil/1) ++ def_sig
      %Concat{inputs: inputs} ->
        Enum.flat_map(inputs, fn
          %Signal{name: n} -> [n]
          _ -> []
        end)
      _ -> []
    end
  end

  # ---------------------------------------------------------------------------
  # _top_ per-edge restriction (M0)
  # ---------------------------------------------------------------------------
  # _top_ owns every anonymous intermediate op in the design (~40k on
  # HelloBoard.Top) and historically re-evaluated ALL of them on every clock
  # edge — twice (phase 1 and commit) — to settle cross-entity comb. That role
  # has been superseded:
  #   * cross-entity comb is settled inline by Hw.Sim.Clock via
  #     cross_settle_ops (~9 ops on HelloBoard),
  #   * testbench reads of _top_ outputs go through top_signal_closures
  #     (lazy per-signal eval in Hw.Sim.Testbench.get),
  #   * other entities carry copies of the anonymous ops they need
  #     (copy_needed_ops/4).
  # Per edge, _top_ therefore only needs the transitive comb closure feeding
  # its OWN registers — exactly what copy_needed_ops computes for every other
  # entity. We precompute that closure here, plus targeted ETS read sets so
  # build_env never has to materialise the whole signal table.
  #
  # Restriction applies only to hierarchical designs (>1 entity). For a flat
  # component everything lives in _top_ and the full eval IS the simulation —
  # restricting it would change per-tick ETS/trace visibility for no win.
  #
  # The FULL comb set stays available on the explicit testbench path
  # (Entity.eval_now via Testbench.set / force_reg), which uses env_inputs
  # for targeted reads instead of an ETS snapshot.
  # Escape hatch: HW_SIM_TOP_FULL=1 restores the legacy behaviour (full _top_
  # comb eval every edge, snapshot-based env). Kept so the two paths can be
  # differentially tested against each other on the same build — and as an
  # operational fallback if a design surfaces a hole in the closure logic.
  defp enrich_top_entity(entities, cross_signals) do
    if System.get_env("HW_SIM_TOP_FULL") == "1" do
      entities
    else
      do_enrich_top_entity(entities, cross_signals)
    end
  end

  defp do_enrich_top_entity(entities, cross_signals) do
    case Map.get(entities, :_top_) do
      nil -> entities
      top ->
        reg_out_names = MapSet.new(top.regs, & &1.output.name)

        # Mirror Hw.Sim.Entity.init/1's comb_ops filter exactly: no Reg, Mem,
        # Blackbox, and no Assign that writes a reg output (elaborator
        # intermediate feeding the Reg — evaluating it would clobber force_reg).
        comb = Enum.reject(top.ops, fn op ->
          match?(%Reg{}, op) or match?(%Mem{}, op) or match?(%Blackbox{}, op) or
            (match?(%Assign{}, op) and MapSet.member?(reg_out_names, op.output.name))
        end)

        produced_full = comb |> Enum.flat_map(&outs_of/1) |> MapSet.new()

        env_inputs = comb
          |> Enum.flat_map(&reads_of/1)
          |> Enum.uniq()
          |> Enum.reject(&MapSet.member?(produced_full, &1))

        top = %{top | env_inputs: env_inputs}

        top =
          if map_size(entities) > 1 do
            # Output-name -> producing-op map over the filtered comb set. Built
            # via output_signal_names so Tristate ops (no :output field; they
            # "produce" their input_value signal) participate in closures.
            by_out =
              comb
              |> Enum.flat_map(fn op -> Enum.map(outs_of(op), &{&1, op}) end)
              |> Map.new()

            # -- Edge set: ops feeding _top_'s own registers ------------------
            seed = top.regs |> Enum.flat_map(&reads_of/1) |> MapSet.new()
            edge_deps = expand_reads(seed, seed, by_out)
            {edge_ops, edge_inputs} = closure_ops(comb, edge_deps, seed)

            # -- Settle set: what the rest of the design sees of _top_ --------
            # Seeded with (a) the official cross_signals (subsumes the old
            # top-comb cross closure), (b) _top_-produced signals other
            # entities' ops read at the OP level — entity_inputs' prefix filter
            # hides e.g. phy_dp_tx from cross detection — and (c) every
            # Tristate op's writes: a Tristate resolves the LINE value of
            # signals an entity also computes (phy_dp_tx has two writers per
            # edge), and raw-ETS observers (Hw.Sim.USBHost, trace) read those.
            # This whole closure is evaluated by the clock AFTER all commits
            # (it replaces cross_settle_ops), so the tristate resolution lands
            # deterministically last — the ordering legacy got from _top_'s
            # full eval being slow.
            others_ext_reads =
              entities
              |> Enum.reject(fn {n, _} -> n == :_top_ end)
              |> Enum.flat_map(fn {_, e} ->
                prod = e.ops |> Enum.flat_map(&outs_of/1) |> MapSet.new()
                e.ops |> Enum.flat_map(&reads_of/1) |> Enum.reject(&MapSet.member?(prod, &1))
              end)
              |> MapSet.new()

            tristate_outs =
              top.ops
              |> Enum.filter(&match?(%Tristate{}, &1))
              |> Enum.flat_map(&outs_of/1)
              |> MapSet.new()

            settle_out =
              produced_full
              |> MapSet.intersection(others_ext_reads)
              |> MapSet.union(tristate_outs)
              |> MapSet.union(MapSet.new(cross_signals))

            settle_deps = expand_reads(settle_out, settle_out, by_out)
            {settle_ops, settle_inputs} = closure_ops(comb, settle_deps, settle_out)

            %{top | edge_ops: edge_ops, edge_inputs: edge_inputs,
                    settle_ops: settle_ops, settle_inputs: settle_inputs}
          else
            top
          end

        Map.put(entities, :_top_, top)
    end
  end

  # Structural output extractor for the M0 closure machinery. The
  # hand-enumerated output_signal_names/1 below predates half the op set —
  # %Neq{}, %Lte{}, %Shl{}, %ZeroExtend{}, %Popcount{} etc. all fall through
  # to [] there, which silently breaks any dependency walk that relies on it
  # (found the hard way: a _neq_ op in lat_hb_moved's chain was invisible to
  # the edge closure). The generic %{output: %Signal{}} pattern covers every
  # single-output op by shape; Blackbox and Tristate need their own clauses.
  defp outs_of(%Blackbox{ports: ports}) do
    for {_, %Signal{name: n}} <- ports, do: n
  end
  defp outs_of(%Tristate{input_value: %Signal{name: n}}), do: [n]
  defp outs_of(%{output: %Signal{name: n}}), do: [n]
  defp outs_of(_), do: []

  # Transitive-dependency expansion like expand_deps/3, but using reads_of/1
  # (structural walk) so Tristate, MemRead and any future op type participate.
  defp expand_reads(frontier, visited, by_out) do
    if MapSet.size(frontier) == 0 do
      visited
    else
      new_frontier = Enum.reduce(frontier, MapSet.new(), fn name, acc ->
        case Map.get(by_out, name) do
          nil -> acc
          op  -> MapSet.union(acc, MapSet.difference(MapSet.new(reads_of(op)), visited))
        end
      end)
      expand_reads(new_frontier, MapSet.union(visited, new_frontier), by_out)
    end
  end

  # Given a dep-name set, select the producing ops (in existing topo order) and
  # compute the external read set (dep/seed names not produced by the selection).
  defp closure_ops(comb, deps, seed) do
    ops = Enum.filter(comb, fn op ->
      Enum.any?(outs_of(op), &MapSet.member?(deps, &1))
    end)

    produced = ops |> Enum.flat_map(&outs_of/1) |> MapSet.new()

    inputs = (Enum.flat_map(ops, &reads_of/1) ++ MapSet.to_list(seed))
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(produced, &1))

    {ops, inputs}
  end

  # Every signal name an op can read, by structural walk — robust against op
  # types the hand-enumerated input_signal_names/1 clauses don't know about
  # (shifts, popcount, ...). Over-collection is harmless: an extra name just
  # costs one ETS read. MemRead's memory is an atom, not a Signal, so it gets
  # its own clause.
  defp reads_of(%MemRead{} = op), do: [op.memory | deep_signals(Map.from_struct(op), [])]
  defp reads_of(op), do: op |> Map.from_struct() |> deep_signals([])

  defp deep_signals(%Signal{name: n}, acc), do: [n | acc]
  defp deep_signals(%_{} = struct, acc), do: deep_signals(Map.from_struct(struct), acc)
  defp deep_signals(%{} = map, acc),
    do: Enum.reduce(map, acc, fn {_k, v}, a -> deep_signals(v, a) end)
  defp deep_signals(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &deep_signals/2)
  defp deep_signals({a, b}, acc), do: deep_signals(a, deep_signals(b, acc))
  defp deep_signals(_, acc), do: acc

  defp entity_for_op(%Blackbox{name: name}), do: entity_from_signal_name(name)
  defp entity_for_op(%Tristate{io: %Signal{name: name}}), do: entity_from_signal_name(name)
  defp entity_for_op(%Mem{name: name}), do: entity_from_signal_name(name)
  defp entity_for_op(op) do
    case output_signal(op) do
      %Signal{name: name} -> entity_from_signal_name(name)
      nil -> :_top_
    end
  end

  # Signals that are written by CDC logic but named after SIE/top wiring.
  # Moving them to the CDC entity ensures CDC's sequential writes commit correctly.
  @cdc_owned_signals ~w[
    sie_ep_in_ep sie_ep_in_pid sie_ep_in_data
    sie_ep_in_valid sie_ep_in_loaded
    dev_addr
  ]a

  @doc """
  The canonical signal-prefix → `{prefix, entity, domain}` table.

  Exposed read-only so `Hw.Trace.Scope` can derive hierarchical scope from the
  same source that drives entity partitioning (no duplication / drift).
  """
  @spec instance_prefixes() :: [{String.t(), atom(), atom() | nil}]
  def instance_prefixes, do: @instance_prefixes

  @doc """
  Signals written by CDC logic but named after SIE/top wiring (notably
  `dev_addr`). Exposed read-only for `Hw.Trace.Scope`'s ownership override.
  """
  @spec cdc_owned_signals() :: [atom()]
  def cdc_owned_signals, do: @cdc_owned_signals

  defp entity_from_signal_name(name) when name in @cdc_owned_signals, do: :cdc
  defp entity_from_signal_name(name) do
    name_str = Atom.to_string(name)
    case Enum.find(@instance_prefixes, fn {prefix, _, _} ->
      String.starts_with?(name_str, prefix)
    end) do
      {_, entity, _} -> entity
      nil -> :_top_
    end
  end

  defp prefix_for_entity(:_top_), do: ""
  defp prefix_for_entity(entity) do
    case Enum.find(@instance_prefixes, fn {_, e, _} -> e == entity end) do
      {prefix, _, _} -> prefix
      nil -> ""
    end
  end

  defp domain_for_entity(:_top_, clock_map, regs) do
    # Flat components: _top_ has regs and one clock → assign that clock.
    # Hierarchical designs: _top_ may have residual cross-instance regs.
    #   - 0 regs: pure combinational glue → nil (evaluates on signal changes)
    #   - >0 regs, 1 clock: flat component → assign the clock
    #   - >0 regs, multiple clocks: pick the primary clock (clk_48 if present,
    #     otherwise the first non-25MHz clock, otherwise nil)
    case {regs, Map.keys(clock_map)} do
      {[], _}              -> nil
      {_, [single]}        -> single
      {_, clocks}          ->
        # Prefer clk_48 (the main logic clock) over board input clocks
        cond do
          :clk_48 in clocks -> :clk_48
          true              -> nil
        end
    end
  end
  defp domain_for_entity(entity, _clock_map, _regs) do
    case Enum.find(@instance_prefixes, fn {_, e, _} -> e == entity end) do
      {_, _, domain} -> domain
      nil -> nil
    end
  end

  # Inputs to an entity: signals it READS that it doesn't produce itself
  defp entity_inputs(ops, prefix) do
    produced = ops
      |> Enum.flat_map(&output_signal_names/1)
      |> MapSet.new()

    ops
    |> Enum.flat_map(&input_signal_names/1)
    |> Enum.reject(&MapSet.member?(produced, &1))
    |> Enum.reject(&internal_prefix?(&1, prefix))
    |> Enum.uniq()
  end

  # Outputs from an entity: signals it PRODUCES that have external consumers
  defp entity_outputs(ops, _prefix) do
    ops
    |> Enum.flat_map(&output_signal_names/1)
    |> Enum.uniq()
  end

  defp internal_prefix?(_signal, ""), do: false
  defp internal_prefix?(signal, prefix) do
    String.starts_with?(Atom.to_string(signal), prefix)
  end

  # ---------------------------------------------------------------------------
  # Cross-signal detection
  # ---------------------------------------------------------------------------

  defp find_cross_signals(entities) do
    # For each signal, find which entity produces it
    producer_map = entities
      |> Enum.flat_map(fn {name, entity} ->
        Enum.map(entity.outputs, &{&1, name})
      end)
      |> Map.new()

    # A signal crosses a boundary if any consumer entity != producer entity
    entities
    |> Enum.flat_map(fn {consumer_name, entity} ->
      entity.inputs
      |> Enum.filter(fn sig ->
        case Map.get(producer_map, sig) do
          nil -> false  # top-level input, treat as cross
          producer_name -> producer_name != consumer_name
        end
      end)
    end)
    |> MapSet.new()
  end

  # Compute the minimal set of _top_ comb ops needed to produce cross_signals,
  # including their full transitive input dependencies. These ops are run after
  # each commit to propagate register changes (e.g. rst_sync_ready -> rst)
  # to dependent entities before the next clock edge fires.
  # Build a map from each _top_ output signal to its minimal {ops, inputs} closure.
  # O(n) single reverse-topo pass: each op propagates its "contributes to" set
  # forward to ops that read its output, using a prebuilt readers adjacency map.
  defp build_top_signal_closures(top_comb, top_outputs) do
    top_outputs_set = MapSet.new(top_outputs)

    # Build forward adjacency: signal_name -> [op_output_names that read this signal]
    readers = Enum.reduce(top_comb, %{}, fn op, acc ->
      case op do
        %{output: %Signal{name: out_name}} ->
          Enum.reduce(op_input_names(op), acc, fn input_name, acc2 ->
            Map.update(acc2, input_name, [out_name], &[out_name | &1])
          end)
        _ -> acc
      end
    end)

    # Reverse-topo pass: build op_name -> MapSet(final outputs it contributes to)
    # Process ops in reverse topo order so each op sees its downstream contributions
    contributes = Enum.reduce(Enum.reverse(top_comb), %{}, fn op, acc ->
      case op do
        %{output: %Signal{name: n}} ->
          direct = if MapSet.member?(top_outputs_set, n), do: [n], else: []
          propagated = Map.get(readers, n, [])
            |> Enum.flat_map(fn reader_name ->
              Map.get(acc, reader_name, MapSet.new()) |> MapSet.to_list()
            end)
          Map.put(acc, n, MapSet.new(direct ++ propagated))
        _ -> acc
      end
    end)

    # Build output -> {ops, inputs} by collecting ops that contribute to each output
    # First, invert: final_output -> [op_names that contribute to it]
    output_to_op_names = Enum.reduce(contributes, %{}, fn {op_name, final_outputs}, acc ->
      Enum.reduce(final_outputs, acc, fn final_out, acc2 ->
        Map.update(acc2, final_out, [op_name], &[op_name | &1])
      end)
    end)

    by_out = Map.new(top_comb, fn op ->
      case op do %{output: %Signal{name: n}} -> {n, op}; _ -> {nil, op} end
    end)

    # Precompute topo index for fast sort
    topo_index = top_comb
      |> Enum.with_index()
      |> Map.new(fn {op, i} ->
        case op do %{output: %Signal{name: n}} -> {n, i}; _ -> {nil, i} end
      end)

    Enum.reduce(top_outputs, %{}, fn sig_name, acc ->
      op_names = Map.get(output_to_op_names, sig_name, [])
      op_name_set = MapSet.new(op_names)
      ops = op_names
        |> Enum.map(&Map.get(by_out, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(fn op ->
          case op do %{output: %Signal{name: n}} -> Map.get(topo_index, n, 999_999); _ -> 999_999 end
        end)
      produced = op_name_set
      inputs = ops
        |> Enum.flat_map(&op_input_names/1)
        |> Enum.reject(&MapSet.member?(produced, &1))
        |> Enum.uniq()
      Map.put(acc, sig_name, {ops, inputs})
    end)
  end

  defp compute_cross_settle_ops(top_comb, cross_signals) do
    # Build output_name -> op index
    by_out = Map.new(top_comb, fn op ->
      case op do
        %{output: %{name: n}} -> {n, op}
        _ -> {nil, op}
      end
    end)

    # Walk backwards from cross_signals to find all transitive input deps
    all_deps = expand_deps(MapSet.new(cross_signals), MapSet.new(cross_signals), by_out)

    # Filter top_comb to the ops in the dep set, preserving topo order
    Enum.filter(top_comb, fn op ->
      case op do
        %{output: %{name: n}} -> MapSet.member?(all_deps, n)
        _ -> false
      end
    end)
  end

  defp expand_deps(frontier, visited, by_out) do
    if MapSet.size(frontier) == 0 do
      visited
    else
      new_frontier = Enum.reduce(frontier, MapSet.new(), fn name, acc ->
        case Map.get(by_out, name) do
          nil -> acc
          op  ->
            inputs = op_input_names(op)
            new_inputs = MapSet.difference(MapSet.new(inputs), visited)
            MapSet.union(acc, new_inputs)
        end
      end)
      expand_deps(new_frontier, MapSet.union(visited, new_frontier), by_out)
    end
  end

  defp op_input_names(op) do
    case op do
      %{input: %Signal{name: n}}                -> [n]
      %{input: %Const{}}                         -> []
      %{a: a, b: b}                              -> signal_name(a) ++ signal_name(b)
      %{cases: cases, default: default}          ->
        Enum.flat_map(cases, fn {k, v} -> signal_name(k) ++ signal_name(v) end) ++
        signal_name(default)
      %{inputs: inputs}                          -> Enum.flat_map(inputs, &signal_name/1)
      # Blackbox stays opaque here, as before: closure walks must not pull a
      # hard macro's output ports in as dependencies.
      %Blackbox{}                                -> []
      # Any other shape (shift amounts, extends, reductions, ...): structural,
      # same reasoning as input_signal_names/1.
      _                                          -> input_signal_names(op)
    end
  end

  defp signal_name(%Signal{name: n}), do: [n]
  defp signal_name(_), do: []

  # ---------------------------------------------------------------------------
  # Topological sort (Kahn's algorithm)
  # ---------------------------------------------------------------------------

  defp topo_sort(ops) do
    # Separate comb and sequential ops
    # Regs are NOT in the comb eval order — they get latched separately
    comb_ops = Enum.reject(ops, &match?(%Reg{}, &1))
               |> Enum.reject(&match?(%Mem{}, &1))

    # Build dependency graph: op -> set of signal names it depends on
    # and signal -> op that produces it
    producer = build_producer_map(comb_ops)
    deps     = build_dep_map(comb_ops, producer)

    # Kahn's algorithm
    {sorted, remaining} = kahn(comb_ops, deps)

    if Enum.any?(remaining) do
      raise combinational_loop_message(remaining, ops)
    end

    sorted
  end

  # Build a readable combinational-loop error. Two improvements over a raw dump of
  # every op in the cycle:
  #   1. Surface the USER-NAMED signals in the loop (drop `_`-prefixed compiler
  #      intermediates from the headline) so the message points at real wires.
  #   2. Detect the register-aliased-into-comb case — a comb `Assign` whose input is
  #      a register output. That single innocent-looking assignment is the usual
  #      trigger for an otherwise-nonexistent loop, so name it and give the fix.
  defp combinational_loop_message(remaining, all_ops) do
    involved = remaining |> Enum.flat_map(&output_signal_names/1) |> MapSet.new()

    named =
      involved
      |> Enum.reject(fn n -> n |> Atom.to_string() |> String.starts_with?("_") end)
      |> Enum.sort()

    reg_outputs =
      all_ops
      |> Enum.filter(&match?(%Reg{}, &1))
      |> Enum.flat_map(&output_signal_names/1)
      |> MapSet.new()

    # Comb assigns in the cycle whose RHS is directly a registered signal.
    reg_aliases =
      remaining
      |> Enum.flat_map(fn
        %Assign{output: %Signal{name: out}, input: %Signal{name: src}} ->
          if MapSet.member?(reg_outputs, src), do: [{out, src}], else: []
        _ -> []
      end)
      |> Enum.uniq()

    signals_line =
      case named do
        [] -> "Signals involved: #{inspect(Enum.take(Enum.sort(involved), 20))}"
        _  -> "Named signals involved: #{inspect(named)}"
      end

    hint =
      case reg_aliases do
        [] ->
          "Break the loop by registering one signal in the path in an `on :clk` block."

        aliases ->
          lines =
            Enum.map_join(aliases, "\n", fn {out, src} ->
              "    - `#{out} = #{src}` aliases register `#{src}` into combinational logic; " <>
                "register the snapshot instead: `on :clk do #{out} = #{src} end`"
            end)

          "LIKELY CAUSE — a register is aliased into combinational logic. Reading a\n" <>
            "register in a `comb` block (`w = some_register`) smuggles it into the\n" <>
            "combinational graph and can create a loop that does not exist in hardware:\n" <>
            lines <>
            "\nAlternatively, read the register directly at the point of use."
      end

    """
    Combinational loop detected in design!
    #{signals_line}
    #{hint}
    This is a design error — combinational feedback is not synthesizable.
    """
  end

  defp build_producer_map(ops) do
    ops
    |> Enum.flat_map(fn op ->
      Enum.map(output_signal_names(op), &{&1, op})
    end)
    |> Map.new()
  end

  defp build_dep_map(ops, producer) do
    # Reg outputs are STATE — reading them during comb eval returns the current
    # latched value. Blackbox and Tristate outputs are OPAQUE SOURCES — we don't
    # model their internals. Exclude all of these from dependency tracking to
    # prevent false cycles (e.g. PLL CLKFB feedback path).
    opaque_outputs = ops
      |> Enum.filter(&match?(%Reg{}, &1) or match?(%Blackbox{}, &1) or match?(%Tristate{}, &1))
      |> Enum.flat_map(&output_signal_names/1)
      |> MapSet.new()

    Map.new(ops, fn op ->
      deps = op
        |> input_signal_names()
        |> Enum.reject(&MapSet.member?(opaque_outputs, &1))
        |> Enum.filter(&Map.has_key?(producer, &1))
        |> MapSet.new()
      {op, deps}
    end)
  end

  defp kahn(ops, deps) do
    # Build reverse adjacency: signal -> list of ops that depend on it
    # This allows O(e) updates instead of O(n) full-map rebuilds.
    signal_to_dependents = Enum.reduce(deps, %{}, fn {op, dep_signals}, acc ->
      Enum.reduce(dep_signals, acc, fn sig, a ->
        Map.update(a, sig, [op], &[op | &1])
      end)
    end)

    # In-degree map: op -> count of unsatisfied dependencies
    in_degree = Map.new(deps, fn {op, dep_set} -> {op, MapSet.size(dep_set)} end)

    # Find ops with no dependencies (ready to evaluate)
    {ready, _blocked} = Enum.split_with(ops, fn op -> Map.get(in_degree, op, 0) == 0 end)

    kahn_loop(ready, ops, in_degree, signal_to_dependents, [])
  end

  defp kahn_loop([], all_ops, in_degree, _s2d, sorted) do
    # Remaining = ops not yet processed (in_degree != -1, i.e. still have unmet deps)
    remaining = Enum.filter(all_ops, fn op -> Map.get(in_degree, op, 0) > 0 end)
    {Enum.reverse(sorted), remaining}
  end

  defp kahn_loop([op | ready], all_ops, in_degree, s2d, sorted) do
    # Mark this op as done (in_degree = -1 means processed)
    in_degree = Map.put(in_degree, op, -1)

    # For each signal this op produces, decrement in-degree of dependent ops
    {newly_ready, in_degree} = Enum.reduce(output_signal_names(op), {[], in_degree}, fn sig, {nr, id} ->
      dependents = Map.get(s2d, sig, [])
      Enum.reduce(dependents, {nr, id}, fn dep_op, {nr2, id2} ->
        new_count = Map.get(id2, dep_op, 0) - 1
        id3 = Map.put(id2, dep_op, new_count)
        if new_count == 0, do: {[dep_op | nr2], id3}, else: {nr2, id3}
      end)
    end)

    kahn_loop(ready ++ newly_ready, all_ops, in_degree, s2d, [op | sorted])
  end

  # ---------------------------------------------------------------------------
  # Signal width map
  # ---------------------------------------------------------------------------

  defp build_signal_widths(signals) do
    Map.new(signals, &{&1.name, &1.width})
  end

  # ---------------------------------------------------------------------------
  # Op signal extraction helpers
  # ---------------------------------------------------------------------------

  # Extract the output signal from an op
  # Structural, not enumerated. The previous per-op clause list covered only
  # Assign/Add/Sub/Mux/Eq/Lt/Gt/bitwise/Slice/Concat/MemRead/Reg: every other
  # single-output op (Gte, Lte, Neq, shifts, extends, Mul/Div/Mod, reductions,
  # Popcount, ...) fell through to nil, so topo_sort never saw it as a
  # producer and its consumers could be ordered BEFORE it. Found 2026-09-24 via
  # Hw.AXIHPReader: `fill >= 128` (Gte) and `rlast != is_last_beat` (Neq) were
  # read before produced; the full-ETS-snapshot env masked it by supplying
  # one-edge-stale values, and the M0 targeted env exposed it. Blackbox and
  # Tristate have no :output field and are handled in output_signal_names/1.
  defp output_signal(%{output: %Signal{} = s}), do: s
  defp output_signal(_),                        do: nil

  defp output_signal_names(op) do
    case output_signal(op) do
      %Signal{name: name} -> [name]
      nil ->
        # Blackbox: all output ports
        case op do
          %Blackbox{ports: ports} ->
            ports
            |> Enum.filter(fn {_, v} -> match?(%Signal{}, v) end)
            |> Enum.map(fn {_, %Signal{name: name}} -> name end)
          %Tristate{input_value: %Signal{name: n}} -> [n]
          _ -> []
        end
    end
  end

  defp input_signal_names(%Assign{input: i}),  do: sig_names([i])
  defp input_signal_names(%Add{a: a, b: b}),   do: sig_names([a, b])
  defp input_signal_names(%Sub{a: a, b: b}),   do: sig_names([a, b])
  defp input_signal_names(%Eq{a: a, b: b}),    do: sig_names([a, b])
  defp input_signal_names(%Lt{a: a, b: b}),    do: sig_names([a, b])
  defp input_signal_names(%Gt{a: a, b: b}),    do: sig_names([a, b])
  defp input_signal_names(%BitAnd{a: a, b: b}), do: sig_names([a, b])
  defp input_signal_names(%BitOr{a: a, b: b}),  do: sig_names([a, b])
  defp input_signal_names(%BitXor{a: a, b: b}), do: sig_names([a, b])
  defp input_signal_names(%BitNot{input: i}),   do: sig_names([i])
  defp input_signal_names(%Slice{input: i}),    do: sig_names([i])
  defp input_signal_names(%Concat{inputs: is}), do: sig_names(is)
  defp input_signal_names(%Mux{cases: cases, default: default}) do
    case_sigs = Enum.flat_map(cases, fn {cond, val} -> sig_names([cond, val]) end)
    case_sigs ++ sig_names([default])
  end
  defp input_signal_names(%Reg{input: i, clock: %Clock{name: clk}, enable: en, async_reset: ar}) do
    sig_names([i]) ++ sig_names([en]) ++ sig_names([ar]) ++ [clk]
  end
  defp input_signal_names(%MemRead{memory: mem, addr: addr}) do
    [mem] ++ sig_names([addr])
  end
  defp input_signal_names(%Blackbox{ports: ports}) do
    ports
    |> Enum.flat_map(fn {_, v} -> sig_names([v]) end)
  end
  defp input_signal_names(%Tristate{output_value: ov, output_enable: oe}) do
    sig_names([ov, oe])
  end
  # Structural fallback for every other op: all Signals anywhere in the struct
  # except the :output field. Replaces a `_ -> []` that silently gave Gte,
  # Lte, Neq, shifts, extends, Mul/Div/Mod, reductions, Popcount, MemWrite etc.
  # NO inputs, so topo_sort placed them before their producers (see
  # output_signal/1). The explicit clauses above stay for the ops whose shape
  # a generic walk would get wrong: Reg (clock is a dependency), MemRead
  # (memory is an atom), Blackbox (ports are in+out), Tristate (input_value is
  # its output).
  defp input_signal_names(op) when is_struct(op) do
    op
    |> Map.from_struct()
    |> Map.drop([:output])
    |> deep_signals([])
    |> Enum.uniq()
  end
  defp input_signal_names(_), do: []

  defp sig_names(list) do
    list
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(fn
      %Signal{name: name} -> [name]
      %Const{} -> []
      _ -> []
    end)
  end
end
