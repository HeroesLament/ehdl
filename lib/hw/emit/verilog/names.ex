defmodule Hw.Emit.Verilog.Names do
  @moduledoc """
  Keep emitted identifiers legal Verilog.

  EHDL names come from Elixir atoms, so nothing stops a design from calling a
  net or memory `buf`, `wire`, `logic`, `table`... all Verilog or
  SystemVerilog keywords. Yosys' default front end tolerates some of them;
  iverilog and Verilator reject them (found 2026-09-24: Hw.StreamBRAMFIFO's
  memory `buf`, a gate primitive).

  `legalize/1` runs once on the finalized design, before any rendering:

    * internal nets and memories with a reserved name are renamed to
      `<name>_r` (more underscores until unique), everywhere they appear;
    * a PORT named after a Verilog-2005 keyword raises: renaming it would
      silently change the module interface every instantiator and constraint
      file depends on. SystemVerilog-only keywords (`ref`, `logic`, ...) are
      legal Verilog-2005 port names and pass through; the emitter targets
      Verilog-2005 (the PLL/MMCM test tops use a `ref` input).
  """

  alias Hw.IR.Design
  alias Hw.IR.Types.Signal
  alias Hw.IR.Ops.{Mem, MemRead, MemWrite}

  # IEEE 1364-2005 keywords plus IEEE 1800-2017 additions, so the output also
  # parses as SystemVerilog (iverilog -g2012, Verilator, yosys -sv).
  @v2005 ~w(
    always and assign automatic begin buf bufif0 bufif1 case casex casez cell
    cmos config deassign default defparam design disable edge else end endcase
    endconfig endfunction endgenerate endmodule endprimitive endspecify
    endtable endtask event for force forever fork function generate genvar
    highz0 highz1 if ifnone incdir include initial inout input instance join
    large liblist library localparam macromodule medium module nand negedge
    nmos nor noshowcancelled not notif0 notif1 or output parameter pmos
    posedge primitive pull0 pull1 pulldown pullup pulsestyle_onevent
    pulsestyle_ondetect rcmos real realtime reg release repeat rnmos rpmos
    rtran rtranif0 rtranif1 scalared showcancelled signed small specify
    specparam strong0 strong1 supply0 supply1 table task time tran tranif0
    tranif1 tri tri0 tri1 triand trior trireg unsigned use uwire vectored wait
    wand weak0 weak1 while wire wor xnor xor
  ) |> MapSet.new()

  @sv_only ~w(
    accept_on alias always_comb always_ff always_latch assert assume before
    bind bins binsof bit break byte chandle checker class clocking const
    constraint context continue cover covergroup coverpoint cross dist do
    endchecker endclass endclocking endgroup endinterface endpackage
    endprogram endproperty endsequence enum eventually expect export extends
    extern final first_match foreach forkjoin global iff ignore_bins
    illegal_bins implements implies import inside int interconnect interface
    intersect join_any join_none let local logic longint matches modport new
    nexttime null package packed priority program property protected pure
    rand randc randcase randsequence ref reject_on restrict return s_always
    s_eventually s_nexttime s_until s_until_with sequence shortint shortreal
    soft solve static string strong struct super sync_accept_on
    sync_reject_on tagged this throughout timeprecision timeunit type typedef
    union unique unique0 until until_with untyped var virtual void
    wait_order weak wildcard with within
  ) |> MapSet.new()

  @reserved MapSet.union(@v2005, @sv_only)

  @doc "True if `name` (atom or string) is a Verilog/SystemVerilog keyword."
  def reserved?(name) when is_atom(name), do: reserved?(Atom.to_string(name))
  def reserved?(name) when is_binary(name), do: MapSet.member?(@reserved, name)

  @doc """
  Rename reserved internal identifiers; raise on reserved port names;
  deduplicate localparams.
  """
  def legalize(%Design{} = design) do
    design
    |> dedupe_localparams()
    |> legalize_names()
  end

  # FSM state localparams are emitted into the one flattened module, so two
  # FSMs (or two instances of one component with an FSM) each contribute
  # `IDLE`, `SEND_ADDR`, ... into the same scope: illegal redeclaration
  # (found 2026-09-26, Hw.AXIHPReader + Hw.AXIHPWriter in one top). They
  # are documentation only: the elaborator inlines state values into the
  # FSM logic, and emit_localparams/1 is their sole consumer. So exact
  # duplicates collapse to one, and a same-name/different-value collision
  # is renamed <NAME>_2, _3, ... rather than dropped.
  defp dedupe_localparams(%Design{localparams: lps} = design) do
    {kept, _seen} =
      Enum.reduce(lps, {[], %{}}, fn lp, {acc, seen} ->
        case Map.get(seen, lp.name) do
          nil ->
            {[lp | acc], Map.put(seen, lp.name, [{lp.value, lp.width}])}

          variants ->
            if {lp.value, lp.width} in variants do
              {acc, seen}
            else
              n = length(variants) + 1
              renamed = %{lp | name: String.to_atom("#{lp.name}_#{n}")}
              {[renamed | acc], Map.put(seen, lp.name, variants ++ [{lp.value, lp.width}])}
            end
        end
      end)

    %{design | localparams: Enum.reverse(kept)}
  end

  defp legalize_names(%Design{} = design) do
    ports =
      for %Signal{direction: d, name: n} <- design.signals,
          d in [:input, :output, :inout],
          MapSet.member?(@v2005, Atom.to_string(n)),
          do: {d, n}

    if ports != [] do
      raise ArgumentError,
            "#{inspect(design.name)}: port name(s) are Verilog keywords: " <>
              Enum.map_join(ports, ", ", fn {d, n} -> "#{d} #{n}" end) <>
              ". Rename them in the design; ports are never renamed silently."
    end

    taken = all_names(design)

    candidates =
      (for(%Signal{name: n, direction: :internal} <- design.signals, do: n) ++
         for(%Mem{name: n} <- design.ops, do: n))
      |> Enum.filter(&reserved?/1)
      |> Enum.uniq()

    case candidates do
      [] ->
        design

      _ ->
        {map, _} =
          Enum.reduce(candidates, {%{}, taken}, fn n, {m, t} ->
            new = fresh(n, t)
            {Map.put(m, n, new), MapSet.put(t, new)}
          end)

        rename(design, map)
    end
  end

  defp fresh(name, taken, suffix \\ "_r") do
    new = String.to_atom("#{name}#{suffix}")
    if MapSet.member?(taken, new), do: fresh(name, taken, suffix <> "_"), else: new
  end

  defp all_names(%Design{} = d) do
    sigs = for %Signal{name: n} <- d.signals, do: n
    mems = for %Mem{name: n} <- d.ops, do: n
    MapSet.new(sigs ++ mems ++ collect_signal_names(d.ops, []))
  end

  defp collect_signal_names(%Signal{name: n}, acc), do: [n | acc]

  defp collect_signal_names(%_{} = s, acc),
    do: s |> Map.from_struct() |> Map.values() |> collect_signal_names(acc)

  defp collect_signal_names(l, acc) when is_list(l),
    do: Enum.reduce(l, acc, &collect_signal_names/2)

  defp collect_signal_names(t, acc) when is_tuple(t),
    do: t |> Tuple.to_list() |> collect_signal_names(acc)

  defp collect_signal_names(m, acc) when is_map(m),
    do: m |> Map.values() |> collect_signal_names(acc)

  defp collect_signal_names(_, acc), do: acc

  # Deep, structure-preserving rename. Only Signal names and memory names are
  # touched; map KEYS (e.g. blackbox port names) are left alone on purpose.
  defp rename(%Signal{name: n} = s, map), do: %{s | name: Map.get(map, n, n)}
  defp rename(%Mem{name: n} = m, map), do: %{m | name: Map.get(map, n, n)}

  defp rename(%MemRead{memory: mem} = r, map),
    do: %{rename_fields(r, map, [:memory]) | memory: rename_mem_ref(mem, map)}

  defp rename(%MemWrite{memory: mem} = w, map),
    do: %{rename_fields(w, map, [:memory]) | memory: rename_mem_ref(mem, map)}

  defp rename(%_{} = s, map), do: rename_fields(s, map, [])
  defp rename(l, map) when is_list(l), do: Enum.map(l, &rename(&1, map))

  defp rename(t, map) when is_tuple(t),
    do: t |> Tuple.to_list() |> rename(map) |> List.to_tuple()

  defp rename(m, map) when is_map(m), do: Map.new(m, fn {k, v} -> {k, rename(v, map)} end)
  defp rename(x, _map), do: x

  defp rename_fields(%mod{} = s, map, skip) do
    s
    |> Map.from_struct()
    |> Map.new(fn {k, v} -> if k in skip, do: {k, v}, else: {k, rename(v, map)} end)
    |> then(&struct(mod, &1))
  end

  defp rename_mem_ref(name, map) when is_atom(name), do: Map.get(map, name, name)
  defp rename_mem_ref(other, map), do: rename(other, map)
end
