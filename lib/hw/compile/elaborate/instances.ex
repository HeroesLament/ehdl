defmodule Hw.Compile.Elaborate.Instances do
  @moduledoc """
  Instance elaboration and connection handling.

  Handles flattening of module hierarchy and interface connections.
  """

  alias Hw.IR.Design
  alias Hw.IR.Types.{Signal, Const}
  alias Hw.IR.Ops

  @doc """
  Elaborate all instances, returning {design, signal_map, instance_map}.
  """
  def elaborate_instances(design, instances, clock_map, signal_map, logic_elaborator, parent_param_map \\ %{}) do
    Enum.reduce(instances, {design, signal_map, %{}}, fn inst, {d, sig_map, inst_map} ->
      elaborate_instance(d, inst, clock_map, sig_map, inst_map, logic_elaborator, parent_param_map)
    end)
  end

  defp elaborate_instance(design, %{name: inst_name, module: child_module, ports: port_map}, clock_map, signal_map, instance_map, _logic_elaborator, parent_param_map) do
    # `function_exported?/3` answers false for a module that has not been loaded
    # yet, so the child must be loaded before any optional-callback probe below.
    # (This used to happen by accident, as a side effect of the first
    # `child_module.__hw_*__()` call. Relying on that meant a cold VM silently
    # saw zero parameters.)
    Code.ensure_loaded!(child_module)

    # Get child's definition
    child_clocks = child_module.__hw_clocks__()
    child_signals = child_module.__hw_signals__()
    child_logic = child_module.__hw_logic__()
    child_instances = get_instances(child_module)

    # Build the child's own defhw map so defhw calls inside the child's
    # logic blocks resolve correctly when elaborated as an instance.
    # sim_only defhws (containing `on` blocks) are excluded from hardware
    # elaboration — they are only used by the simulation interpreter.
    child_defhws = if (Code.ensure_loaded?(child_module) and function_exported?(child_module, :__hw_defhw__, 0)),
      do: child_module.__hw_defhw__(), else: []
    child_defhw_map = child_defhws
      |> Enum.reject(fn d -> Map.get(d, :sim_only, false) end)
      |> Map.new(fn d -> {d.name, d} end)

    # Resolve the child's parameters before anything that depends on them:
    # signal widths, memories, grandchild instances and the child's own logic.
    #
    # port_map carries both signal connections and parameter overrides
    # (e.g. CLKOP_DIV: 13); parameters are matched out of it by name. A value
    # written as a bare uppercase name is a reference to one of the *enclosing*
    # module's parameters — see resolve_instance_param/4.
    child_params = if (Code.ensure_loaded?(child_module) and function_exported?(child_module, :__hw_params__, 0)),
      do: child_module.__hw_params__(), else: []
    param_names = MapSet.new(child_params, & &1.name)
    child_params_with_values = Enum.map(child_params, fn p ->
      case Keyword.get(port_map, p.name) do
        nil -> p
        val -> Map.put(p, :value, resolve_instance_param(val, parent_param_map, inst_name, p.name))
      end
    end)
    child_param_map = Hw.Compile.Elaborate.build_param_map_pub(child_params_with_values)

    # Build child's internal maps (unprefixed)
    child_clock_map = build_clock_map(child_clocks)
    child_signal_map = build_signal_map(child_signals, child_param_map)

    # Create prefixed signals for child's ports and internals
    {design, prefixed_signal_map} = create_prefixed_signals(design, inst_name, child_signal_map, signal_map, port_map)

    # Map clocks from port_map to parent clocks
    child_clock_map = map_child_clocks(child_clock_map, port_map, clock_map)

    # Register any synthetic clocks (PLL outputs etc.) into the design
    # so the validator can find them. Only add clocks whose name matches
    # the parent-side name (the mapped value), not the child-side prefixed name.
    # This prevents e.g. :pll_clk_48mhz from leaking as a top-level port
    # when the intent is :clk_48 (a wire driven by the PLL blackbox).
    parent_clock_names = MapSet.new(clock_map, fn {_, clk} -> clk.name end)
    known_clock_names = MapSet.new(design.clocks, & &1.name)
    design = Enum.reduce(child_clock_map, design, fn {_child_name, clk}, d ->
      already_known = MapSet.member?(known_clock_names, clk.name)
      is_parent_clock = MapSet.member?(parent_clock_names, clk.name)
      if already_known or is_parent_clock do
        d
      else
        Hw.IR.Design.add_clock(d, clk)
      end
    end)

    # Build merged signal map for child elaboration
    merged_signal_map = Map.merge(signal_map, prefixed_signal_map)

    # Build a child-specific elaborator that uses the child's own defhw_map.
    # This ensures defhw calls inside child logic blocks resolve correctly,
    # and also propagates into grandchild instance elaboration.
    child_logic_elaborator = fn d, lb, cm, sm, im, mm, cwm ->
      Hw.Compile.Elaborate.elaborate_logic_block(d, lb, cm, sm, im, mm, child_defhw_map, cwm)
    end

    # Recursively elaborate child instances, handing them the child's resolved
    # params as their enclosing scope.
    {design, merged_signal_map, child_instance_map} =
      elaborate_child_instances(design, child_instances, inst_name, child_clock_map, merged_signal_map, child_logic_elaborator, child_param_map)
    # Build child memory map (prefixed) and add memories to design
    child_raw_memories = if (Code.ensure_loaded?(child_module) and function_exported?(child_module, :__hw_memories__, 0)),
      do: child_module.__hw_memories__(), else: []
    # Also filter port_map to remove param keys so they don't confuse signal resolution
    port_map = Keyword.reject(port_map, fn {k, _} -> MapSet.member?(param_names, k) end)

    {design, child_memory_map} = Enum.reduce(child_raw_memories, {design, %{}}, fn mem, {d, mmap} ->
      resolved_width = Hw.Compile.Elaborate.resolve_param_pub(mem.width, child_param_map)
      resolved_depth = Hw.Compile.Elaborate.resolve_param_pub(mem.depth, child_param_map)
      mem_op = %Hw.IR.Ops.Mem{
        name: :"#{inst_name}_#{mem.name}",
        width: resolved_width,
        depth: resolved_depth,
        init: mem[:init],
        sync_read: mem[:sync_read] || false
      }
      d = Hw.IR.Design.add_op(d, mem_op)
      {d, Map.put(mmap, mem.name, mem_op)}
    end)

    # Elaborate child blackboxes (using prefixed signal map)
    child_blackboxes = if (Code.ensure_loaded?(child_module) and function_exported?(child_module, :__hw_blackboxes__, 0)),
      do: child_module.__hw_blackboxes__(), else: []
    design = Enum.reduce(child_blackboxes, design, fn bb, d ->
      ports = for {port_name, connection} <- bb.ports do
        case connection do
          n when is_integer(n) ->
            {port_name, %Hw.IR.Types.Const{value: n, width: 1, signed: :unsigned}}
          name when is_atom(name) ->
            {port_name, Map.get(prefixed_signal_map, name, Map.get(merged_signal_map, name, name))}
          other ->
            {port_name, other}
        end
      end
      # Resolve any param references in blackbox params.
      # Values may be: integers (pass through), strings (pass through),
      # atoms that name a param (look up in child_param_map),
      # or %Param{} structs (extract .value).
      resolved_params = Enum.map(bb.params, fn {k, v} ->
        resolved = case v do
          %{__struct__: Hw.IR.Types.Param, value: val} when not is_nil(val) ->
            val
          %{__struct__: Hw.IR.Types.Param, name: param_name} ->
            case Map.get(child_param_map, param_name) do
              %{value: val} when not is_nil(val) -> val
              _ -> raise "Unresolved PLL param: #{param_name}"
            end
          atom when is_atom(atom) ->
            case Map.get(child_param_map, atom) do
              nil -> atom
              %{value: val} when not is_nil(val) -> val
              other -> other
            end
          other -> other
        end
        {k, resolved}
      end)

      blackbox_op = %Hw.IR.Ops.Blackbox{
        name: :"#{inst_name}_#{bb.name}",
        module: bb.module,
        params: resolved_params,
        ports: ports,
        attrs: Map.get(bb, :attrs, [])
      }
      Hw.IR.Design.add_op(d, blackbox_op)
    end)

    # Elaborate child tristates (using prefixed signal map)
    child_tristates = if (Code.ensure_loaded?(child_module) and function_exported?(child_module, :__hw_tristates__, 0)),
      do: child_module.__hw_tristates__(), else: []
    design = Enum.reduce(child_tristates, design, fn ts, d ->
      lookup = fn name -> Map.get(prefixed_signal_map, name, Map.get(merged_signal_map, name)) end
      tristate_op = %Hw.IR.Ops.Tristate{
        io:            lookup.(ts.io),
        output_value:  lookup.(ts.output),
        output_enable: lookup.(ts.enable),
        input_value:   lookup.(ts.input)
      }
      Hw.IR.Design.add_op(d, tristate_op)
    end)

    # Process child's logic blocks
    # Inject resolved child params as %Const{} into the signal_map so that
    # build_expr can fold param arithmetic (e.g. CLK_FREQ / BAUD_RATE - 1)
    # into concrete constants rather than unresolvable ParamRef chains.
    param_const_map = child_param_map
      |> Enum.flat_map(fn {name, param} ->
        case param.value do
          v when is_integer(v) ->
            [{name, %Hw.IR.Types.Const{value: v, width: 32, signed: :unsigned}}]
          _ -> []
        end
      end)
      |> Map.new()

    param_signal_map = Map.merge(merged_signal_map, param_const_map)

    # Build const wire map for this child's logic (resolves constant alias wires
    # like `zero = 0`, `w2_0 = 0` so extract_reset can produce correct reset values).
    child_const_wire_map = Enum.reduce(child_logic, %{}, fn block, acc ->
      Enum.reduce(block.body, acc, fn stmt, a ->
        case stmt do
          %{type: :assign, target: name, value: {:const, n}} -> Map.put(a, name, n)
          _ -> a
        end
      end)
    end)

    design = Enum.reduce(child_logic, design, fn logic_block, d ->
      child_logic_elaborator.(d, logic_block, child_clock_map, param_signal_map, child_instance_map, child_memory_map, child_const_wire_map)
    end)

    # Process child FSMs — must run after logic blocks, using the same
    # param_signal_map so the state signal resolves to its prefixed name.
    child_fsms = if (Code.ensure_loaded?(child_module) and function_exported?(child_module, :__hw_fsm__, 0)),
      do: child_module.__hw_fsm__(), else: []
    design = Enum.reduce(child_fsms, design, fn fsm, d ->
      Hw.Compile.Elaborate.elaborate_fsm(d, fsm, child_clock_map, param_signal_map, child_instance_map, child_memory_map, child_defhw_map, child_const_wire_map)
    end)

    # Create port connections
    design = create_port_connections(design, inst_name, child_signal_map, port_map, signal_map, prefixed_signal_map)

    # Add this instance's signals to instance_map
    instance_signals = for {child_sig_name, prefixed_sig} <- prefixed_signal_map, into: %{} do
      {child_sig_name, prefixed_sig}
    end
    instance_map = Map.put(instance_map, inst_name, instance_signals)

    # Hand the ENCLOSING scope back to the caller, not the child-priority map.
    #
    # `merged_signal_map` is keyed by the child's *unprefixed* names so the
    # child's own logic resolves against its prefixed signals. Returning it
    # would inject every child internal name into the parent's namespace, where
    # `elaborate/1` rebinds signal_map from this return value before elaborating
    # the parent's own logic and FSMs. A parent signal sharing a name with any
    # instance's internal signal would then silently resolve to the child's
    # signal instead of its own — wrong hardware with no diagnostic, because it
    # only trips the multiple-driver check when the parent also writes the name.
    #
    # Merging the other way round makes the parent's own declarations win, while
    # still letting non-colliding child names through for connection handling.
    outward_signal_map = Map.merge(merged_signal_map, signal_map)

    {design, outward_signal_map, instance_map}
  end

  defp get_instances(module) do
    if (Code.ensure_loaded?(module) and function_exported?(module, :__hw_instances__, 0)) do
      module.__hw_instances__()
    else
      []
    end
  end

  defp create_prefixed_signals(design, inst_name, child_signal_map, parent_signal_map, port_map) do
    Enum.reduce(child_signal_map, {design, %{}}, fn {sig_name, %Signal{} = sig}, {d, prefixed_map} ->
      prefixed_name = :"#{inst_name}_#{sig_name}"

      case sig.direction do
        :input ->
          case Keyword.get(port_map, sig_name) do
            nil ->
              prefixed_sig = %{sig | name: prefixed_name, direction: :internal}
              d = Design.add_signal(d, prefixed_sig)
              {d, Map.put(prefixed_map, sig_name, prefixed_sig)}
            connected_to when is_atom(connected_to) ->
              case Map.get(parent_signal_map, connected_to) do
                nil ->
                  # FIX: parent signal not yet in signal_map (e.g. top-level input ports
                  # like clk_25mhz that are registered as ports but not in the internal
                  # signal_map). Synthesize a signal with the parent's name directly so
                  # the blackbox port connection resolves to the correct wire rather than
                  # a floating prefixed internal wire (e.g. pll_clk_in with no driver).
                  parent_sig = %{sig | name: connected_to, direction: :internal}
                  {d, Map.put(prefixed_map, sig_name, parent_sig)}
                parent_sig ->
                  {d, Map.put(prefixed_map, sig_name, parent_sig)}
              end
            _constant ->
              prefixed_sig = %{sig | name: prefixed_name, direction: :internal}
              d = Design.add_signal(d, prefixed_sig)
              {d, Map.put(prefixed_map, sig_name, prefixed_sig)}
          end

        :output ->
          # If this output port is mapped to a parent signal, resolve to that
          # instead of creating a new prefixed internal signal.
          case Keyword.get(port_map, sig_name) do
            nil ->
              prefixed_sig = %{sig | name: prefixed_name, direction: :internal}
              d = Design.add_signal(d, prefixed_sig)
              {d, Map.put(prefixed_map, sig_name, prefixed_sig)}
            connected_to when is_atom(connected_to) ->
              case Map.get(parent_signal_map, connected_to) do
                nil ->
                  prefixed_sig = %{sig | name: prefixed_name, direction: :internal}
                  d = Design.add_signal(d, prefixed_sig)
                  {d, Map.put(prefixed_map, sig_name, prefixed_sig)}
                parent_sig ->
                  {d, Map.put(prefixed_map, sig_name, parent_sig)}
              end
            _ ->
              prefixed_sig = %{sig | name: prefixed_name, direction: :internal}
              d = Design.add_signal(d, prefixed_sig)
              {d, Map.put(prefixed_map, sig_name, prefixed_sig)}
          end

        :internal ->
          prefixed_sig = %{sig | name: prefixed_name}
          d = Design.add_signal(d, prefixed_sig)
          {d, Map.put(prefixed_map, sig_name, prefixed_sig)}

        :inout ->
          # Inout ports: connect through to parent signal if mapped, else create internal
          case Keyword.get(port_map, sig_name) do
            nil ->
              prefixed_sig = %{sig | name: prefixed_name, direction: :inout}
              d = Design.add_signal(d, prefixed_sig)
              {d, Map.put(prefixed_map, sig_name, prefixed_sig)}
            connected_to when is_atom(connected_to) ->
              parent_sig = Map.get(parent_signal_map, connected_to)
              if parent_sig do
                {d, Map.put(prefixed_map, sig_name, parent_sig)}
              else
                prefixed_sig = %{sig | name: prefixed_name, direction: :inout}
                d = Design.add_signal(d, prefixed_sig)
                {d, Map.put(prefixed_map, sig_name, prefixed_sig)}
              end
            _ ->
              prefixed_sig = %{sig | name: prefixed_name, direction: :inout}
              d = Design.add_signal(d, prefixed_sig)
              {d, Map.put(prefixed_map, sig_name, prefixed_sig)}
          end
      end
    end)
  end

  defp map_child_clocks(child_clock_map, port_map, parent_clock_map) do
    for {child_clk_name, child_clk} <- child_clock_map, into: %{} do
      case Keyword.get(port_map, child_clk_name) do
        nil ->
          {child_clk_name, child_clk}
        parent_clk_name when is_atom(parent_clk_name) ->
          case Map.get(parent_clock_map, parent_clk_name) do
            nil ->
              # Parent name not in clock map — it's a wire (e.g. PLL output).
              # Synthesize a clock entry using the child's edge and the parent's name
              # so the validator sees a registered clock for this domain.
              synthetic_clk = %Hw.IR.Types.Clock{
                name: parent_clk_name,
                edge: child_clk.edge
              }
              {child_clk_name, synthetic_clk}
            parent_clk ->
              # Preserve reset_style: :none from child — it's a deliberate
              # override (e.g. ResetSync) that must survive clock mapping.
              merged_clk = if Map.get(child_clk, :reset_style) == :none do
                %{parent_clk | reset_style: :none, reset_signal: nil}
              else
                parent_clk
              end
              {child_clk_name, merged_clk}
          end
        _ ->
          {child_clk_name, child_clk}
      end
    end
  end

  defp elaborate_child_instances(design, child_instances, parent_inst_name, clock_map, signal_map, logic_elaborator, parent_param_map) do
    Enum.reduce(child_instances, {design, signal_map, %{}}, fn inst, {d, sig_map, inst_map} ->
      prefixed_inst = %{inst | name: :"#{parent_inst_name}_#{inst.name}"}
      elaborate_instance(d, prefixed_inst, clock_map, sig_map, inst_map, logic_elaborator, parent_param_map)
    end)
  end

  # Resolve one instance parameter value against the *enclosing* module's params.
  #
  # A bare uppercase name in an instance option is parsed by Elixir as an alias,
  # so `TQ_CLOCKS: TQ_CLOCKS` reaches us as the atom :"Elixir.TQ_CLOCKS". That is
  # the same "uppercase means parameter" convention the `pipeline` macro relies
  # on for auto-balance, applied one level out. Demangle it and look it up.
  #
  # Anything else passes through untouched, so integer literals and any existing
  # instance option behave exactly as before.
  defp resolve_instance_param(value, parent_param_map, inst_name, param_name) when is_atom(value) do
    case Atom.to_string(value) do
      "Elixir." <> bare ->
        if String.contains?(bare, ".") do
          # Multi-segment alias: a module name, not a parameter reference.
          value
        else
          name = String.to_atom(bare)

          if Map.has_key?(parent_param_map, name) do
            Hw.Compile.Elaborate.resolve_param_pub(name, parent_param_map)
          else
            declared =
              parent_param_map |> Map.keys() |> Enum.sort() |> Enum.map_join(", ", &to_string/1)

            raise Hw.Compile.Elaborate.ElabError,
              message:
                "instance #{inspect(inst_name)} forwards #{param_name}: #{bare}, but the " <>
                  "enclosing module declares no parameter #{bare}. Declared: " <>
                  if(declared == "", do: "(none)", else: declared),
              context: {inst_name, param_name}
          end
        end

      _ ->
        value
    end
  end

  defp resolve_instance_param(value, _parent_param_map, _inst_name, _param_name), do: value

  defp create_port_connections(design, _inst_name, child_signal_map, port_map, parent_signal_map, prefixed_signal_map) do
    Enum.reduce(port_map, design, fn {child_port, connection}, d ->
      child_sig = Map.get(child_signal_map, child_port)
      prefixed_sig = Map.get(prefixed_signal_map, child_port)

      cond do
        child_sig == nil ->
          d

        child_sig.direction == :output ->
          # Output port: child drives parent wire
          # Create assign: parent_wire <= prefixed_child_output
          if is_atom(connection) do
            parent_sig = Map.get(parent_signal_map, connection)
            if parent_sig && prefixed_sig && prefixed_sig.name != parent_sig.name do
              assign = %Ops.Assign{output: parent_sig, input: prefixed_sig}
              Design.add_op(d, assign)
            else
              d
            end
          else
            d
          end

        child_sig.direction != :input ->
          d

        is_integer(connection) ->
          const = %Const{value: connection, width: child_sig.width, signed: child_sig.signed}
          assign = %Ops.Assign{output: prefixed_sig, input: const}
          Design.add_op(d, assign)

        is_atom(connection) ->
          parent_sig = Map.get(parent_signal_map, connection)
          if parent_sig && prefixed_sig && prefixed_sig.name != parent_sig.name do
            assign = %Ops.Assign{output: prefixed_sig, input: parent_sig}
            Design.add_op(d, assign)
          else
            d
          end

        true ->
          d
      end
    end)
  end

  defp build_clock_map(clocks) do
    alias Hw.IR.Types.Clock
    for clk <- clocks, into: %{} do
      {clk.name, %Clock{
        name:         clk.name,
        edge:         clk.edge,
        domain:       Map.get(clk, :domain, clk.name),
        reset_signal: Map.get(clk, :reset),
        reset_style:  Map.get(clk, :reset_style, :sync)
      }}
    end
  end

  # Widths are resolved against the child's own parameters here, mirroring what
  # the top-level `build_signal_map/2` does. Without this a child that sizes a
  # signal from one of its parameters (`wire :r, WIDTH`, `clog2(DEPTH) + 1`)
  # reaches the design with an unresolved parameter expression as its width.
  defp build_signal_map(signals, param_map) do
    for sig <- signals, into: %{} do
      signal = case sig do
        %Signal{} = s ->
          %Signal{s | width: Hw.Compile.Elaborate.resolve_param_pub(s.width, param_map)}

        %{name: name, width: width} ->
          %Signal{
            name:         name,
            width:        Hw.Compile.Elaborate.resolve_param_pub(width, param_map),
            signed:       Map.get(sig, :signed, :unsigned),
            direction:    Map.get(sig, :direction, :internal),
            init:         Map.get(sig, :init),
            clock_domain: Map.get(sig, :clock_domain),
            sense:        Map.get(sig, :sense, :high),
            endian:       Map.get(sig, :endian),
            persist:      Map.get(sig, :persist, :full)
          }
      end
      {signal.name, signal}
    end
  end

  # --- Connection Elaboration ---

  @doc """
  Elaborate interface connections between modules.
  """
  def elaborate_connections(design, connections, interfaces, signal_map, instance_map) do
    Enum.reduce(connections, design, fn conn, d ->
      elaborate_connection(d, conn, interfaces, signal_map, instance_map)
    end)
  end

  defp elaborate_connection(design, conn, interfaces, signal_map, instance_map) do
    %{
      source_instance: src_inst,
      source_interface: src_if,
      sink_instance: sink_inst,
      sink_interface: sink_if
    } = conn

    src_interface_def = find_interface_def(src_inst, src_if, interfaces, instance_map)
    _sink_interface_def = find_interface_def(sink_inst, sink_if, interfaces, instance_map)

    src_if_signals = src_interface_def.module.__hw_interface_signals__()

    Enum.reduce(src_if_signals, design, fn if_sig, d ->
      src_sig_name = build_interface_signal_name(src_inst, src_if, if_sig.name)
      sink_sig_name = build_interface_signal_name(sink_inst, sink_if, if_sig.name)

      src_signal = find_signal(src_sig_name, src_inst, signal_map, instance_map)
      sink_signal = find_signal(sink_sig_name, sink_inst, signal_map, instance_map)

      if src_signal && sink_signal do
        {driver, driven} = if if_sig.flip do
          {sink_signal, src_signal}
        else
          {src_signal, sink_signal}
        end

        if driver.name != driven.name do
          assign = %Ops.Assign{output: driven, input: driver}
          Design.add_op(d, assign)
        else
          d
        end
      else
        d
      end
    end)
  end

  defp find_interface_def(nil, if_name, interfaces, _instance_map) do
    Enum.find(interfaces, & &1.name == if_name) ||
      raise Hw.Compile.Elaborate.ElabError, message: "Unknown interface: #{if_name}"
  end

  defp find_interface_def(inst_name, if_name, _interfaces, instance_map) do
    case Map.get(instance_map, inst_name) do
      nil -> raise Hw.Compile.Elaborate.ElabError, message: "Unknown instance: #{inst_name}"
      _inst_signals ->
        raise Hw.Compile.Elaborate.ElabError, message: "Instance interface lookup not yet implemented: #{inst_name}.#{if_name}"
    end
  end

  defp build_interface_signal_name(nil, if_name, sig_name) do
    :"#{if_name}_#{sig_name}"
  end

  defp find_signal(sig_name, nil, signal_map, _instance_map) do
    Map.get(signal_map, sig_name)
  end
end
