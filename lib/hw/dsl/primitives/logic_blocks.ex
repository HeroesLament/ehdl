defmodule Hw.DSL.Primitives.LogicBlocks do
  @moduledoc """
  Logic block macros: on, comb, fsm, instance, interface, connect, generate.
  """

  alias Hw.DSL.Primitives.Parse
  alias Hw.Analysis.Location

  @doc """
  Define a finite state machine.

      fsm :state, clock: :clk, init: :idle do
        defaults do
          valid <= 0
        end

        case state do
          :idle ->
            on rx == 0, next: :start_bit

          :start_bit ->
            counter <= 0
            next :receive

          :receive ->
            data[counter] <= rx
            on counter == 7, next: :stop_bit
            on :else, do: counter <= counter + 1

          :stop_bit ->
            valid <= 1
            next :idle
        end
      end

  Options:
  - clock: (required) clock signal name
  - init: (required) initial state atom
  - encoding: :binary (default), :onehot, or :gray
  """
  defmacro fsm(name, opts, do: block) do
    clock    = Keyword.fetch!(opts, :clock)
    init     = Keyword.fetch!(opts, :init)
    encoding = Keyword.get(opts, :encoding, :binary)
    reset    = Keyword.get(opts, :reset, nil)

    {defaults, states, case_body} = Parse.parse_fsm_block(block, name)

    # Post-process to combine if/fsm_else pairs
    case_body = postprocess_fsm_case(case_body)

    num_states   = length(states)
    state_width  = case encoding do
      :onehot -> num_states
      _       -> max(1, ceil(:math.log2(max(num_states, 2))))
    end

    quote do
      @hw_signals %{
        name:      unquote(name),
        width:     unquote(state_width),
        direction: :internal,
        signed:    :unsigned,
        init:      0
      }
      @hw_fsm %{
        name:     unquote(name),
        clock:    unquote(clock),
        init:     unquote(init),
        encoding: unquote(encoding),
        reset:    unquote(reset),
        states:   unquote(states),
        defaults: unquote(Macro.escape(defaults)),
        case_body: unquote(Macro.escape(case_body))
      }
    end
  end

  # Placeholder macro for defaults - actual parsing handled by parse_fsm_block
  defmacro defaults(do: _block) do
    raise "defaults must be used inside an fsm block"
  end

  # Placeholder for next - parsed specially in FSM context
  defmacro next(_state) do
    raise "next must be used inside an fsm block"
  end

  # ---------------------------------------------------------------------------
  # Pipeline — feed-forward staged datapath sugar.
  # ---------------------------------------------------------------------------

  @doc """
  Declare a feed-forward pipeline.

  Each `stage do out = expr end` becomes one registered stage. Stage outputs are
  auto-declared with inferred width (`:infer`, resolved from the driver), and a
  valid bit is threaded from `valid_in:` to `valid_out:`, delayed to match the
  pipeline depth so a caller knows when the output is real. Only the valid chain
  is reset; data registers are left un-reset (they are don't-care until valid).

      pipeline :cfar, clock: :clk, reset: :rst, valid_in: :in_v, valid_out: :det_v do
        stage do noise_sum = sum_l + sum_t end
        stage do noise     = noise_sum >>> LOG2_N end
        stage do thresh    = noise * ALPHA end
        stage do detect    = cut > thresh end
      end

  Options: `clock:` (required), `reset:`, `valid_in:`, `valid_out:`.
  Stage inputs, `valid_in`, and `valid_out` are declared by the caller; the
  stage outputs and the intermediate valid registers are generated here.
  """
  defmacro pipeline(name, opts, do: block) do
    clock     = Keyword.fetch!(opts, :clock)
    reset     = Keyword.get(opts, :reset)
    valid_in  = Keyword.get(opts, :valid_in)
    valid_out = Keyword.get(opts, :valid_out)

    stage_stmts = block |> extract_pipeline_stages() |> Enum.map(&pipeline_stage_stmt/1)

    if stage_stmts == [] do
      raise "pipeline #{inspect(name)} has no `stage do ... end` blocks"
    end

    stage_outs = Enum.map(stage_stmts, &pipeline_assign_target/1)
    n = length(stage_stmts)

    # --- Phase 2: auto-balance cross-stage references. ------------------------
    # A signal referenced in stage i must arrive at depth i. The prior stage's
    # output already does; anything older (an external input, or a stage output
    # from further back) is delayed by matching registers so it lines up with
    # the sample flowing through.
    # Classification is by AST shape, which matches EHDL naming convention:
    # lowercase bare identifiers are signals; UPPERCASE params parse as aliases
    # (not vars) and calls/literals aren't vars either, so neither is ever
    # delayed. This needs no module-attribute lookups (which aren't populated at
    # macro-expansion time anyway).
    stage_index = stage_outs |> Enum.with_index() |> Map.new()

    {stage_stmts, delay_max} =
      stage_stmts
      |> Enum.with_index()
      |> Enum.map_reduce(%{}, fn {stmt, i}, dmax ->
        {new_stmt, used} = rewrite_stage(stmt, i, stage_index)
        {new_stmt, merge_delays(dmax, used)}
      end)

    delay_assigns = build_delay_chains(delay_max)
    delay_wires   = delay_wire_decls(delay_max)

    # Valid chain: valid_out = valid_in delayed n cycles (n-1 intermediate regs).
    {valid_shift, valid_reset, valid_intermediates} =
      if valid_in && valid_out do
        inters  = for i <- 1..(n - 1)//1, do: :"#{name}__valid_#{i}"
        targets = inters ++ [valid_out]
        sources = [valid_in | inters]
        shift   = targets |> Enum.zip(sources) |> Enum.map(fn {t, s} -> pipe_assign(t, pipe_var(s)) end)
        reset   = Enum.map(targets, fn t -> pipe_assign(t, 0) end)
        {shift, reset, inters}
      else
        {[], [], []}
      end

    valid_block =
      case {reset, valid_shift} do
        {rst, [_ | _]} when not is_nil(rst) ->
          # Only the valid chain is reset; data registers load unconditionally.
          [
            quote do
              if unquote(pipe_var(rst)) do
                unquote_splicing(valid_reset)
              else
                unquote_splicing(valid_shift)
              end
            end
          ]

        _ ->
          valid_shift
      end

    on_body = {:__block__, [], delay_assigns ++ stage_stmts ++ valid_block}

    infer_wires = for o <- stage_outs ++ delay_wires, do: quote(do: wire(unquote(o), :infer))
    valid_wires = for v <- valid_intermediates, do: quote(do: wire(unquote(v), 1, init: 0))

    quote do
      unquote_splicing(infer_wires)
      unquote_splicing(valid_wires)

      on unquote(clock) do
        unquote(on_body)
      end
    end
  end

  @doc false
  defmacro stage(do: _block) do
    raise "stage must be used inside a pipeline block"
  end

  # Extract the list of stage bodies (raw AST) from a pipeline do-block.
  defp extract_pipeline_stages({:__block__, _, stmts}) do
    stmts
    |> Enum.filter(&match?({:stage, _, [[do: _]]}, &1))
    |> Enum.map(fn {:stage, _, [[do: body]]} -> body end)
  end
  defp extract_pipeline_stages({:stage, _, [[do: body]]}), do: [body]
  defp extract_pipeline_stages(_), do: []

  # A stage body must be a single `out = expr` assignment (Phase 1 scope).
  defp pipeline_stage_stmt({:__block__, _, [single]}), do: pipeline_stage_stmt(single)
  defp pipeline_stage_stmt({:=, _, [_lhs, _rhs]} = assign), do: assign
  defp pipeline_stage_stmt(other) do
    raise "each pipeline stage must be a single `out = expr` assignment, got: #{Macro.to_string(other)}"
  end

  defp pipeline_assign_target({:=, _, [{name, _, _}, _]}) when is_atom(name), do: name
  defp pipeline_assign_target(other) do
    raise "pipeline stage must assign a bare signal name, got: #{Macro.to_string(other)}"
  end

  defp pipe_var(name), do: Macro.var(name, nil)
  defp pipe_assign(target, value_ast), do: {:=, [], [pipe_var(target), value_ast]}

  # Rewrite one stage's RHS so each cross-stage reference reads its delay-aligned
  # tap. Returns {rewritten_assign, %{source => max_delay_used_here}}.
  defp rewrite_stage({:=, m, [lhs, rhs]}, i, stage_index) do
    {new_rhs, used} =
      Macro.prewalk(rhs, %{}, fn
        {nm, vm, ctx}, acc when is_atom(nm) and not is_list(ctx) ->
          case ref_delay(nm, i, stage_index) do
            0 ->
              {{nm, vm, ctx}, acc}

            d when d > 0 ->
              tap = :"#{nm}__dly_#{d}"
              {{tap, vm, ctx}, Map.update(acc, nm, d, &max(&1, d))}

            d when d < 0 ->
              raise "pipeline: stage #{i} references `#{nm}` from the same or a later " <>
                    "stage (illegal feedback/forward reference in a pipeline)"
          end

        node, acc ->
          {node, acc}
      end)

    {{:=, m, [lhs, new_rhs]}, used}
  end

  # Delay a reference to `nm` needs as a stage-`i` operand. A prior stage output
  # is already aligned (delay 0); an older stage output needs `i - j - 1`; every
  # other bare signal is a streaming input and needs `i`. Params are aliases and
  # never reach here, so they stay compile-time constants.
  defp ref_delay(nm, i, stage_index) do
    case Map.get(stage_index, nm) do
      nil -> i
      j   -> i - j - 1
    end
  end

  defp merge_delays(dmax, used), do: Map.merge(dmax, used, fn _k, a, b -> max(a, b) end)

  defp build_delay_chains(delay_max) do
    Enum.flat_map(delay_max, fn {src, m} ->
      for d <- 1..m//1 do
        prev = if d == 1, do: src, else: :"#{src}__dly_#{d - 1}"
        pipe_assign(:"#{src}__dly_#{d}", pipe_var(prev))
      end
    end)
  end

  defp delay_wire_decls(delay_max) do
    Enum.flat_map(delay_max, fn {src, m} ->
      for d <- 1..m//1, do: :"#{src}__dly_#{d}"
    end)
  end

  # Post-process case body to merge if statements with following fsm_else
  defp postprocess_fsm_case(%{type: :case, clauses: clauses} = case_body) do
    %{case_body | clauses: Enum.map(clauses, &postprocess_clause/1)}
  end

  defp postprocess_clause(%{body: body} = clause) do
    %{clause | body: merge_fsm_else(body)}
  end

  # Merge consecutive if + fsm_else into if with else_body, recursively
  defp merge_fsm_else([]), do: []
  defp merge_fsm_else([%{type: :if} = if_stmt, %{type: :fsm_else, body: else_body} | rest]) do
    merged = %{if_stmt |
      then_body: merge_fsm_else(if_stmt.then_body),
      else_body: merge_fsm_else(else_body)
    }
    [merged | merge_fsm_else(rest)]
  end
  defp merge_fsm_else([%{type: :if} = if_stmt | rest]) do
    merged = %{if_stmt | then_body: merge_fsm_else(if_stmt.then_body)}
    [merged | merge_fsm_else(rest)]
  end
  defp merge_fsm_else([stmt | rest]), do: [stmt | merge_fsm_else(rest)]

  @doc """
  Generate replicated logic.

      generate i <- 0..7 do
        out[i] <= in[7 - i]
      end

  The loop variable is substituted at compile time.
  """
  defmacro generate({:<-, _, [{var, _, _}, range]}, do: block) do
    # Evaluate the range at compile time
    range_values = case range do
      {:.., _, [lo, hi]} -> Enum.to_list(lo..hi)
      _ -> raise "generate requires a range like 0..N"
    end

    # Generate statements for each value
    statements = Enum.flat_map(range_values, fn val ->
      # Substitute the variable with the value in the block
      substituted = substitute_var(block, var, val)
      Parse.parse_statements(substituted)
    end)

    quote do
      @hw_logic %{
        type: :combinational,
        body: unquote(Macro.escape(statements))
      }
    end
  end

  # Substitute a variable with a value in an AST
  defp substitute_var({var, _, nil}, var, val) when is_atom(var), do: val
  defp substitute_var({var, _, ctx}, var, val) when is_atom(var) and is_atom(ctx), do: val
  defp substitute_var({op, meta, args}, var, val) when is_list(args) do
    {op, meta, Enum.map(args, &substitute_var(&1, var, val))}
  end
  defp substitute_var({a, b}, var, val) do
    {substitute_var(a, var, val), substitute_var(b, var, val)}
  end
  defp substitute_var(list, var, val) when is_list(list) do
    Enum.map(list, &substitute_var(&1, var, val))
  end
  defp substitute_var(other, _var, _val), do: other

  @doc """
  Define a named, reusable hardware logic fragment.

  `defhw` declares a parameterized logic template that the elaborator inlines
  at each call site. It is NOT a runtime function — it is an expression or
  statement template that gets substituted before IR generation.

  ## Expression-level (no assignments — usable as an expression)

      defhw crc_valid?(crc) do
        bxor(crc[15..0], 0xB001) == 0
      end

      defhw data_pid?(pid) do
        pid == 0xC3 or pid == 0x4B
      end

  Call inside `comb do` or on the RHS of any assignment:

      comb do
        crc_ok = crc_valid?(crc16_reg)
      end

  ## Statement-level (contains assignments — inlined as a block)

      defhw load_ep1_in(pid_val) do
        ep_in_ep     <= 1
        ep_in_pid    <= pid_val
        ep_in_valid  <= one
        ep_in_loaded <= one
      end

  Call inside `on :clk do`:

      on :clk do
        if tx_valid and not ep1_in_busy do
          load_ep1_in(if ep1_toggle, do: pid_data1, else: pid_data0)
        end
      end

  ## Rules

  - Cannot declare wires, registers, or clocks
  - Cannot call itself (no recursion)
  - Parameters are substituted by name — no runtime evaluation
  - Closes over all signals in the enclosing component scope
  - Statement-level defhw (containing `<=`) can only be called from `on :clk do`
  - Expression-level defhw can be called anywhere an expression is valid
  """
  defmacro defhw(call, do: block) do
    {name, params} = case call do
      {fname, _, nil}  -> {fname, []}
      {fname, _, args} -> {fname, Enum.map(args, fn
        {pname, _, nil} -> pname
        {pname, _, _}   -> pname
        pname when is_atom(pname) -> pname
      end)}
    end

    loc = Location.from_env(__CALLER__)

    # Detect `on` blocks in the raw AST — these make the defhw simulation-only.
    # A sim_only defhw is never inlined into hardware; it is only interpreted
    # by Hw.Sim.DefhwInterpreter at simulation time.
    has_on_block = case block do
      {:__block__, _, stmts} -> Enum.any?(stmts, &match?({:on, _, _}, &1))
      {:on, _, _} -> true
      _ -> false
    end

    # Determine if the body is expression-level (single bare expression)
    # or statement-level (contains assignments, if, case, hdl_case, etc.)
    parsed = case block do
      {:__block__, _, _}   -> Parse.parse_statements(block)
      {:=, _, _}           -> Parse.parse_statements(block)
      {:if, _, _}          -> Parse.parse_statements(block)
      {:case, _, _}        -> Parse.parse_statements(block)
      {:hdl_case, _, _}    -> Parse.parse_statements(block)
      {:generate, _, _}    -> Parse.parse_statements(block)
      _ ->
        # Single expression — store as expression-level body marker
        [%{type: :defhw_expr, value: Parse.parse_expr(block)}]
    end

    # A defhw is sequential if its body contains any `on` blocks.
    # Sequential defhws tick the clock in simulation and cannot be
    # inlined into hardware — the elaborator raises if this is attempted.
    sequential = Enum.any?(parsed, fn
      %{type: :sequential} -> true
      %{type: :if, then_body: b} -> Enum.any?(b, &match?(%{type: :sequential}, &1))
      _ -> false
    end)

    quote do
      @hw_defhw %{
        name:            unquote(name),
        params:          unquote(params),
        body:            unquote(Macro.escape(parsed)),
        sequential:      unquote(sequential),
        sim_only:        unquote(has_on_block),
        source_location: unquote(Macro.escape(loc))
      }
    end
  end

  @doc "Define clocked (sequential) logic."
  defmacro on(clock_name, do: block) do
    parsed = block |> preprocess_block() |> Parse.parse_on_block()

    quote do
      @hw_logic %{
        type: :sequential,
        clock: unquote(clock_name),
        async_reset: nil,
        body: unquote(Macro.escape(parsed))
      }
    end
  end

  defmacro on(clock_name, opts, do: block) do
    async_reset = Keyword.get(opts, :async_reset)
    parsed = block |> preprocess_block() |> Parse.parse_on_block()

    quote do
      @hw_logic %{
        type: :sequential,
        clock: unquote(clock_name),
        async_reset: unquote(async_reset),
        body: unquote(Macro.escape(parsed))
      }
    end
  end

  @doc "Define combinational logic."
  defmacro comb(do: block) do
    parsed = block |> preprocess_block() |> Parse.parse_comb_block()

    quote do
      @hw_logic %{
        type: :combinational,
        body: unquote(Macro.escape(parsed))
      }
    end
  end

  @doc """
  Like `case` but allows `<<signal::width>>` binary patterns in the subject.

  Elixir's compiler expands `<<>>` expressions before macros can intercept
  them, rejecting signal names as undefined variables. `hdl_case` is a macro
  that receives the subject as raw AST, shielding it from that expansion so
  the EHDL parser sees the binary pattern intact.

      hdl_case <<rx_state::1, sym_se0::1, sym_k::1>> do
        <<0::1, _::1, 0::1>> -> nil
        <<0::1, 0::1, 1::1>> ->
          rx_state <= one
        <<1::1, 1::1, _::1>> ->
          rx_state <= zero
        <<1::1, 0::1, _::1>> ->
          prev_diff <= dp_diff
      end

  The clause patterns (`<<0::1, _::1, 0::1>>` etc.) must use integer literals
  and wildcards only — signal names in patterns are not supported. Only the
  subject can reference signals.
  """
  defmacro hdl_case(subject, do: clauses) do
    # hdl_case is the unified pattern matcher for EHDL DSL.
    # Handles both plain patterns (integers, atoms) AND binary
    # <<signal::width>> patterns that bare `case` cannot handle.
    #
    # The key challenge: `on`/`comb` macros receive their do-block AFTER
    # inner macros have been expanded. We need the case structure — including
    # binary subject ASTs — to survive so parse_statement can find them.
    #
    # Solution: store the real {subject, clauses} AST in the process
    # dictionary under a unique key at macro expansion time. Then expand
    # to a plain `case :__hw_case_KEY__ do _ -> nil end` sentinel.
    # parse_statement sees the sentinel atom, retrieves the real AST, and
    # routes through the normal binary case machinery.
    #
    # This works because all macros in a module compile in the same process.
    key = :"__hw_case_#{:erlang.unique_integer([:positive, :monotonic])}__"
    Process.put(key, {subject, clauses})

    quote do
      case unquote(key) do
        _ -> nil
      end
    end
  end

  defp preprocess_block(block), do: block

  @doc "Instantiate a child component."
  defmacro instance(name, module, port_map) do
    loc = Location.from_env(__CALLER__)
    quote do
      @hw_instances %{
        name:            unquote(name),
        module:          unquote(module),
        ports:           unquote(port_map),
        source_location: unquote(Macro.escape(loc))
      }
    end
  end

  @doc "Declare an interface bundle."
  defmacro interface(name, module, opts) do
    quote do
      signals = Hw.Interface.expand(unquote(module), unquote(name), unquote(opts))
      for sig <- signals do
        @hw_signals sig
      end

      @hw_interfaces %{
        name: unquote(name),
        module: unquote(module),
        opts: unquote(opts)
      }
    end
  end

  @doc """
  Connect two interfaces together.

  Used in top-level modules to wire a provider interface on one instance
  to a consumer interface on another.

      connect :sie, :tx, :cdc, :tx
  """
  defmacro connect(provider_inst, provider_iface, consumer_inst, consumer_iface) do
    loc = Location.from_env(__CALLER__)
    quote do
      @hw_connections %{
        provider_module:    __MODULE__,
        provider_instance:  unquote(provider_inst),
        provider_interface: unquote(provider_iface),
        consumer_instance:  unquote(consumer_inst),
        consumer_interface: unquote(consumer_iface),
        source_location:    unquote(Macro.escape(loc))
      }
    end
  end

  # Keep the old 2-arity connect for backwards compatibility with existing
  # source_instance/sink_instance style connections.
  defmacro connect(source, sink) do
    loc = Location.from_env(__CALLER__)
    {src_inst, src_if} = parse_interface_ref(source)
    {sink_inst, sink_if} = parse_interface_ref(sink)

    quote do
      @hw_connections %{
        source_instance:  unquote(src_inst),
        source_interface: unquote(src_if),
        sink_instance:    unquote(sink_inst),
        sink_interface:   unquote(sink_if),
        source_location:  unquote(Macro.escape(loc))
      }
    end
  end

  # Parse interface.name or name
  defp parse_interface_ref({{:., _, [{inst, _, _}, if_name]}, _, _}) do
    {inst, if_name}
  end
  defp parse_interface_ref({if_name, _, _}) when is_atom(if_name) do
    {nil, if_name}
  end
end
