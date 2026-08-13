defmodule Hw.Emit.Verilog.Sequential do
  @moduledoc """
  Verilog emission for sequential logic, memory, blackbox, and tristate.
  """

  alias Hw.IR.Ops.{Reg, MemRead, MemWrite, Blackbox, Tristate}
  alias Hw.Emit.Verilog.Ops, as: VerilogOps

  # --- Sequential Logic ---

  @doc """
  Emit sequential (registered) logic as always blocks.
  """
  def emit_sequential_logic(ops, clocks, kept \\ MapSet.new()) do
    regs = Enum.filter(ops, &match?(%Reg{}, &1))

    case regs do
      [] -> []
      _ ->
        # Group by both clock name AND reset style — reset_style: :none
        # registers must be in a separate always block, not merged with
        # the main if(rst) block even if they share the same clock signal.
        by_clock = Enum.group_by(regs, fn reg ->
          {reg.clock.name, Map.get(reg.clock, :reset_style, :sync)}
        end)

        ["  // Sequential logic" |
          Enum.flat_map(by_clock, fn {clock_key, clock_regs} ->
            {clock_name, reset_style} = clock_key
            clock = Enum.find(clocks, &(&1.name == clock_name))
            block_kept = Enum.any?(clock_regs, fn reg ->
              MapSet.member?(kept, reg.output.name)
            end)

            if reset_style == :none do
              emit_noreset_clock_block(clock, clock_regs, block_kept)
            else
              emit_clock_block(clock, clock_regs, block_kept)
            end
          end)
        ]
    end
  end

  # Emit a bare always block with no reset gating.
  # Used for reset_style: :none domains — registers rely on FF init values only.
  defp emit_noreset_clock_block(clock, regs, block_kept) do
    edge = if clock.edge == :posedge, do: "posedge", else: "negedge"
    keep_attr = if block_kept, do: "  (* keep *) ", else: "  "
    lines = ["#{keep_attr}always @(#{edge} #{clock.name}) begin"]
    assign_lines = Enum.flat_map(regs, fn reg ->
      emit_reg_assignment(reg, false)
    end)
    lines ++ assign_lines ++ ["  end"]
  end

  defp emit_clock_block(clock, regs, block_kept) do
    edge = if clock.edge == :posedge, do: "posedge", else: "negedge"

    {with_reset, without_reset} = Enum.split_with(regs, & &1.reset_value != nil)
    has_reset = with_reset != []

    async_reset = Enum.find_value(regs, fn reg -> reg.async_reset end)

    # Build sensitivity list
    sensitivity = if async_reset do
      "#{edge} #{clock.name} or posedge #{async_reset}"
    else
      "#{edge} #{clock.name}"
    end

    keep_attr = if block_kept, do: "  (* keep *) ", else: "  "
    lines = ["#{keep_attr}always @(#{sensitivity}) begin"]

    # Use the clock's declared reset signal, falling back to :rst for
    # backward compatibility with components that don't declare one
    # Only a reset signal we can actually name. The old `|| :rst` fallback
    # emitted `if (rst)` against a wire that need not exist: after an instance
    # is flattened its local `rst` becomes `<inst>_rst`, so the guard referenced
    # an undeclared identifier. Verilog implicitly declares it, nothing drives
    # it, and synthesis treats it as a constant — yosys reported "always-active
    # SRST" and folded a whole design away. No error is raised anywhere along
    # that path, which is what made it expensive to find.
    #
    # Losing the guard costs nothing: `reset:` on an fsm is elaborated into a
    # priority mux inside the register's input (`rst ? init : d`), and that mux
    # is correctly renamed during flattening. Synthesis infers the synchronous
    # reset from it just the same.
    reset_signal = async_reset || Map.get(clock, :reset_signal)
    emit_guard? = has_reset and reset_signal != nil

    # A register with no reset value must be assigned UNCONDITIONALLY. It must
    # never land inside the else branch of some other register's reset guard.
    #
    # A reset synchroniser has exactly that shape — two unreset flops feeding
    # the reset that everything else is guarded by. Sweeping it into the else
    # branch gates the synchroniser with the reset it generates: the reset
    # asserts at power-up, the synchroniser can never advance, the reset never
    # deasserts, and every flop in the domain sits at its reset value forever.
    #
    # It is not a subtle failure. Synthesis proves the design does nothing and
    # folds it to nothing: yosys reports "always-active SRST (changing to const
    # D)" and a LibreSDR PS7 bring-up design collapsed to two cells (the PS7
    # and a clock buffer) with every register gone. The generated Verilog looks
    # plausible, so this reads as a toolchain problem rather than an emitter
    # bug — which is why the split is now honoured rather than discarded.
    {plain_regs, guarded_regs} =
      if emit_guard?, do: {without_reset, with_reset}, else: {regs, []}

    plain_lines = Enum.flat_map(plain_regs, &emit_reg_assignment(&1, false))

    guard_lines =
      if emit_guard? do
        ["    if (#{reset_signal}) begin"] ++
          Enum.map(guarded_regs, fn reg ->
            "      #{reg.output.name} <= #{VerilogOps.emit_value(reg.reset_value)};"
          end) ++
          ["    end else begin"] ++
          Enum.flat_map(guarded_regs, &emit_reg_assignment(&1, true)) ++
          ["    end"]
      else
        []
      end

    lines ++ plain_lines ++ guard_lines ++ ["  end"]
  end

  defp emit_reg_assignment(reg, has_reset_block) do
    indent = if has_reset_block, do: "      ", else: "    "

    case reg.enable do
      nil ->
        ["#{indent}#{reg.output.name} <= #{VerilogOps.emit_value(reg.input)};"]
      en ->
        ["#{indent}if (#{en.name}) #{reg.output.name} <= #{VerilogOps.emit_value(reg.input)};"]
    end
  end

  # --- Memory Logic ---

  @doc """
  Emit memory writes and synchronous reads.
  """
  def emit_memory_logic(ops, clocks) do
    writes = Enum.filter(ops, &match?(%MemWrite{}, &1))
    sync_reads = Enum.filter(ops, fn
      %MemRead{clock: clk} when clk != nil -> true
      _ -> false
    end)

    mem_ops = writes ++ sync_reads

    case mem_ops do
      [] -> []
      _ ->
        by_clock = Enum.group_by(mem_ops, fn
          %MemWrite{clock: clk} -> clk.name
          %MemRead{clock: clk} -> clk.name
        end)

        ["  // Memory logic" |
          Enum.flat_map(by_clock, fn {clock_name, clock_ops} ->
            clock = Enum.find(clocks, &(&1.name == clock_name))
            emit_memory_clock_block(clock, clock_ops)
          end)
        ]
    end
  end

  defp emit_memory_clock_block(clock, mem_ops) do
    edge = if clock.edge == :posedge, do: "posedge", else: "negedge"

    lines = ["  always @(#{edge} #{clock.name}) begin"]

    op_lines = Enum.flat_map(mem_ops, fn
      %MemWrite{memory: mem, addr: addr, data: data, enable: en} ->
        ["    if (#{VerilogOps.emit_value(en)}) #{mem}[#{VerilogOps.emit_value(addr)}] <= #{VerilogOps.emit_value(data)};"]
      %MemRead{output: out, memory: mem, addr: addr} ->
        ["    #{out.name} <= #{mem}[#{VerilogOps.emit_value(addr)}];"]
    end)

    lines ++ op_lines ++ ["  end"]
  end

  # --- Blackbox Instances ---

  @doc """
  Emit blackbox module instantiations.
  """
  def emit_blackbox_instances(ops, design_params \\ []) do
    blackboxes = Enum.filter(ops, &match?(%Blackbox{}, &1))
    param_map = Map.new(design_params, fn p -> {p.name, p.value} end)

    case blackboxes do
      [] -> []
      _ ->
        ["  // Module instances" |
          Enum.map(blackboxes, &emit_blackbox(&1, param_map))
        ]
    end
  end

  defp emit_blackbox(%Blackbox{name: name, module: mod, params: params, ports: ports, attrs: attrs}, param_map) do
    attr_str = case attrs do
      [] -> ""
      _ ->
        attrs
        |> Enum.map(fn {k, v} -> "(* #{k}=\"#{v}\" *)" end)
        |> Enum.join(" ")
        |> then(fn s -> "  #{s}\n" end)
    end
    param_str = case params do
      [] -> ""
      _ ->
        param_list = Enum.map(params, fn {k, v} ->
          # Resolve atom param refs against the design's own params
          resolved = case v do
            atom when is_atom(atom) ->
              case Map.get(param_map, atom) do
                nil -> atom
                val -> val
              end
            other -> other
          end
          formatted = if is_binary(resolved), do: ~s("#{resolved}"), else: to_string(resolved)
          ".#{k}(#{formatted})"
        end)
        " #(\n    " <> Enum.join(param_list, ",\n    ") <> "\n  )"
    end

    port_list = Enum.map(ports, fn {port_name, connection} ->
      ".#{port_name}(#{VerilogOps.emit_value(connection)})"
    end)
    port_str = Enum.join(port_list, ",\n    ")


    "#{attr_str}  #{mod}#{param_str} #{name} (\n    #{port_str}\n  );"
  end

  # --- Tristate Logic ---

  @doc """
  Emit tristate buffer logic.
  """
  def emit_tristate_logic(ops) do
    tristates = Enum.filter(ops, &match?(%Tristate{}, &1))

    case tristates do
      [] -> []
      _ ->
        ["  // Tristate buffers" |
          Enum.flat_map(tristates, &emit_tristate/1)
        ]
    end
  end

  defp emit_tristate(%Tristate{io: io, output_value: out_val, output_enable: en, input_value: in_val}) do
    # Emit ECP5 BB (bidirectional buffer) primitive.
    # BB has separate I (drive to pad), T (tristate, active HIGH = Z),
    # B (the actual pad), and O (read from pad) ports.
    # This gives proper electrical separation between the drive path and
    # the read-back path — plain assign loops don't work on real silicon.
    inst_name = "#{io.name}_bb"
    [
      "  BB #{inst_name} (",
      "    .I(#{VerilogOps.emit_value(out_val)}),",
      "    .T(~#{VerilogOps.emit_value(en)}),",
      "    .B(#{io.name}),",
      "    .O(#{in_val.name})",
      "  );"
    ]
  end
end
