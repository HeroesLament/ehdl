defmodule Hw.Emit.Verilog do
  @moduledoc """
  Emit boring, explicit Verilog from IR.

  ## Design Philosophy

  - No clever Verilog
  - No synthesis pragmas
  - No vendor-specific constructs
  - No optimizations
  - If emitting is hard, the IR is wrong

  The output should look like something a VHDL engineer would accept
  without squinting.
  """

  alias Hw.IR.Design
  alias Hw.IR.Types.Signal
  alias Hw.IR.Ops.{Reg, Mem, MemWrite, Blackbox, Tristate, MemRead}
  alias Hw.Emit.Verilog.{Ops, Sequential}

  @doc """
  Emit a design as Verilog text.
  """
  def emit(%Design{} = design, opts \\ []) do
    design =
      design
      |> Design.finalize()
      |> maybe_optimize(opts)
      # Reserved-word nets/memories renamed; reserved port names raise.
      |> Hw.Emit.Verilog.Names.legalize()

    # Default keep policy: clock_domain_preservation only.
    #
    # output_reachability and blackbox_fanout are intentionally excluded from the
    # default. Both are redundant with correct synthesis: yosys never prunes
    # logic that drives a primary output, nor logic driven by an opaque blackbox
    # output it can't see inside. Their only effect is to `(* keep *)` those nets,
    # which BLOCKS yosys from optimizing them. Worse, both expand into ~the whole
    # design here (output_reachability pins the fanin cone of the debug dashboard;
    # blackbox_fanout can't tell the PLL's input connections from its outputs and
    # forward-expands from tie-off constants like diag_zero and the clock nets).
    # Measured cost: ~5.5k LUT4 vs ~1.8k with them off, and the device enumerates
    # identically either way (silicon-gated). Both remain available via
    # opts[:keep_policies] for designs that genuinely need them.
    policies = Keyword.get(opts, :keep_policies, [:clock_domain_preservation])
    kept = Hw.Compile.KeepPolicy.compute(design, policies: policies)

    # Emit case-derived muxes as parallel `casez` (decoded once) instead of the
    # priority if-chain when opts[:casez] is set. Off by default -> byte-identical
    # emission. Requires the Mux to carry selector+patterns metadata (elaborator).
    casez? = Keyword.get(opts, :casez, false)

    [
      emit_module_header(design),
      emit_port_declarations(design),
      emit_localparams(design),
      "",
      emit_internal_wires(design, kept),
      emit_memory_declarations(design),
      emit_initial_values(design),
      "",
      emit_combinational_logic(design, kept, casez?),
      "",
      Sequential.emit_sequential_logic(design.ops, design.clocks, kept),
      Sequential.emit_memory_logic(design.ops, design.clocks),
      Sequential.emit_blackbox_instances(design.ops, design.params),
      Sequential.emit_tristate_logic(design.ops),
      "",
      "endmodule"
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  # Run the IR optimizer between finalize and emission. Inert unless
  # `opts[:optimize]` is truthy (Hw.Optimize.run/2 short-circuits), so the
  # default emit path is byte-for-byte unchanged. See `Hw.Optimize`.
  defp maybe_optimize(%Design{} = design, opts) do
    Hw.Optimize.run(design, opts)
  end

  # --- Module Header ---

  defp emit_module_header(%Design{name: name} = design) do
    inputs = Design.inputs(design)
    outputs = Design.outputs(design)
    inouts = Design.inouts(design)

    # Only emit clocks as ports if they have no internal wire driver.
    # Clocks derived from PLL outputs (or any internal logic) have a
    # corresponding :internal signal with the same name — those are
    # wires, not primary inputs, and must not appear in the port list.
    internal_names = MapSet.new(Design.internals(design), & &1.name)
    clocks = Enum.reject(design.clocks, fn clk ->
      MapSet.member?(internal_names, clk.name)
    end)

    port_names =
      Enum.map(clocks, &Atom.to_string(&1.name)) ++
      Enum.map(inputs, &Atom.to_string(&1.name)) ++
      Enum.map(outputs, &Atom.to_string(&1.name)) ++
      Enum.map(inouts, &Atom.to_string(&1.name))

    # Check if we have parameters
    params = Map.get(design, :params, [])

    if params == [] do
      [
        "module #{name} (",
        "  " <> Enum.join(port_names, ",\n  "),
        ");"
      ]
    else
      # Emit with parameter block
      param_decls = Enum.map(params, fn p ->
        if p.default do
          "  parameter #{p.name} = #{p.default}"
        else
          "  parameter #{p.name}"
        end
      end)

      [
        "module #{name} #(",
        Enum.join(param_decls, ",\n"),
        ") (",
        "  " <> Enum.join(port_names, ",\n  "),
        ");"
      ]
    end
  end

  # --- Port Declarations ---

  defp emit_port_declarations(%Design{} = design) do
    internal_names = MapSet.new(Design.internals(design), & &1.name)
    clocks = Enum.reject(design.clocks, fn clk ->
      MapSet.member?(internal_names, clk.name)
    end)
    inputs = Design.inputs(design)
    outputs = Design.outputs(design)
    inouts = Design.inouts(design)

    clock_decls = Enum.map(clocks, fn clk ->
      "  input #{clk.name};"
    end)

    input_decls = Enum.map(inputs, &emit_port_decl(&1, :input))
    # An output assigned procedurally (a registered output, or a >2-arm mux
    # rendered as always @(*)) must be `output reg`: a bare `output` is a net,
    # and procedural assignment to a net is illegal Verilog. Yosys tolerated
    # it; iverilog rejects it (found 2026-09-24, Hw.AXIHPWriter's `bursts`).
    procedural = procedural_names(design)

    output_decls =
      Enum.map(outputs, fn sig ->
        if MapSet.member?(procedural, sig.name),
          do: emit_port_decl(sig, :"output reg"),
          else: emit_port_decl(sig, :output)
      end)

    inout_decls = Enum.map(inouts, &emit_port_decl(&1, :inout))

    clock_decls ++ input_decls ++ output_decls ++ inout_decls
  end

  defp emit_port_decl(%Signal{name: name, width: width, signed: signed}, direction) do
    dir = Atom.to_string(direction)
    type_str = if signed == :signed, do: "signed ", else: ""
    width_str = if width == 1, do: "", else: "[#{width - 1}:0] "
    "  #{dir} #{type_str}#{width_str}#{name};"
  end

  # --- Localparam Declarations (FSM states, etc.) ---

  defp emit_localparams(%Design{localparams: []}) do
    []
  end

  defp emit_localparams(%Design{localparams: localparams}) do
    ["" , "  // State encoding" |
      Enum.map(localparams, fn lp ->
        "  localparam #{lp.name} = #{lp.width}'d#{lp.value};"
      end)
    ]
  end

  # --- Internal Wire Declarations ---

  # Every signal the emitted Verilog assigns PROCEDURALLY, i.e. inside an
  # always block, and which therefore must be declared `reg`:
  #   * Reg outputs (clocked always, Sequential.emit_sequential_logic);
  #   * synchronous MemRead outputs (clocked always, emit_memory_logic);
  #   * combinational ops the renderer emits as `always @(*)`, as decided by
  #     Structure.procedural?/1 (the same predicate the renderer uses).
  # One set, used for internals AND output ports, so the two can't disagree.
  defp procedural_names(%Design{ops: ops}) do
    ops
    |> Enum.filter(fn
      %Reg{} -> true
      %MemRead{clock: clk} -> clk != nil
      op -> Hw.Emit.Verilog.Ops.Structure.procedural?(op)
    end)
    |> MapSet.new(& &1.output.name)
  end

  defp emit_internal_wires(%Design{} = design, kept) do
    internals = Design.internals(design)
    clock_names = MapSet.new(design.clocks, & &1.name)

    # Signals assigned procedurally must be declared `reg` not `wire`. See
    # procedural_names/1. Declaring them `wire` is illegal Verilog (procedural
    # assignment to a net) even if some tools tolerate it.
    reg_driven = procedural_names(design)

    case internals do
      [] -> []
      _ ->
        ["  // Internal wires" |
          Enum.map(internals, fn sig ->
            type_str = if sig.signed == :signed, do: "signed ", else: ""
            width_str = if sig.width == 1, do: "", else: "[#{sig.width - 1}:0] "
            is_kept = MapSet.member?(clock_names, sig.name) or MapSet.member?(kept, sig.name)
            keep = if is_kept, do: "  (* keep *) ", else: "  "
            decl_type = if MapSet.member?(reg_driven, sig.name), do: "reg", else: "wire"
            "#{keep}#{decl_type} #{type_str}#{width_str}#{sig.name};"
          end)
        ]
    end
  end

  # --- Memory Declarations ---

  defp emit_memory_declarations(%Design{ops: ops}) do
    mems = Enum.filter(ops, &match?(%Mem{}, &1))

    case mems do
      [] -> []
      _ ->
        decls = ["  // Memory declarations" |
          Enum.map(mems, fn %Mem{name: name, width: width, depth: depth, sync_read: sync_read} ->
            addr_bits = max(1, ceil(:math.log2(depth)) |> trunc())
            # A registered-read memory (sync_read) is meant to map to a real
            # block RAM (ECP5 DP16KD / iCE40 EBR), which is the only RAM style
            # that loads its init from the bitstream. yosys will otherwise size
            # a small memory into distributed LUT-RAM, which on ECP5 CANNOT be
            # initialized -> it reads all zeros on silicon (the desc_rom bug).
            # The `ram_style="block"` attribute forces block-RAM inference; it
            # is a matched pair with the registered-read idiom emitted by
            # Sequential.emit_memory_logic (both are required, neither alone
            # suffices). yosys's memory_libmap/memory_bram passes honor it.
            ram_style = if sync_read && sync_read != false do
              ~s{  (* ram_style = "block" *)\n}
            else
              ""
            end
            "#{ram_style}  reg [#{width - 1}:0] #{name} [0:#{depth - 1}];  // #{depth} x #{width}-bit, #{addr_bits}-bit addr"
          end)
        ]

        # Emit initialization blocks for memories with init data
        inits = mems
        |> Enum.filter(fn %Mem{init: init} -> init != nil end)
        |> Enum.flat_map(&emit_memory_init/1)

        decls ++ inits
    end
  end

  defp emit_memory_init(%Mem{name: name, width: width, init: init}) when is_list(init) do
    # Inline initialization with list of values
    lines = init
    |> Enum.with_index()
    |> Enum.map(fn {value, idx} ->
      "    #{name}[#{idx}] = #{width}'d#{value};"
    end)

    ["  initial begin"] ++ lines ++ ["  end"]
  end

  defp emit_memory_init(%Mem{name: name, init: {:file, filename}}) do
    # File-based initialization
    ["  initial $readmemh(\"#{filename}\", #{name});"]
  end

  defp emit_memory_init(%Mem{name: name, init: init}) when is_binary(init) do
    # Assume string is a filename (shorthand)
    ["  initial $readmemh(\"#{init}\", #{name});"]
  end

  # --- Initial Values ---

  defp emit_initial_values(%Design{signals: signals}) do
    signals_with_init = Enum.filter(signals, fn sig -> sig.init != nil end)

    case signals_with_init do
      [] -> []
      _ ->
        ["  // Initial values" |
          Enum.map(signals_with_init, fn sig ->
            "  initial #{sig.name} = #{sig.width}'d#{sig.init};"
          end)
        ]
    end
  end

  # --- Combinational Logic ---

  defp emit_combinational_logic(%Design{ops: ops}, _kept, casez?) do
    comb_ops = Enum.filter(ops, &is_combinational?/1)

    case comb_ops do
      [] -> []
      _ ->
        ["  // Combinational logic" |
          Enum.map(comb_ops, &Ops.emit_comb_op(&1, casez?))
        ]
    end
  end

  defp is_combinational?(%Reg{}), do: false
  defp is_combinational?(%Mem{}), do: false
  defp is_combinational?(%MemWrite{}), do: false
  defp is_combinational?(%Blackbox{}), do: false
  defp is_combinational?(%Tristate{}), do: false
  defp is_combinational?(%MemRead{clock: nil}), do: true
  defp is_combinational?(%MemRead{}), do: false
  defp is_combinational?(_), do: true
end
