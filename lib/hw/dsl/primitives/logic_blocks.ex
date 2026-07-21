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
