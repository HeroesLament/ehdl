defmodule Hw.Analysis.Rules.MultipleDrivers do
  @moduledoc """
  Detects wires or output ports that are driven by more than one source
  at the component level.

  In synthesizable RTL, every wire must have exactly one driver. A wire
  driven by two instance outputs, or by both an instance output and a
  combinational block, produces a multi-driver conflict that synthesis
  tools handle inconsistently — some tools error, others pick one driver
  arbitrarily, and simulation may produce X.

  ## What is checked

  For each top-level component, this rule builds a map of
  `wire_name → [driver_instance, ...]` by examining the output ports of
  every instance in the port map. If any wire appears as an output
  connection in more than one instance, it is flagged.

  Note: the elaboration-time `Hw.Compile.Validate.check_single_driver/2`
  catches this at the IR level for already-elaborated designs. This rule
  operates at the **DSL metadata level** — catching the error earlier,
  with better source locations pointing at the conflicting instance
  declarations rather than the emitted IR ops.

  ## Example diagnostic

      error[E055]: wire `:pll_locked` is driven by multiple instances
        │
        │ MyTop
        │
        │   instance :pll_a, ULX3S.PLL, [..., locked: :pll_locked]
        │   instance :pll_b, ULX3S.PLL, [..., locked: :pll_locked]  ← also drives it
        │
        └─ hint: each wire may only have one driver; use separate wire names
                 or merge the two instances if they were duplicated by mistake

  ## Priority

  Runs at priority 35, before CDC analysis which depends on clean driver maps.
  """

  @behaviour Hw.Analysis.Rule

  alias Hw.Analysis.{Diagnostic, Location}

  @impl Hw.Analysis.Rule
  def priority, do: 35

  @impl Hw.Analysis.Rule
  def run(%{components: components}) do
    Enum.flat_map(components, fn comp ->
      if comp.instances != [] do
        check_component(comp, components)
      else
        []
      end
    end)
  end

  defp check_component(comp, all_components) do
    # Build: wire_name -> list of {instance_name, source_location}
    driver_map =
      comp.instances
      |> Enum.reduce(%{}, fn inst, acc ->
        child_comp = find_component(all_components, inst.module)
        output_ports = output_port_names(child_comp)
        conns = inst_conns(inst) |> Map.new()

        Enum.reduce(conns, acc, fn {port, wire}, acc2 ->
          if is_atom(wire) and port in output_ports do
            entry = {inst.name, inst[:source_location]}
            Map.update(acc2, wire, [entry], &[entry | &1])
          else
            acc2
          end
        end)
      end)

    Enum.flat_map(driver_map, fn {wire, drivers} ->
      if length(drivers) > 1 do
        [build_diagnostic(wire, drivers, comp)]
      else
        []
      end
    end)
  end

  defp build_diagnostic(wire, drivers, comp) do
    loc = drivers |> Enum.map(&elem(&1, 1)) |> Enum.find(& &1) || fallback(comp.module)
    driver_names = Enum.map(drivers, fn {name, _} -> ":#{name}" end) |> Enum.join(", ")

    related =
      drivers
      |> Enum.reject(fn {_, l} -> l == nil end)
      |> Enum.map(fn {name, location} ->
        %{location: location, message: "instance `:#{name}` drives `:#{wire}` here"}
      end)

    Diagnostic.error(
      :multiple_drivers,
      "wire `:#{wire}` on #{inspect(comp.module)} is driven by " <>
      "#{length(drivers)} instances: #{driver_names}",
      loc,
      context: %{
        wire:    wire,
        drivers: Enum.map(drivers, &elem(&1, 0)),
        module:  comp.module
      },
      related: related
    )
  end

  defp output_port_names(nil), do: MapSet.new()
  defp output_port_names(comp) do
    comp.signals
    |> Enum.filter(&(&1.direction in [:output, :inout]))
    |> MapSet.new(& &1.name)
  end

  defp find_component(components, module) do
    Enum.find(components, &(&1.module == module))
  end

  defp inst_conns(%{ports: ports}) when is_list(ports), do: ports
  defp inst_conns(%{connections: conns}) when is_list(conns), do: conns
  defp inst_conns(_), do: []

  defp fallback(module),
    do: %Location{file: "unknown", line: 0, module: module}
end
