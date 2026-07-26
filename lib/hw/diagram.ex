defmodule Hw.Diagram do
  @moduledoc """
  Wiring diagram generation for EHDL components.

  Extracts the instance graph from a component module's DSL metadata
  and emits diagram source in multiple formats. Typst/fletcher is the
  primary high-quality output; SVG and DOT are also supported.

  ## Usage

      # From a mix task:
      mix hw.diagram HelloBoard.Top

      # Programmatically:
      Hw.Diagram.typst(HelloBoard.Top) |> then(&File.write!("diagram.typ", &1))
      Hw.Diagram.dot(HelloBoard.Top)   |> then(&File.write!("diagram.dot", &1))

  ## Graph model

  The graph is extracted from pre-elaboration module attributes, preserving
  the hierarchical instance structure rather than the flat post-elaboration IR.

  Nodes:
    - Each `instance` declaration becomes a node
    - Top-level input/output ports become terminal nodes

  Edges:
    - A wire appearing as an output port of instance A and input port of
      instance B creates a directed edge A → B labeled with the wire name
    - Wires connecting to top-level ports create edges to/from port nodes

  Clock domains are inferred by the same heuristic as `CDCCrossing` —
  the wire connected to the primary clock port of each instance.
  """

  @clock_port_names [:clk, :clk_48mhz, :clk_fast, :clk_src, :clk_in, :clock, :clk_dst]

  @cdc_modules [
    Hw.CDC.Sync2,
    Hw.CDC.HandshakeSync,
    Hw.CDC.PulseSync,
    Hw.CDC.GrayCounter
  ]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Extract the graph intermediate representation from a module.

  Returns `%{nodes: [...], edges: [...], clocks: [...], module: Module}`.
  This is the shared intermediate form consumed by all emitters.
  """
  def graph(module) when is_atom(module) do
    instances  = safe_call(module, :__hw_instances__, [])
    signals    = safe_call(module, :__hw_signals__, [])
    clocks     = safe_call(module, :__hw_clocks__, [])

    # Build wire → driver map: wire_name → instance_name
    # and wire → consumers map: wire_name → [instance_name]
    {driver_map, consumer_map} = build_wire_maps(instances)

    # Assign clock domain to each instance
    domain_map = build_domain_map(instances)

    # Build node list
    nodes = build_nodes(instances, domain_map)

    # Build port nodes for top-level inputs/outputs
    port_nodes = build_port_nodes(signals)

    # Build edge list
    edges = build_edges(instances, driver_map, consumer_map, signals, module)

    %{
      module:   module,
      nodes:    nodes ++ port_nodes,
      edges:    edges,
      clocks:   clocks,
      # Order domains by first appearance in instance list (signal flow order)
      # rather than alphabetically
      domains: instances
        |> Enum.map(fn inst -> domain_map[inst.name] end)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
    }
  end

  @doc "Emit Typst/fletcher source for a module."
  def typst(module) when is_atom(module) do
    emit_typst(graph(module))
  end

  @doc "Emit Graphviz DOT source for a module."
  def dot(module) when is_atom(module) do
    emit_dot(graph(module))
  end

  @doc "Emit Mermaid flowchart source for a module."
  def mermaid(module) when is_atom(module) do
    emit_mermaid(graph(module))
  end

  # ---------------------------------------------------------------------------
  # Graph extraction
  # ---------------------------------------------------------------------------

  defp build_wire_maps(instances) do
    # Build a global output-port set from all child modules we can inspect.
    # For modules we cannot inspect, we treat every wire connection as BOTH
    # a potential driver and consumer — edges will be built from whichever
    # side we can confirm.
    child_output_ports = build_child_output_ports(instances)

    Enum.reduce(instances, {%{}, %{}}, fn inst, {drivers, consumers} ->
      conns = inst_conns(inst) |> Map.new()

      Enum.reduce(conns, {drivers, consumers}, fn {port, wire}, {d, c} ->
        if is_atom(wire) and not is_integer(wire) do
          direction = infer_port_direction(inst.module, port, child_output_ports)
          case direction do
            :output ->
              {Map.put_new(d, wire, {inst.name, port}), c}
            :input ->
              existing = Map.get(c, wire, [])
              {d, Map.put(c, wire, [{inst.name, port} | existing])}
            _ ->
              # Unknown: treat as consumer (most ports are inputs)
              existing = Map.get(c, wire, [])
              {d, Map.put(c, wire, [{inst.name, port} | existing])}
          end
        else
          {d, c}
        end
      end)
    end)
  end

  defp build_child_output_ports(instances) do
    Enum.reduce(instances, MapSet.new(), fn inst, acc ->
      if (Code.ensure_loaded?(inst.module) and function_exported?(inst.module, :__hw_signals__, 0)) do
        inst.module.__hw_signals__()
        |> Enum.filter(&(&1.direction == :output))
        |> Enum.reduce(acc, fn sig, a -> MapSet.put(a, {inst.module, sig.name}) end)
      else
        acc
      end
    end)
  end

  defp infer_port_direction(module, port, child_output_ports) do
    cond do
      # Clock and reset ports are always inputs
      port in @clock_port_names -> :input
      port in [:rst, :reset, :areset] -> :input

      # Check module metadata if available
      (Code.ensure_loaded?(module) and function_exported?(module, :__hw_signals__, 0)) ->
        module.__hw_signals__()
        |> Enum.find(&(&1.name == port))
        |> case do
          nil -> :input  # default to input if not found
          sig -> sig.direction
        end

      # Check our prebuilt output port set
      MapSet.member?(child_output_ports, {module, port}) -> :output

      # Common output naming patterns
      String.starts_with?(to_string(port), "rx_") -> :output
      String.starts_with?(to_string(port), "tx_") -> :input
      String.ends_with?(to_string(port), "_out") -> :output
      String.ends_with?(to_string(port), "_out0") -> :output
      String.ends_with?(to_string(port), "_out1") -> :output
      String.ends_with?(to_string(port), "_out2") -> :output
      String.ends_with?(to_string(port), "_valid") -> :output
      String.ends_with?(to_string(port), "_ready") -> :input
      String.ends_with?(to_string(port), "_data") -> :output
      String.ends_with?(to_string(port), "_active") -> :output
      String.ends_with?(to_string(port), "_locked") -> :output
      port == :locked -> :output
      port == :txd -> :output
      port == :rxd -> :input

      true -> :input
    end
  end

  defp build_domain_map(instances) do
    Map.new(instances, fn inst ->
      conns = inst_conns(inst) |> Map.new()
      clock =
        if inst.module in @cdc_modules do
          Map.get(conns, :clk_dst) || Map.get(conns, :clk)
        else
          Enum.find_value(@clock_port_names, &Map.get(conns, &1))
        end
      {inst.name, clock}
    end)
  end

  defp build_nodes(instances, domain_map) do
    child_output_ports = build_child_output_ports(instances)

    Enum.map(instances, fn inst ->
      short_name = inst.module |> Module.split() |> Enum.take(-2) |> Enum.join(".")
      conns = inst_conns(inst)

      # Split port connections into inputs and outputs, skip clocks/reset/underscore
      skip = MapSet.new(@clock_port_names ++ [:rst, :reset, :areset])
      {inputs, outputs} = conns
        |> Enum.filter(fn {port, wire} ->
          is_atom(wire) and not is_integer(wire) and
          not MapSet.member?(skip, port) and
          not (wire |> Atom.to_string() |> String.starts_with?("_"))
        end)
        |> Enum.split_with(fn {port, _wire} ->
          infer_port_direction(inst.module, port, child_output_ports) == :input
        end)

      %{
        id:      inst.name,
        label:   Atom.to_string(inst.name),
        module:  short_name,
        domain:  Map.get(domain_map, inst.name),
        kind:    node_kind(inst.module),
        inputs:  Enum.map(inputs,  fn {_port, wire} -> Atom.to_string(wire) end) |> Enum.uniq(),
        outputs: Enum.map(outputs, fn {_port, wire} -> Atom.to_string(wire) end) |> Enum.uniq(),
        source_location: inst[:source_location]
      }
    end)
  end

  defp build_port_nodes(signals) do
    signals
    |> Enum.filter(&(&1.direction in [:input, :output]))
    |> Enum.reject(&(Atom.to_string(&1.name) |> String.starts_with?("_")))
    |> Enum.map(fn sig ->
      %{
        id:     sig.name,
        label:  Atom.to_string(sig.name),
        module: "#{sig.direction} [#{sig.width}]",
        domain: nil,
        kind:   :port,
        source_location: sig[:source_location]
      }
    end)
  end

  defp build_edges(instances, driver_map, consumer_map, top_signals, module) do
    # Collect all wires that appear in port maps
    all_wires =
      instances
      |> Enum.flat_map(fn inst ->
        inst_conns(inst) |> Enum.map(fn {_, wire} -> wire end)
      end)
      |> Enum.filter(&is_atom/1)
      |> Enum.uniq()

    # Top-level port sets
    top_inputs  = top_signals |> Enum.filter(&(&1.direction == :input))  |> MapSet.new(& &1.name)
    top_outputs = top_signals |> Enum.filter(&(&1.direction == :output)) |> MapSet.new(& &1.name)

    # Filter out clock and reset wires — these are shown via domain grouping,
    # not as individual edges. They add visual noise without information.
    clock_names = MapSet.new(safe_call(module, :__hw_clocks__, []), & &1.name)
    signal_wires = Enum.reject(all_wires, fn wire ->
      MapSet.member?(clock_names, wire) or wire in [:rst, :reset, :pll_locked]
    end)

    Enum.flat_map(signal_wires, fn wire ->
      driver    = Map.get(driver_map, wire)
      consumers = Map.get(consumer_map, wire, [])

      # Source: instance driver OR top-level input port
      sources =
        case driver do
          {inst_name, _port} -> [inst_name]
          nil ->
            if MapSet.member?(top_inputs, wire), do: [wire], else: []
        end

      # Sinks: instance consumers PLUS top-level output port if wire matches
      instance_sinks = Enum.map(consumers, fn {inst_name, _port} -> inst_name end)
      port_sinks = if MapSet.member?(top_outputs, wire), do: [wire], else: []
      sinks = (instance_sinks ++ port_sinks) |> Enum.uniq()

      for source <- sources, sink <- sinks, source != sink do
        %{from: source, to: sink, label: Atom.to_string(wire), wire: wire}
      end
    end)
    |> Enum.uniq_by(&{&1.from, &1.to, &1.wire})
  end

  defp node_kind(module) do
    cond do
      module in @cdc_modules -> :cdc
      module |> Module.split() |> List.last() |> String.contains?("PLL") -> :pll
      true -> :component
    end
  end

  # ---------------------------------------------------------------------------
  # Typst / fletcher emitter — Graphviz-assisted layout
  #
  # Pipeline:
  #   1. emit_dot -> dot -Txdot -> parse node pos="x,y"
  #   2. Convert Graphviz points to fletcher absolute pt coordinates
  #   3. emit typst with node((Xpt, Ypt), ...) absolute positions
  # ---------------------------------------------------------------------------

  defp emit_typst(graph) do
    module_name = graph.module |> Module.split() |> Enum.join(".")
    nodes = graph.nodes
    edges = graph.edges

    # Step 1: run DOT layout to get real x,y positions
    dot_src = emit_dot(graph)
    positions = case layout_via_graphviz(dot_src) do
      {:ok, pos_map} -> pos_map
      {:error, reason} ->
        IO.warn("Graphviz layout failed (#{reason}), using grid fallback")
        fallback_positions(nodes)
    end

    # Only keep edges where both endpoints have graphviz positions
    placed = MapSet.new(Map.keys(positions))
    deduped_edges =
      edges
      |> dedup_edges()
      |> Enum.filter(fn %{from: from, to: to} ->
        MapSet.member?(placed, from) and MapSet.member?(placed, to)
      end)

    lines = [
      "#import \"@preview/fletcher:0.5.8\" as fletcher: diagram, node, edge",
      "",
      "#set page(width: auto, height: auto, margin: 10mm)",
      "#set text(size: 9pt)",
      "",
      "// Wiring diagram for " <> module_name,
      "// Generated by mix hw.diagram",
      "// Layout: Graphviz dot  Rendering: Typst / fletcher",
      "",
      "#diagram(",
      "  node-stroke: 0.5pt,",
      "  node-corner-radius: 2pt,",
      "  edge-stroke: 0.4pt,",
      "  label-size: 7pt,",
      "",
      emit_typst_nodes(nodes, positions),
      emit_domain_groups(graph, %{}, positions),
      emit_typst_edges(deduped_edges),
      ")"
    ]

    Enum.join(lines, "\n")
  end

  # Run dot -Txdot and extract node positions.
  # Returns {:ok, %{atom => {x_float, y_float}}} in pt, Y flipped to top-down.
  defp layout_via_graphviz(dot_src) do
    case System.find_executable("dot") do
      nil -> {:error, "dot not on PATH"}
      dot_bin ->
        tmp = Path.join(System.tmp_dir!(), "hw_diag_#{:erlang.unique_integer([:positive])}.dot")
        File.write!(tmp, dot_src)
        result = System.cmd(dot_bin, ["-Txdot", tmp], stderr_to_stdout: true)
        File.rm(tmp)
        case result do
          {output, 0} -> {:ok, parse_xdot_positions(output)}
          {err, _code} -> {:error, String.slice(err, 0, 200)}
        end
    end
  end

  defp parse_xdot_positions(xdot) do
    bb_height = case Regex.run(~r/bb="[0-9.]+,[0-9.]+,[0-9.]+,([0-9.]+)"/, xdot) do
      [_, h] -> parse_float(h)
      _      -> 500.0
    end

    # Match: identifier [... pos="x,y" ...]
    # Handles both quoted and unquoted node names
    ~r/\t"?([A-Za-z][A-Za-z0-9_]*)"?\s*\[(?:[^\]]*)pos="([0-9.]+),([0-9.]+)"/
    |> Regex.scan(xdot)
    |> Enum.reduce(%{}, fn [_, name, xs, ys], acc ->
      x = parse_float(xs)
      y = bb_height - parse_float(ys)
      Map.put(acc, String.to_atom(name), {Float.round(x, 1), Float.round(y, 1)})
    end)
  end

  defp parse_float(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error  -> 0.0
    end
  end

  defp fallback_positions(nodes) do
    nodes
    |> Enum.with_index()
    |> Map.new(fn {node, i} ->
      {node.id, {rem(i, 5) * 100.0, div(i, 5) * 70.0}}
    end)
  end

  defp emit_domain_groups(%{domains: domains, nodes: nodes}, _domain_row, _node_positions) do
    domain_colors = %{
      0 => "teal.lighten(80%)",
      1 => "blue.lighten(85%)",
      2 => "eastern.lighten(85%)",
      3 => "purple.lighten(85%)",
      4 => "green.lighten(85%)"
    }

    domains
    |> Enum.with_index()
    |> Enum.map(fn {domain, idx} ->
      domain_nodes = Enum.filter(nodes, &(&1.domain == domain))
      if domain_nodes == [] do
        ""
      else
        name_refs = domain_nodes
          |> Enum.reject(&(&1.kind == :port))
          |> Enum.map(fn n -> "<" <> typst_name(n.id) <> ">" end)
        color = Map.get(domain_colors, rem(idx, map_size(domain_colors)), "gray.lighten(85%)")
        enclose_str = Enum.join(name_refs, ", ")
        domain_str = to_string(domain)
        "  node(\n" <>
        "    enclose: (" <> enclose_str <> ",),\n" <>
        "    [#text(size: 7pt, fill: gray.darken(20%))[" <> domain_str <> "]],\n" <>
        "    stroke: gray.lighten(40%) + 0.4pt,\n" <>
        "    fill: " <> color <> ",\n" <>
        "    corner-radius: 4pt,\n" <>
        "  ),"
      end
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp emit_typst_nodes(nodes, node_positions) do
    node_fills = %{
      component: "white",
      cdc:       "orange.lighten(70%)",
      pll:       "purple.lighten(75%)",
      port:      "gray.lighten(70%)"
    }

    nodes
    |> Enum.reject(fn node ->
      node.kind == :port and not Map.has_key?(node_positions, node.id)
    end)
    |> Enum.map(fn node ->
      {x, y} = Map.get(node_positions, node.id, {0.0, 0.0})
      fill     = Map.get(node_fills, node.kind, "white")
      name_str = typst_name(node.id)
      x_str    = to_string(x) <> "pt"
      y_str    = to_string(y) <> "pt"

      label = case node.kind do
        :port ->
          # Port nodes: simple label
          "[*" <> node.label <> "* \\\\ #text(size: 7pt)[" <> node.module <> "]]"

        _ ->
          # Instance nodes: two-column port table
          inputs  = Map.get(node, :inputs,  [])
          outputs = Map.get(node, :outputs, [])
          n_rows  = max(max(length(inputs), length(outputs)), 1)

          # Build table rows — pad shorter column with empty strings
          rows = for i <- 0..(n_rows - 1) do
            inp = Enum.at(inputs,  i, "")
            out = Enum.at(outputs, i, "")
            inp_cell = if inp == "", do: "[]",
              else: "[#text(size: 5.5pt, fill: gray.darken(10%))[" <> inp <> " →]]"
            out_cell = if out == "", do: "[]",
              else: "[#align(right)[#text(size: 5.5pt, fill: gray.darken(10%))[← " <> out <> "]]]"
            "        " <> inp_cell <> ", " <> out_cell <> ","
          end

          "[" <>
          "#grid(\n" <>
          "        columns: (1fr, 1fr),\n" <>
          "        gutter: 1pt,\n" <>
          "        [#text(size: 8pt, weight: 600)[" <> node.label <> "]], " <>
          "[#align(right)[#text(size: 7pt, fill: gray.darken(30%))[" <> node.module <> "]]],\n" <>
          Enum.join(rows, "\n") <> "\n" <>
          "      )" <>
          "]"
      end

      "  node(\n" <>
      "    (" <> x_str <> ", " <> y_str <> "),\n" <>
      "    " <> label <> ",\n" <>
      "    name: <" <> name_str <> ">,\n" <>
      "    fill: " <> fill <> ",\n" <>
      "    stroke: 0.5pt,\n" <>
      "    corner-radius: 2pt,\n" <>
      "    inset: 5pt,\n" <>
      "    width: 90pt,\n" <>
      "  ),"
    end)
    |> Enum.join("\n")
  end

  defp emit_typst_edges(edges) do
    edges
    |> Enum.map(fn %{from: from, to: to, label: label} ->
      from_name = typst_name(from)
      to_name   = typst_name(to)
      # Truncate, strip any chars that break Typst content blocks
      label_str =
        label
        |> String.replace(["[", "]", "#"], "")
        |> then(fn s ->
          if String.length(s) > 18,
            do: String.slice(s, 0, 15) <> "..",
            else: s
        end)
      "  edge(<" <> from_name <> ">, <" <> to_name <>
      ">, text(size: 6pt, [" <> label_str <> "]), \"-|>\"),"
    end)
    |> Enum.join("\n")
  end

  # ---------------------------------------------------------------------------
  # DOT emitter
  # ---------------------------------------------------------------------------

  defp emit_dot(%{module: module, nodes: nodes, edges: edges, domains: domains}) do
    module_name  = module |> Module.split() |> Enum.join("_") |> String.downcase()
    module_label = module |> Module.split() |> Enum.join(".")
    domain_nodes = Enum.group_by(nodes, & &1.domain)

    node_fill = fn kind -> case kind do
      :cdc  -> "#fff3cd"
      :pll  -> "#e8d5f5"
      :port -> "#e2e3e5"
      _     -> "white"
    end end

    clusters =
      domains
      |> Enum.with_index()
      |> Enum.map(fn {domain, idx} ->
        domain_ns = Enum.filter(Map.get(domain_nodes, domain, []), &(&1.kind != :port))
        if domain_ns == [] do
          nil
        else
          node_lines = Enum.map(domain_ns, fn n ->
            fill    = node_fill.(n.kind)
            id      = Atom.to_string(n.id)
            label   = n.label <> "\\n" <> n.module
            n_ports = max(length(Map.get(n, :inputs, [])), length(Map.get(n, :outputs, [])))
            h_in    = Float.round(0.2 + n_ports * 0.13 + 0.1, 2)
            "    " <> inspect(id) <> " [label=" <> inspect(label) <>
            " fillcolor=" <> inspect(fill) <>
            " style=filled shape=box width=1.5 height=" <> to_string(h_in) <> "];"
          end)
          "  subgraph cluster_" <> to_string(idx) <> " {\n" <>
          "    label=" <> "\"" <> to_string(domain) <> "\"" <> ";\n" <>
          "    style=filled;\n" <>
          "    color=\"#cccccc\";\n" <>
          "    fillcolor=\"#f8f9fa\";\n" <>
          Enum.join(node_lines, "\n") <> "\n" <>
          "  }"
        end
      end)
      |> Enum.reject(&is_nil/1)

    port_lines =
      Enum.filter(nodes, &(&1.kind == :port))
      |> Enum.map(fn n ->
        shape = if String.contains?(n.module, "input"), do: "invtriangle", else: "triangle"
        id    = Atom.to_string(n.id)
        label = n.label <> "\\n" <> n.module
        "  " <> inspect(id) <> " [label=" <> inspect(label) <>
        " fillcolor=\"#dee2e6\" style=filled shape=" <> shape <> "];"
      end)

    edge_lines =
      edges
      |> dedup_edges()
      |> Enum.map(fn %{from: from, to: to, label: label} ->
        truncated = String.slice(label, 0, 24)
        "  " <> inspect(Atom.to_string(from)) <> " -> " <>
        inspect(Atom.to_string(to)) <> " [label=" <> inspect(truncated) <> " fontsize=8];"
      end)

    "digraph " <> module_name <> " {\n" <>
    "  rankdir=TB;\n" <>
    "  node [fontname=\"sans-serif\" fontsize=9 fixedsize=true];\n" <>
    "  edge [fontname=\"sans-serif\" fontsize=8];\n" <>
    "  graph [fontname=\"sans-serif\" label=" <> inspect(module_label) <> " labelloc=t];\n\n" <>
    Enum.join(clusters, "\n") <> "\n\n" <>
    Enum.join(port_lines, "\n") <> "\n\n" <>
    Enum.join(edge_lines, "\n") <> "\n}\n"
  end

  # ---------------------------------------------------------------------------
  # Mermaid emitter
  # ---------------------------------------------------------------------------

  defp emit_mermaid(%{module: module, nodes: nodes, edges: edges}) do
    module_name = module |> Module.split() |> Enum.join(".")

    node_lines = Enum.map(nodes, fn n ->
      shape = case n.kind do
        :port -> "([#{n.label}])"
        :cdc  -> "{{#{n.label}}}"
        _     -> "[#{n.label}<br/><small>#{n.module}</small>]"
      end
      "  #{mermaid_id(n.id)}#{shape}"
    end)

    edge_lines =
      edges
      |> dedup_edges()
      |> Enum.map(fn %{from: from, to: to, label: label} ->
        "  #{mermaid_id(from)} -->|#{String.slice(label, 0, 20)}| #{mermaid_id(to)}"
      end)

    """
    ---
    title: #{module_name}
    ---
    flowchart LR
    #{Enum.join(node_lines, "\n")}
    #{Enum.join(edge_lines, "\n")}
    """
  end

  # ---------------------------------------------------------------------------
  # Layout helpers
  # ---------------------------------------------------------------------------

  # Simple topological column assignment via BFS from port nodes
  defp dedup_edges(edges) do
    edges
    |> Enum.group_by(&{&1.from, &1.to})
    |> Enum.map(fn {{from, to}, group} ->
      labels = group |> Enum.map(& &1.label) |> Enum.sort() |> Enum.join(", ")
      %{from: from, to: to, label: labels, wire: hd(group).wire}
    end)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp inst_conns(%{ports: ports}) when is_list(ports), do: ports
  defp inst_conns(%{connections: conns}) when is_list(conns), do: conns
  defp inst_conns(_), do: []

  defp safe_call(module, fun, default) do
    if (Code.ensure_loaded?(module) and function_exported?(module, fun, 0)), do: apply(module, fun, []), else: default
  end

  # Fletcher uses <label> syntax for named node references
  # Labels must be valid identifiers — replace special chars
  defp typst_name(atom) when is_atom(atom) do
    atom |> Atom.to_string() |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
  end

  defp mermaid_id(atom) when is_atom(atom) do
    atom |> Atom.to_string() |> String.replace(~r/[^a-zA-Z0-9]/, "_")
  end
end
