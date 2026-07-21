defmodule Hw.Analysis.Rules.CDCCrossing do
  @moduledoc """
  Detects signals that cross clock domain boundaries without a CDC
  synchronizer primitive.

  A crossing is flagged when a wire is driven by an instance running in
  clock domain X and consumed by an instance running in clock domain Y,
  and no `Hw.CDC.*` instance exists on that wire between them.

  ## Clock domain inference

  Each instance's clock domain is determined by the wire connected to its
  primary clock port. For CDC primitives, the destination domain is taken
  from the `clk_dst` port.

  ## Known safe CDC primitives

    - `Hw.CDC.Sync2`          — two-flop synchronizer
    - `Hw.CDC.HandshakeSync`  — req/ack handshake crossing
    - `Hw.CDC.PulseSync`      — single-cycle pulse crossing
    - `Hw.CDC.GrayCounter`    — gray-coded counter crossing

  ## Example diagnostic

      error[E040]: clock domain crossing without synchronization
        │
        │ HelloBoard.Top
        │
        │  ep_out_pkt_end: SIE (clk_fast) → CDCSerial (clk_48)
        │
        └─ note: `ep_out_pkt_end` is a single-cycle pulse in clk_fast (~4.6ns)
                 and will be missed by clk_48 (20.8ns period) ~78% of the time
        └─ hint: instance :sync_ep_out_pkt_end, Hw.CDC.Sync2,
                   clk_dst: :clk_48, rst: :rst,
                   data_in: :ep_out_pkt_end, data_out: :ep_out_pkt_end_sync
  """

  @behaviour Hw.Analysis.Rule

  # Dialyzer false positive: keyword list containing a map value doesn't
  # unify with :elixir.keyword() in strict mode, but is valid at runtime.
  @dialyzer {:nowarn_function, build_diagnostic: 6}

  alias Hw.Analysis.Diagnostic

  # CDC primitives whose outputs are safe to use in any domain
  @cdc_modules [
    Hw.CDC.Sync2,
    Hw.CDC.HandshakeSync,
    Hw.CDC.PulseSync,
    Hw.CDC.GrayCounter
  ]

  # Clock port names to check for domain inference
  @clock_port_names [:clk, :clk_48mhz, :clk_fast, :clk_src, :clk_in, :clock]

  @impl Hw.Analysis.Rule
  def priority, do: 40

  @impl Hw.Analysis.Rule
  def run(%{components: components}) do
    # Focus on top-level components that have instances (i.e. top.ex)
    Enum.flat_map(components, fn comp ->
      if comp.instances != [] do
        check_component(comp, components)
      else
        []
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Per-component check
  # ---------------------------------------------------------------------------

  defp check_component(top, all_components) do
    instances = top.instances

    # Build clock domain map: instance_name -> clock_wire_name
    domain_map = build_domain_map(instances)

    # Build CDC-safe wire set: wires that are outputs of CDC primitives
    cdc_safe = build_cdc_safe_set(instances)

    # Build driver map: wire_name -> {instance_name, clock_domain}
    driver_map = build_driver_map(instances, domain_map, all_components)

    # Build consumer map: wire_name -> [{instance_name, clock_domain}]
    consumer_map = build_consumer_map(instances, domain_map, all_components)

    # Find all wires and check each for unsafe crossings
    all_wires = Map.keys(driver_map) ++ Map.keys(consumer_map)
    |> Enum.uniq()

    Enum.flat_map(all_wires, fn wire ->
      check_wire(wire, driver_map, consumer_map, cdc_safe, top.module)
    end)
  end

  defp check_wire(wire, driver_map, consumer_map, cdc_safe, top_module) do
    driver   = Map.get(driver_map, wire)
    consumers = Map.get(consumer_map, wire, [])

    if driver == nil or consumers == [] do
      []
    else
      {driver_inst, driver_clock} = driver

      Enum.flat_map(consumers, fn {consumer_inst, consumer_clock} ->
        cond do
          driver_clock == nil or consumer_clock == nil ->
            []

          driver_clock == consumer_clock ->
            []

          MapSet.member?(cdc_safe, wire) ->
            []

          true ->
            [build_diagnostic(
              wire, driver_inst, driver_clock,
              consumer_inst, consumer_clock, top_module
            )]
        end
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Build diagnostic
  # ---------------------------------------------------------------------------

  defp build_diagnostic(wire, driver_inst, driver_clock, consumer_inst, consumer_clock, top_module) do
    loc  = %Hw.Analysis.Location{file: "unknown", line: 0, module: top_module}
    ctx  = %{
      signal:         wire,
      driver:         driver_inst,
      driver_clock:   driver_clock,
      consumer:       consumer_inst,
      consumer_clock: consumer_clock,
      hint:           pulse_hint(wire, consumer_clock)
    }
    opts = [context: ctx]
    Diagnostic.error(:clock_domain_crossing,
      "signal `#{wire}` crosses clock domains without synchronization: " <>
      "`#{driver_inst}` (#{driver_clock}) → `#{consumer_inst}` (#{consumer_clock})",
      loc, opts)
  end

  defp pulse_hint(wire, consumer_clock) do
    "add a synchronizer in top.ex:\n" <>
    "    instance :sync_#{wire}, Hw.CDC.Sync2,\n" <>
    "      clk_dst:  :#{consumer_clock},\n" <>
    "      rst:      :rst,\n" <>
    "      data_in:  :#{wire},\n" <>
    "      data_out: :#{wire}_sync\n" <>
    "  then use `:#{wire}_sync` in the #{consumer_clock} domain"
  end

  # ---------------------------------------------------------------------------
  # Domain map: instance_name -> clock_wire
  # ---------------------------------------------------------------------------

  defp build_domain_map(instances) do
    Map.new(instances, fn inst ->
      clock = infer_clock(inst)
      {inst.name, clock}
    end)
  end

  defp infer_clock(inst) do
    conns = inst_connections(inst)

    # CDC primitives: use clk_dst as the output/consumer domain
    if inst.module in @cdc_modules do
      Map.get(conns, :clk_dst) || Map.get(conns, :clk)
    else
      # Find first clock port that has a connection
      Enum.find_value(@clock_port_names, fn port ->
        Map.get(conns, port)
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # CDC-safe wire set: outputs of CDC primitives
  # ---------------------------------------------------------------------------

  defp build_cdc_safe_set(instances) do
    Enum.reduce(instances, MapSet.new(), fn inst, acc ->
      if inst.module in @cdc_modules do
        conns = inst_connections(inst)
        case Map.get(conns, :data_out) do
          nil  -> acc
          wire -> MapSet.put(acc, wire)
        end
      else
        acc
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Driver map: wire -> {instance_name, clock}
  # For each instance output port, record which wire it drives
  # ---------------------------------------------------------------------------

  defp build_driver_map(instances, domain_map, all_components) do
    Enum.reduce(instances, %{}, fn inst, acc ->
      clock = Map.get(domain_map, inst.name)
      comp  = find_component(all_components, inst.module)
      conns = inst_connections(inst)

      output_ports = if comp do
        comp.signals
        |> Enum.filter(&(&1.direction in [:output, :inout]))
        |> Enum.map(&(&1.name))
      else
        []
      end

      Enum.reduce(conns, acc, fn {port, wire}, acc2 ->
        if port in output_ports and is_atom(wire) do
          Map.put_new(acc2, wire, {inst.name, clock})
        else
          acc2
        end
      end)
    end)
  end

  # ---------------------------------------------------------------------------
  # Consumer map: wire -> [{instance_name, clock}]
  # For each instance input port, record which wire it reads
  # ---------------------------------------------------------------------------

  defp build_consumer_map(instances, domain_map, all_components) do
    Enum.reduce(instances, %{}, fn inst, acc ->
      clock = Map.get(domain_map, inst.name)
      comp  = find_component(all_components, inst.module)
      conns = inst_connections(inst)

      input_ports = if comp do
        comp.signals
        |> Enum.filter(&(&1.direction in [:input, :inout]))
        |> Enum.map(&(&1.name))
      else
        []
      end

      Enum.reduce(conns, acc, fn {port, wire}, acc2 ->
        if port in input_ports and is_atom(wire) do
          existing = Map.get(acc2, wire, [])
          Map.put(acc2, wire, [{inst.name, clock} | existing])
        else
          acc2
        end
      end)
    end)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Instance connections are stored as a keyword list or map depending on version
  defp inst_connections(%{connections: conns}) when is_list(conns) do
    Map.new(conns)
  end
  defp inst_connections(%{connections: conns}) when is_map(conns) do
    conns
  end
  defp inst_connections(%{ports: ports}) when is_list(ports) do
    Map.new(ports)
  end
  defp inst_connections(_), do: %{}

  defp find_component(components, module) do
    Enum.find(components, &(&1.module == module))
  end
end
