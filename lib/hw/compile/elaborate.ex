defmodule Hw.Compile.Elaborate do
  @moduledoc """
  Elaboration: Transform DSL module attributes into hardware IR.

  This module takes the parsed AST fragments stored in module attributes
  and builds a proper `Hw.IR.Design` struct.

  ## Process

  1. Build Clock objects from @hw_clocks
  2. Build Signal objects from @hw_signals
  3. Process logic blocks, creating Ops for each assignment
  4. Resolve signal references
  5. Build mux trees for conditional assignments
  """

  alias Hw.IR.{Design, Ops}
  alias Hw.IR.Types.{Signal, Clock, Const}
  alias Hw.Compile.Elaborate.{Expr, Sequential, Instances}

  defmodule ElabError do
    defexception [:message, :context]
  end

  @doc """
  Elaborate a component module into IR.
  """
  def elaborate(module) when is_atom(module) do
    # Generated signal names must restart from zero for every elaboration, or
    # the same design emits different Verilog on each run and no seed is
    # reproducible. See Hw.Compile.Elaborate.Gensym.
    Hw.Compile.Elaborate.Gensym.reset()

    name = module.__hw_design_name__()
    params = get_params(module)
    clocks = module.__hw_clocks__()
    signals = module.__hw_signals__()
    logic = module.__hw_logic__()
    instances = get_instances(module)
    connections = get_connections(module)
    interfaces = get_interfaces(module)
    memories = get_memories(module)
    blackboxes = get_blackboxes(module)
    tristates = get_tristates(module)

    # Build defhw registry: name -> %{params, body, source_location}
    # sim_only defhws (containing `on` blocks) are excluded from hardware
    # elaboration — they are only used by the simulation interpreter.
    defhws    = get_defhws(module)
    defhw_map = defhws
      |> Enum.reject(fn d -> Map.get(d, :sim_only, false) end)
      |> Map.new(fn d -> {d.name, d} end)

    # Build param map (name -> Param struct with default as value)
    param_map = build_param_map(params)

    # Build lookup maps (resolve param refs in widths)
    clock_map  = build_clock_map(clocks)
    signal_map = build_signal_map(signals, param_map)
    memory_map = build_memory_map(memories, param_map)

    # Inject resolved param values as %Const{} so build_expr can fold param
    # arithmetic (e.g. CLK_FREQ / BAUD_RATE - 1) into concrete constants.
    # Applied after Design.add_signal so Const structs don't get added as signals.
    param_const_map = param_map
      |> Enum.flat_map(fn {name, param} ->
        case param.value do
          v when is_integer(v) ->
            [{name, %Hw.IR.Types.Const{value: v, width: 32, signed: :unsigned}}]
          _ -> []
        end
      end)
      |> Map.new()

    # Resolve `:infer`-width signals from their single driver (in dataflow
    # order) before anything consumes concrete widths. No-op when the design
    # declares no `:infer` signals.
    signal_map = Hw.Compile.InferWidths.resolve(signal_map, param_const_map, logic, memory_map)

    # Start building the design
    design = Design.new(name)

    # Add params
    design = Enum.reduce(param_map, design, fn {_, param}, d ->
      Design.add_param(d, param)
    end)

    # Add clocks
    design = Enum.reduce(clock_map, design, fn {_, clock}, d ->
      Design.add_clock(d, clock)
    end)

    # Add signals
    design = Enum.reduce(signal_map, design, fn {_, signal}, d ->
      Design.add_signal(d, signal)
    end)

    # Now merge param consts into signal_map for expression building
    signal_map = Map.merge(signal_map, param_const_map)

    # Add memories
    design = Enum.reduce(memory_map, design, fn {_, mem}, d ->
      Design.add_op(d, mem)
    end)

    # Add blackboxes
    design = elaborate_blackboxes(design, blackboxes, signal_map)

    # Add tristates
    design = elaborate_tristates(design, tristates, signal_map)

    # Process instances. Each child component elaborates its own logic blocks
    # using its own defhw_map (built inside elaborate_instance). The outer
    # logic_elaborator is only used for the top-level module's own logic.
    logic_elaborator = fn d, lb, cm, sm, im, mm, cwm ->
      elaborate_logic_block(d, lb, cm, sm, im, mm, defhw_map, cwm)
    end
    {design, signal_map, instance_map} = Instances.elaborate_instances(design, instances, clock_map, signal_map, logic_elaborator, param_map)

    # Process interface connections
    design = Instances.elaborate_connections(design, connections, interfaces, signal_map, instance_map)

    # Build a map of signal -> constant integer for wires that are always
    # assigned a literal (e.g. `zero = 0`, `w2_0 = 0`, `one = 1`).
    # Used by extract_reset to resolve one level of signal indirection so that
    # reset branches using these aliases (e.g. `dev_state = w2_0`) produce
    # correct reset_value constants in the IR.
    const_wire_map = build_const_wire_map(logic)

    # Process logic blocks
    design = Enum.reduce(logic, design, fn logic_block, d ->
      elaborate_logic_block(d, logic_block, clock_map, signal_map, instance_map, memory_map, defhw_map, const_wire_map)
    end)

    # Process FSMs
    fsms = get_fsms(module)
    design = Enum.reduce(fsms, design, fn fsm, d ->
      elaborate_fsm(d, fsm, clock_map, signal_map, instance_map, memory_map, defhw_map, const_wire_map)
    end)

    Design.finalize(design)
  end

  # --- Module Attribute Getters ---

  defp get_instances(module) do
    if (Code.ensure_loaded?(module) and function_exported?(module, :__hw_instances__, 0)), do: module.__hw_instances__(), else: []
  end

  defp get_connections(module) do
    if (Code.ensure_loaded?(module) and function_exported?(module, :__hw_connections__, 0)), do: module.__hw_connections__(), else: []
  end

  defp get_interfaces(module) do
    if (Code.ensure_loaded?(module) and function_exported?(module, :__hw_interfaces__, 0)), do: module.__hw_interfaces__(), else: []
  end

  defp get_memories(module) do
    if (Code.ensure_loaded?(module) and function_exported?(module, :__hw_memories__, 0)), do: module.__hw_memories__(), else: []
  end

  defp get_blackboxes(module) do
    if (Code.ensure_loaded?(module) and function_exported?(module, :__hw_blackboxes__, 0)), do: module.__hw_blackboxes__(), else: []
  end

  defp get_tristates(module) do
    if (Code.ensure_loaded?(module) and function_exported?(module, :__hw_tristates__, 0)), do: module.__hw_tristates__(), else: []
  end

  defp get_fsms(module) do
    if (Code.ensure_loaded?(module) and function_exported?(module, :__hw_fsm__, 0)), do: module.__hw_fsm__(), else: []
  end

  defp get_defhws(module) do
    if (Code.ensure_loaded?(module) and function_exported?(module, :__hw_defhw__, 0)), do: module.__hw_defhw__(), else: []
  end

  # Scan all logic blocks for flat `signal = const` assignments — these are
  # constant alias wires. Returns a map of signal_name -> integer value.
  # Only captures direct const assignments; ignores conditionals.
  defp build_const_wire_map(logic_blocks) do
    Enum.reduce(logic_blocks, %{}, fn block, acc ->
      scan_const_assigns(block.body, acc)
    end)
  end

  defp scan_const_assigns(statements, acc) when is_list(statements) do
    Enum.reduce(statements, acc, fn stmt, a ->
      case stmt do
        %{type: :assign, target: name, value: {:const, n}} ->
          Map.put(a, name, n)
        _ ->
          a
      end
    end)
  end
  defp scan_const_assigns(_, acc), do: acc

  defp get_params(module) do
    if (Code.ensure_loaded?(module) and function_exported?(module, :__hw_params__, 0)), do: module.__hw_params__(), else: []
  end

  # --- Map Building ---

  alias Hw.IR.Types.Param

  def build_param_map_pub(params), do: build_param_map(params)
  def inline_defhw_calls_pub(body, defhw_map), do: inline_defhw_calls(body, defhw_map)
  def substitute_defhw_expr_pub(expr, bindings), do: substitute_defhw_expr(expr, bindings)
  defp build_param_map(params) do
    for p <- params, into: %{} do
      # `case`, not `Map.get(p, :value) || p.default` -- but for a narrower reason
      # than it looks. **In Elixir `0` is truthy**, so the obvious falsy-zero
      # hazard does not exist: `PREG: 0` resolved correctly under `||` too. That
      # was checked by reverting this line and re-running
      # `test/xilinx_primitives_test.exs`, which still passed 17/17.
      #
      # What `||` did get wrong is `false`, the only falsy value that can reach
      # here: `STARTUP_WAIT: false` against `default: "TRUE"` silently resolved to
      # `"TRUE"`. Narrow, because Verilog parameters are numbers and strings
      # rather than booleans -- but silent, and an override discarded without a
      # word is the failure mode this repo keeps paying for.
      resolved_value =
        case Map.get(p, :value) do
          nil -> p.default
          value -> value
        end
      param = %Param{
        name: p.name,
        default: p.default,
        value: resolved_value
      }
      {p.name, param}
    end
  end

  defp build_clock_map(clocks) do
    for clk <- clocks, into: %{} do
      {clk.name, %Clock{
        name:         clk.name,
        edge:         clk.edge,
        freq_mhz:     Map.get(clk, :freq_mhz),
        # Structural type fields from DSL declaration
        domain:       Map.get(clk, :domain, clk.name),
        reset_signal: Map.get(clk, :reset),
        reset_style:  Map.get(clk, :reset_style, :sync)
      }}
    end
  end

  defp build_signal_map(signals, param_map) do
    for sig <- signals, into: %{} do
      width = resolve_param(sig.width, param_map)

      signal = case sig do
        %Signal{} = s -> %Signal{s | width: width}
        %{name: name} ->
          %Signal{
            name:         name,
            width:        width,
            signed:       Map.get(sig, :signed, :unsigned),
            direction:    Map.get(sig, :direction, :internal),
            init:         Map.get(sig, :init),
            # Structural type annotations — passed through if present
            clock_domain: Map.get(sig, :clock_domain),
            sense:        Map.get(sig, :sense, :high),
            endian:       Map.get(sig, :endian),
            persist:      Map.get(sig, :persist, :full)
          }
      end
      {signal.name, signal}
    end
  end

  defp build_memory_map(memories, param_map) do
    for mem <- memories, into: %{} do
      mem_op = %Ops.Mem{
        name: mem.name,
        width: resolve_param(mem.width, param_map),
        depth: resolve_param(mem.depth, param_map),
        init: mem[:init],
        sync_read: mem[:sync_read] || false
      }
      {mem.name, mem_op}
    end
  end

  # Resolve a value that might be a param reference or expression
  def resolve_param_pub(value, param_map), do: resolve_param(value, param_map)
  defp resolve_param(value, _param_map) when is_integer(value), do: value

  # `:infer` is a sentinel resolved later by Hw.Compile.InferWidths — pass it
  # through untouched instead of treating it as an unknown parameter name.
  defp resolve_param(:infer, _param_map), do: :infer

  defp resolve_param(name, param_map) when is_atom(name) do
    case Map.get(param_map, name) do
      nil -> raise ElabError, message: "Unknown parameter: #{name}", context: name
      %Param{value: nil} -> raise ElabError, message: "Parameter #{name} has no value", context: name
      %Param{value: v} -> v
    end
  end

  # Arithmetic expressions
  defp resolve_param({:+, a, b}, param_map) do
    resolve_param(a, param_map) + resolve_param(b, param_map)
  end

  defp resolve_param({:-, a, b}, param_map) do
    resolve_param(a, param_map) - resolve_param(b, param_map)
  end

  defp resolve_param({:*, a, b}, param_map) do
    resolve_param(a, param_map) * resolve_param(b, param_map)
  end

  defp resolve_param({:/, a, b}, param_map) do
    div(resolve_param(a, param_map), resolve_param(b, param_map))
  end

  defp resolve_param({:div, a, b}, param_map) do
    div(resolve_param(a, param_map), resolve_param(b, param_map))
  end

  # clog2 - ceiling of log base 2 (for address width calculation)
  defp resolve_param({:clog2, a}, param_map) do
    val = resolve_param(a, param_map)
    if val <= 1, do: 1, else: ceil(:math.log2(val)) |> trunc()
  end

  # Handle escaped tuples from Macro.escape (3-element tuple form)
  defp resolve_param({:{}, [], [op | args]}, param_map) when is_atom(op) do
    resolve_param(List.to_tuple([op | args]), param_map)
  end

  defp resolve_param(value, _param_map), do: value

  # --- Blackbox/Tristate Elaboration ---

  defp elaborate_blackboxes(design, blackboxes, signal_map) do
    Enum.reduce(blackboxes, design, fn bb, d ->
      ports = for {port_name, connection} <- bb.ports do
        case connection do
          n when is_integer(n) ->
            {port_name, %Const{value: n, width: 32, signed: :unsigned}}
          name when is_atom(name) ->
            {port_name, Map.get(signal_map, name, name)}
          other ->
            {port_name, other}
        end
      end

      blackbox_op = %Ops.Blackbox{
        name: bb.name,
        module: bb.module,
        params: bb.params,
        ports: ports,
        # attrs were being dropped here while the child-instance path in
        # Elaborate.Instances passed them through, so a `blackbox ..., attrs:`
        # on a component's own primitive silently emitted no attribute. That
        # matters: a Zynq PS7 needs (* keep *) to survive synthesis when
        # nothing is connected to it, and without it runtime PCAP programming
        # hangs the processor.
        attrs: Map.get(bb, :attrs, [])
      }

      Design.add_op(d, blackbox_op)
    end)
  end

  defp elaborate_tristates(design, tristates, signal_map) do
    Enum.reduce(tristates, design, fn ts, d ->
      tristate_op = %Ops.Tristate{
        io: Map.fetch!(signal_map, ts.io),
        output_value: Map.get(signal_map, ts.output),
        output_enable: Map.get(signal_map, ts.enable),
        input_value: Map.get(signal_map, ts.input)
      }

      Design.add_op(d, tristate_op)
    end)
  end

  # --- Logic Block Processing ---

  # Inline all :defhw_call statement nodes in a body by substituting
  # the named template with arguments bound to parameters.
  #
  # Inlining is a FIXPOINT, not a single pass. A defhw body may itself call
  # other defhws — including from inside an hdl_case branch, which is the
  # ordinary way to write a register-write dispatcher:
  #
  #     defhw commit_write() do
  #       hdl_case <<wr_index::4>> do
  #         <<2::4>> -> merge_scratch()
  #         <<3::4>> -> merge_ctrl()
  #       end
  #     end
  #
  # Substituting the template used to return the body verbatim, so those inner
  # calls survived as :defhw_call nodes. Nothing downstream matches that node:
  # find_all_assigned does not see it as an assignment, build_mux_tree never
  # visits it, and the emitter has no clause for it. The result was a component
  # that elaborated cleanly, synthesised cleanly, and dropped every write on
  # real hardware — the registers were declared, initialised and read, but
  # never assigned. Re-inlining the substituted body is what closes that hole;
  # assert_no_defhw_calls!/2 is the backstop that turns any future gap in this
  # traversal into a loud failure instead of a silent one.
  defp inline_defhw_calls(body, defhw_map), do: inline_defhw_calls(body, defhw_map, [])

  defp inline_defhw_calls(body, defhw_map, stack) when is_list(body) do
    Enum.flat_map(body, fn stmt -> inline_defhw_stmt(stmt, defhw_map, stack) end)
  end

  defp inline_defhw_stmt(%{type: :defhw_call, name: name, args: args}, defhw_map, stack) do
    check_defhw_cycle!(name, stack)

    case Map.get(defhw_map, name) do
      nil ->
        raise ElabError,
          message: "Unknown defhw: #{name}/#{length(args)}. " <>
                   "Check the defhw is declared in this component.",
          context: name
      %{params: params, body: template_body} ->
        if length(params) != length(args) do
          raise ElabError,
            message: "defhw #{name}/#{length(params)} called with #{length(args)} argument(s)",
            context: name
        end

        # Arguments are evaluated in the CALLER's scope, so any defhw call
        # inside an argument expression is inlined before binding.
        args = Enum.map(args, &inline_defhw_expr(&1, defhw_map, stack))
        bindings = Map.new(Enum.zip(params, args))

        template_body
        |> substitute_defhw_body(bindings)
        |> inline_defhw_calls(defhw_map, [name | stack])
    end
  end

  # Recursively inline defhw calls inside if/case branches
  defp inline_defhw_stmt(%{type: :if} = stmt, defhw_map, stack) do
    [%{stmt |
       condition: inline_defhw_expr(stmt.condition, defhw_map, stack),
       then_body: inline_defhw_calls(stmt.then_body, defhw_map, stack),
       else_body: stmt.else_body && inline_defhw_calls(stmt.else_body, defhw_map, stack)
    }]
  end

  defp inline_defhw_stmt(%{type: :case} = stmt, defhw_map, stack) do
    inlined_clauses = Enum.map(stmt.clauses, fn clause ->
      %{clause | body: inline_defhw_calls(clause.body, defhw_map, stack)}
    end)
    [%{stmt | clauses: inlined_clauses, expr: inline_defhw_expr(stmt.expr, defhw_map, stack)}]
  end

  defp inline_defhw_stmt(%{type: :assign} = stmt, defhw_map, stack) do
    [%{stmt | value: inline_defhw_expr(stmt.value, defhw_map, stack)}]
  end

  # A bare `foo(...)` written as the whole body of a defhw parses as a
  # :defhw_expr wrapping a call, not as a :defhw_call statement -- the DSL macro
  # cannot tell a statement-level delegation from an expression until it knows
  # what `foo` is. Unwrap it so statement-level delegation works:
  #
  #     defhw commit_write() do
  #       merge_scratch()          # <- lands here, not on the :defhw_call clause
  #     end
  #
  defp inline_defhw_stmt(%{type: :defhw_expr, value: %{defhw_call: name, args: args}}, defhw_map, stack) do
    inline_defhw_stmt(%{type: :defhw_call, name: name, args: args}, defhw_map, stack)
  end

  defp inline_defhw_stmt(%{type: :defhw_expr} = stmt, defhw_map, stack) do
    [%{stmt | value: inline_defhw_expr(stmt.value, defhw_map, stack)}]
  end

  defp inline_defhw_stmt(stmt, _defhw_map, _stack), do: [stmt]

  # A defhw that reaches itself has no fixpoint: hardware is finite, so there is
  # no base case to terminate on. Without this the elaborator loops forever and
  # the build simply hangs.
  defp check_defhw_cycle!(name, stack) do
    if name in stack do
      cycle = Enum.reverse([name | stack]) |> Enum.map_join(" -> ", &to_string/1)
      raise ElabError,
        message: "Recursive defhw: #{cycle}. " <>
                 "defhw is inlined at elaboration time, so it cannot call itself " <>
                 "directly or indirectly.",
        context: name
    end
  end

  # Backstop: no :defhw_call node may survive inlining.
  #
  # Every silent-drop bug in this area has the same shape — a statement node
  # whose nested bodies inline_defhw_stmt/3 does not traverse, so the calls
  # inside it are carried through untouched and then ignored by everything
  # downstream. Rather than trust the traversal to stay complete as node types
  # are added, walk the result and fail loudly. :on_condition subtrees are
  # skipped: they are simulation-only wait constructs, never elaborated to
  # hardware, and their bodies are interpreted with calls intact.
  defp assert_no_defhw_calls!(body, where) do
    case find_defhw_call(body) do
      nil -> body
      name ->
        raise ElabError,
          message: "defhw `#{name}` survived inlining in #{where}. " <>
                   "This is an elaborator bug: the call would be silently " <>
                   "dropped, producing hardware that reads correctly and " <>
                   "never updates. Please report the enclosing construct.",
          context: name
    end
  end

  defp find_defhw_call(%{type: :on_condition}), do: nil
  defp find_defhw_call(%{type: :defhw_call, name: name}), do: name
  defp find_defhw_call(%{defhw_call: name}), do: name
  defp find_defhw_call(%{} = node), do: node |> Map.values() |> find_defhw_call()
  defp find_defhw_call(list) when is_list(list), do: Enum.find_value(list, &find_defhw_call/1)
  defp find_defhw_call(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> find_defhw_call()
  defp find_defhw_call(_), do: nil

  # Inline defhw calls in expression position
  defp inline_defhw_expr(%{defhw_call: name, args: args}, defhw_map, stack) do
    check_defhw_cycle!(name, stack)
    args = Enum.map(args, &inline_defhw_expr(&1, defhw_map, stack))

    inlined = fn params, expr ->
      bindings = Map.new(Enum.zip(params, args))
      expr
      |> substitute_defhw_expr(bindings)
      |> inline_defhw_expr(defhw_map, [name | stack])
    end

    case Map.get(defhw_map, name) do
      nil ->
        raise ElabError,
          message: "Unknown defhw expression: #{name}/#{length(args)}",
          context: name
      %{params: params} when length(params) != length(args) ->
        raise ElabError,
          message: "defhw #{name}/#{length(params)} called with #{length(args)} argument(s)",
          context: name
      %{params: params, body: [%{type: :defhw_expr, value: expr}]} ->
        inlined.(params, expr)
      %{params: params, body: [%{type: :assign, value: expr}]} ->
        inlined.(params, expr)
      %{params: params, body: body} when length(body) == 1 ->
        inlined.(params, List.first(body))
      _ ->
        raise ElabError,
          message: "defhw #{name} used in expression position but has multiple statements",
          context: name
    end
  end

  # Structural clauses come FIRST. {:concat, elems} and {:slice, b, hi, lo} both
  # have an atom head, so the generic {op, a} / {op, a, b} clauses below would
  # otherwise swallow them and recurse into a list or an arity they do not
  # understand — leaving a defhw call inside a concat or a slice un-inlined.
  defp inline_defhw_expr({:concat, elems}, defhw_map, stack) do
    {:concat, Enum.map(elems, &inline_defhw_expr(&1, defhw_map, stack))}
  end

  defp inline_defhw_expr({:slice, base, hi, lo}, defhw_map, stack) do
    {:slice, inline_defhw_expr(base, defhw_map, stack),
             inline_defhw_expr(hi, defhw_map, stack),
             inline_defhw_expr(lo, defhw_map, stack)}
  end

  defp inline_defhw_expr({:ternary, c, t, e}, defhw_map, stack) do
    {:ternary, inline_defhw_expr(c, defhw_map, stack),
               inline_defhw_expr(t, defhw_map, stack),
               inline_defhw_expr(e, defhw_map, stack)}
  end

  defp inline_defhw_expr({op, a, b}, defhw_map, stack) when is_atom(op) do
    {op, inline_defhw_expr(a, defhw_map, stack), inline_defhw_expr(b, defhw_map, stack)}
  end

  defp inline_defhw_expr({op, a}, defhw_map, stack) when is_atom(op) do
    {op, inline_defhw_expr(a, defhw_map, stack)}
  end

  defp inline_defhw_expr(expr, _defhw_map, _stack), do: expr

  # Substitute param names with argument expressions throughout a body
  defp substitute_defhw_body(body, bindings) when is_list(body) do
    Enum.map(body, &substitute_defhw_stmt(&1, bindings))
  end

  defp substitute_defhw_stmt(%{type: :assign} = stmt, bindings) do
    %{stmt | value: substitute_defhw_expr(stmt.value, bindings)}
  end

  defp substitute_defhw_stmt(%{type: :if} = stmt, bindings) do
    %{stmt |
      condition: substitute_defhw_expr(stmt.condition, bindings),
      then_body: substitute_defhw_body(stmt.then_body, bindings),
      else_body: stmt.else_body && substitute_defhw_body(stmt.else_body, bindings)
    }
  end

  defp substitute_defhw_stmt(%{type: :case} = stmt, bindings) do
    inlined_clauses = Enum.map(stmt.clauses, fn clause ->
      %{clause | body: substitute_defhw_body(clause.body, bindings)}
    end)
    %{stmt |
      expr:    substitute_defhw_expr(stmt.expr, bindings),
      clauses: inlined_clauses
    }
  end

  # A nested call's ARGUMENTS live in the enclosing template's scope, so they
  # must be substituted here even though the call itself is inlined later.
  defp substitute_defhw_stmt(%{type: :defhw_call} = stmt, bindings) do
    %{stmt | args: Enum.map(stmt.args, &substitute_defhw_expr(&1, bindings))}
  end

  defp substitute_defhw_stmt(%{type: :defhw_expr} = stmt, bindings) do
    %{stmt | value: substitute_defhw_expr(stmt.value, bindings)}
  end

  defp substitute_defhw_stmt(stmt, _bindings), do: stmt

  defp substitute_defhw_expr({:signal, name}, bindings) do
    Map.get(bindings, name, {:signal, name})
  end

  defp substitute_defhw_expr({:concat, elems}, bindings) do
    {:concat, Enum.map(elems, &substitute_defhw_expr(&1, bindings))}
  end

  defp substitute_defhw_expr({:slice, base, hi, lo}, bindings) do
    {:slice, substitute_defhw_expr(base, bindings),
             substitute_defhw_expr(hi, bindings),
             substitute_defhw_expr(lo, bindings)}
  end

  defp substitute_defhw_expr({:ternary, c, t, e}, bindings) do
    {:ternary, substitute_defhw_expr(c, bindings),
               substitute_defhw_expr(t, bindings),
               substitute_defhw_expr(e, bindings)}
  end

  defp substitute_defhw_expr({op, a, b}, bindings) when is_atom(op) do
    {op, substitute_defhw_expr(a, bindings), substitute_defhw_expr(b, bindings)}
  end

  defp substitute_defhw_expr({op, a}, bindings) when is_atom(op) do
    {op, substitute_defhw_expr(a, bindings)}
  end

  defp substitute_defhw_expr(%{defhw_call: _} = call, bindings) do
    %{call | args: Enum.map(call.args, &substitute_defhw_expr(&1, bindings))}
  end

  defp substitute_defhw_expr(expr, _bindings), do: expr

  def elaborate_logic_block(design, %{type: :sequential, clock: clock_name, body: body} = logic_block, clock_map, signal_map, instance_map, memory_map, defhw_map, const_wire_map) do
    body = body |> inline_defhw_calls(defhw_map) |> assert_no_defhw_calls!("sequential block on #{clock_name}")
    clock = Map.fetch!(clock_map, clock_name)
    async_reset = Map.get(logic_block, :async_reset)

    # Find all signals assigned in this block
    {signal_targets, mem_writes} = Sequential.find_all_assigned(body)

    # Process signal assignments as registers
    design = Enum.reduce(signal_targets, design, fn target_name, d ->
      output_signal = case Map.fetch(signal_map, target_name) do
        {:ok, sig} -> sig
        :error -> raise ElabError, message: "Unknown signal: #{target_name}", context: body
      end

      # Build the mux tree for this signal's next value
      {next_value, d2} = Sequential.build_mux_tree(body, target_name, signal_map, instance_map, memory_map, d)

      # Match constant width to output signal
      next_value = Expr.match_value_to_output(next_value, output_signal)

      # Extract reset value — suppressed for :none style domains so the
      # register gets no reset gating, relying only on FF init values.
      reset_value = case Map.get(clock, :reset_style, :sync) do
        :none -> nil
        _     ->
          {rv, _} = Sequential.extract_reset(body, target_name, signal_map, const_wire_map)
          rv
      end

      # Create the register
      reg = %Ops.Reg{
        output: output_signal,
        input: next_value,
        clock: clock,
        reset_value: reset_value,
        enable: nil,
        async_reset: async_reset
      }

      Design.add_op(d2, reg)
    end)

    # Process memory writes
    Enum.reduce(mem_writes, design, fn {mem_name, addr_expr, value_expr, enable_expr}, d ->
      {addr_val, d2} = Expr.build_expr(addr_expr, signal_map, instance_map, memory_map, d)
      {data_val, d3} = Expr.build_expr(value_expr, signal_map, instance_map, memory_map, d2)
      {enable_val, d4} = Expr.build_expr(enable_expr, signal_map, instance_map, memory_map, d3)

      # Resolve the memory's ACTUAL op name through memory_map. `mem_name` is the
      # source-level name (e.g. :trace); when the owning component is instantiated
      # as a submodule its Mem op is prefixed (e.g. :cycle_trace_trace). Emitting
      # the raw name here left the MemWrite pointing at a nonexistent memory, so
      # the write was silently dropped for any memory inside an instance.
      resolved_mem = case Map.get(memory_map, mem_name) do
        %Ops.Mem{name: actual} -> actual
        _ -> mem_name
      end

      mem_write = %Ops.MemWrite{
        memory: resolved_mem,
        addr: addr_val,
        data: data_val,
        enable: enable_val,
        clock: clock
      }

      Design.add_op(d4, mem_write)
    end)
  end

  def elaborate_logic_block(design, %{type: :combinational, body: body}, _clock_map, signal_map, instance_map, memory_map, defhw_map, _const_wire_map) do
    body = body |> inline_defhw_calls(defhw_map) |> assert_no_defhw_calls!("comb block")
    # Find ALL signals assigned anywhere in the body — including inside
    # if/case/hdl_case blocks. find_all_assignments only finds flat assigns
    # and would miss case arms, so we use find_all_assigned instead.
    {signal_targets, _mem_writes} = Sequential.find_all_assigned(body)

    Enum.reduce(signal_targets, design, fn target_name, d ->
      output_signal = case Map.fetch(signal_map, target_name) do
        {:ok, sig} -> sig
        :error -> raise ElabError, message: "Unknown signal in comb block: #{target_name}", context: body
      end

      # Build mux tree — handles flat assigns, if/else, and case statements.
      # comb: true prevents using the signal's own value as the case default,
      # which would create a combinational loop in the simulator.
      {value, d2} = Sequential.build_mux_tree(body, target_name, signal_map, instance_map, memory_map, d, comb: true)

      if value == nil do
        raise ElabError,
          message: "Signal `#{target_name}` is listed as assigned in comb block but build_mux_tree returned nil — possible parser/elaborator mismatch",
          context: target_name
      end

      value = Expr.match_value_to_output(value, output_signal)

      assign = %Ops.Assign{
        output: output_signal,
        input: value
      }

      Design.add_op(d2, assign)
    end)
  end

  # --- FSM Elaboration ---

  def elaborate_fsm(design, fsm, clock_map, signal_map, instance_map, memory_map, defhw_map, const_wire_map) do
    %{
      name: state_name,
      clock: clock_name,
      init: init_state,
      encoding: encoding,
      states: states,
      defaults: defaults,
      case_body: case_body
    } = fsm

    reset_signal = Map.get(fsm, :reset, nil)

    # Calculate state encoding
    num_states = length(states)
    state_width = case encoding do
      :binary -> max(1, ceil(:math.log2(num_states)))
      :onehot -> num_states
      :gray -> max(1, ceil(:math.log2(num_states)))
    end

    # Build state value map (atom -> integer)
    state_values = build_state_encoding(states, encoding)
    init_value = Map.fetch!(state_values, init_state)

    # The state signal may already exist in signal_map if the fsm macro
    # pre-registered it via @hw_signals (which gets prefixed during instance
    # elaboration). Use the existing signal if present, otherwise create it.
    {state_signal, design} = case Map.fetch(signal_map, state_name) do
      {:ok, existing} ->
        {existing, design}
      :error ->
        sig = %Signal{
          name: state_name,
          width: state_width,
          signed: :unsigned,
          direction: :internal
        }
        {sig, Design.add_signal(design, sig)}
    end

    # Add localparams for each state
    design = Enum.reduce(state_values, design, fn {state_atom, value}, d ->
      param_name = state_atom |> Atom.to_string() |> String.upcase() |> String.to_atom()
      localparam = %Hw.IR.Types.Localparam{
        name: param_name,
        value: value,
        width: state_width
      }
      Design.add_localparam(d, localparam)
    end)

    # Add state signal to signal_map for elaboration
    signal_map = Map.put(signal_map, state_name, state_signal)

    # Get clock (validated but not directly used - clock_name passed to logic block)
    _clock = Map.fetch!(clock_map, clock_name)

    # Convert case_body with state values
    converted_case = convert_fsm_case(case_body, state_values)

    # Combine defaults with case body.
    #
    # Inline defhw calls HERE, before find_all_assigned/1 below collects the
    # signals that need reset assignments. elaborate_logic_block/8 inlines
    # again (harmlessly — inlining is idempotent once no calls remain), but by
    # then it is too late: a register assigned only from inside a defhw would
    # not appear in assigned_signals, so the reset branch would omit it and the
    # register would HOLD across reset instead of returning to its init: value.
    # On a 7-series that also splits the control set, since some flops in the
    # domain end up SR-used and some do not.
    fsm_body = inline_defhw_calls(defaults ++ [converted_case], defhw_map)

    # If reset: is specified, wrap the entire FSM body in a priority reset mux.
    # The reset branch sets the state register to init_state and all other
    # signals assigned in the FSM to their init: values from signal_map.
    # This produces Reg ops with reset_value populated, which the Verilog
    # emitter maps to synchronous reset inputs on FFs — zero extra LUT cost.
    full_body = case reset_signal do
      nil ->
        fsm_body

      rst_name ->
        # Collect all signals assigned anywhere in the FSM body
        {assigned_signals, _} = Hw.Compile.Elaborate.Sequential.find_all_assigned(fsm_body)

        # Build reset assignments: state -> init encoding, others -> init value
        reset_assignments = Enum.flat_map(assigned_signals, fn sig_name ->
          reset_val = if sig_name == state_name do
            init_value
          else
            case Map.get(signal_map, sig_name) do
              %Signal{init: v} when not is_nil(v) -> v
              _ -> 0
            end
          end
          [%{type: :assign, target: sig_name, value: {:const, reset_val}}]
        end)

        [%{
          type: :if,
          condition: {:signal, rst_name},
          then_body: reset_assignments,
          else_body: fsm_body
        }]
    end

    # Now process as a regular sequential block
    elaborate_logic_block(design, %{
      type: :sequential,
      clock: clock_name,
      async_reset: nil,
      body: full_body
    }, clock_map, signal_map, instance_map, memory_map, defhw_map, const_wire_map)
  end

  # Build state encoding map
  defp build_state_encoding(states, :binary) do
    states
    |> Enum.with_index()
    |> Map.new()
  end

  defp build_state_encoding(states, :onehot) do
    states
    |> Enum.with_index()
    |> Enum.map(fn {state, idx} -> {state, Bitwise.bsl(1, idx)} end)
    |> Map.new()
  end

  defp build_state_encoding(states, :gray) do
    states
    |> Enum.with_index()
    |> Enum.map(fn {state, idx} -> {state, Bitwise.bxor(idx, Bitwise.bsr(idx, 1))} end)
    |> Map.new()
  end

  # Convert FSM case patterns from {:state, atom} to {:const, value}
  defp convert_fsm_case(%{type: :case, expr: expr, clauses: clauses}, state_values) do
    %{
      type: :case,
      expr: expr,
      clauses: Enum.map(clauses, &convert_fsm_clause(&1, state_values))
    }
  end

  defp convert_fsm_clause(%{pattern: {:state, state_atom}, body: body}, state_values) do
    value = Map.fetch!(state_values, state_atom)
    %{
      pattern: {:const, value},
      body: convert_fsm_body(body, state_values)
    }
  end

  # Convert state references in body
  defp convert_fsm_body(stmts, state_values) when is_list(stmts) do
    Enum.map(stmts, &convert_fsm_stmt(&1, state_values))
  end

  defp convert_fsm_stmt(%{type: :assign, target: target, value: {:state, state_atom}}, state_values) do
    value = Map.fetch!(state_values, state_atom)
    %{type: :assign, target: target, value: {:const, value}}
  end

  defp convert_fsm_stmt(%{type: :if, condition: cond, then_body: then_b, else_body: else_b}, state_values) do
    %{
      type: :if,
      condition: cond,
      then_body: convert_fsm_body(then_b, state_values),
      else_body: case else_b do
        nil -> nil
        body -> convert_fsm_body(body, state_values)
      end
    }
  end

  # Nested data case (e.g. PHY TX :data hdl_case on <<tx_se0,tx_valid,tx_data>>):
  # recurse into each clause body so a `next` (-> {:state, atom}) inside a clause is
  # converted to its numeric const. Without this the arc parsed correctly but the
  # elaborator hit `Cannot elaborate expression: {:state, :eop1}`.
  defp convert_fsm_stmt(%{type: :case, clauses: clauses} = c, state_values) do
    %{c | clauses: Enum.map(clauses, fn cl ->
            %{cl | body: convert_fsm_body(cl.body, state_values)}
          end)}
  end

  defp convert_fsm_stmt(stmt, _state_values), do: stmt
end
