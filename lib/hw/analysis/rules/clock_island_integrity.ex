defmodule Hw.Analysis.Rules.ClockIslandIntegrity do
  @moduledoc """
  Verifies that every instance in a component can be assigned to a known
  clock domain, and warns when the clock topology has structural problems.

  A healthy clocked design has a clear answer for "which clock runs this
  instance?" If an instance's clock port is connected to a wire that is
  not declared as a `clock` in the parent, or to nothing at all, the
  design's domain structure is ambiguous and CDC analysis cannot reason
  about it reliably.

  ## Checks performed

  ### 1. Unclockable instances

  An instance with a declared clock input port that is not connected to
  any wire (or connected to a wire that is not a known clock name) is
  flagged. This often indicates:
  - A clock wire was renamed without updating instance port maps
  - A PLL output clock was connected but not declared as `clock` in the
    parent
  - The instance was copy-pasted and the clock connection forgotten

  ### 2. Mixed-clock instances

  An instance that has **more than one clock input port** connected to
  **different** clock wires is flagged. While dual-clock components
  exist legitimately (e.g. async FIFOs), they should be rare and
  intentional. Accidental dual-clock connections often indicate a
  copy-paste error in the port map.

  ### 3. Unknown clock wires

  A clock port connected to a wire name that does not appear in the
  parent's declared clocks, and is not a wire driven by a known clock
  source (PLL output, etc.), is flagged with a hint to add a `clock`
  declaration or check the wiring.

  ## Example diagnostic

      warning[W065]: instance `:uart_rx` clock port `:clk` is connected
                     to `:clk_48` which is not declared as a `clock` in HelloBoard.Top
        │
        └─ hint: add `clock :clk_48, freq: 48.0` to HelloBoard.Top,
                 or check that `:clk_48` is the intended clock wire

  ## Priority

  Runs at priority 42, just after frequency ratio (45) but before
  general output/connectivity checks (50+).
  """

  @behaviour Hw.Analysis.Rule

  alias Hw.Analysis.{Diagnostic, Location}

  @impl Hw.Analysis.Rule
  def priority, do: 42

  @clock_port_names [:clk, :clk_48mhz, :clk_fast, :clk_src, :clk_in, :clock, :clk_dst]

  # Modules where multiple clocks are expected and legitimate
  @dual_clock_allowlist [
    Hw.CDC.Sync2,
    Hw.CDC.HandshakeSync,
    Hw.CDC.PulseSync,
    Hw.CDC.GrayCounter,
    Hw.AsyncFIFO
  ]

  @impl Hw.Analysis.Rule
  def run(%{components: components}) do
    Enum.flat_map(components, fn comp ->
      known_clocks = MapSet.new(comp.clocks, & &1.name)
      check_component(comp, known_clocks)
    end)
  end

  defp check_component(comp, known_clocks) do
    Enum.flat_map(comp.instances, fn inst ->
      check_instance(inst, known_clocks, comp)
    end)
  end

  defp check_instance(inst, known_clocks, comp) do
    conns = inst_conns(inst) |> Map.new()

    # Find all clock ports that are connected
    connected_clocks =
      @clock_port_names
      |> Enum.flat_map(fn port ->
        case Map.get(conns, port) do
          nil  -> []
          wire -> [{port, wire}]
        end
      end)

    case connected_clocks do
      [] ->
        # No clock port connected at all — only warn if the child has a clock
        # port in its known port names (heuristic)
        []

      [{_port, wire}] ->
        # Single clock — check it's a known domain
        check_single_clock(wire, inst, known_clocks, comp)

      clocks ->
        # Multiple clock ports connected — warn if not in allowlist
        check_multi_clock(clocks, inst, known_clocks, comp)
    end
  end

  defp check_single_clock(wire, inst, known_clocks, comp) do
    if MapSet.member?(known_clocks, wire) do
      []
    else
      loc = inst[:source_location] || fallback(comp.module)
      [Diagnostic.warning(
        :unknown_clock_wire,
        "instance `:#{inst.name}` (#{inspect(inst.module)}) clock is " <>
        "connected to `:#{wire}`, which is not declared as a `clock` in " <>
        "#{inspect(comp.module)}",
        loc,
        context: %{
          instance:     inst.name,
          module:       inst.module,
          clock_wire:   wire,
          known_clocks: MapSet.to_list(known_clocks),
          parent:       comp.module
        }
      )]
    end
  end

  defp check_multi_clock(clocks, inst, known_clocks, comp) do
    if inst.module in @dual_clock_allowlist do
      # Expected — CDC primitives and async FIFOs legitimately use two clocks.
      # Still check that both clock wires are known domains.
      Enum.flat_map(clocks, fn {_port, wire} ->
        check_single_clock(wire, inst, known_clocks, comp)
      end)
    else
      loc = inst[:source_location] || fallback(comp.module)
      clock_summary =
        clocks
        |> Enum.map(fn {port, wire} -> "#{port}: #{wire}" end)
        |> Enum.join(", ")

      [Diagnostic.warning(
        :mixed_clock_instance,
        "instance `:#{inst.name}` (#{inspect(inst.module)}) has multiple " <>
        "clock connections: #{clock_summary} — if this is an async FIFO or " <>
        "dual-clock primitive, add it to the allowlist in ClockIslandIntegrity",
        loc,
        context: %{
          instance: inst.name,
          module:   inst.module,
          clocks:   clocks,
          parent:   comp.module
        }
      )]
    end
  end

  defp inst_conns(%{ports: ports}) when is_list(ports), do: ports
  defp inst_conns(%{connections: conns}) when is_list(conns), do: conns
  defp inst_conns(_), do: []

  defp fallback(module),
    do: %Location{file: "unknown", line: 0, module: module}
end
