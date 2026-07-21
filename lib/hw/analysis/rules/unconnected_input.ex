defmodule Hw.Analysis.Rules.UnconnectedInput do
  @moduledoc """
  Detects instance input ports that are left unconnected (floating) in
  the parent component's port map.

  In synthesized hardware, an unconnected input to a module is tied to
  zero by most tools — but this is implicit behavior that is easy to
  confuse with an intentional connection. Floating inputs on control
  signals (enables, modes, addresses) are almost always bugs.

  ## What is checked

  For each instance in a component, this rule compares the set of input
  ports declared by the child module against the keys present in the
  instance's port map. Any input port that:

  - Is declared on the child module
  - Does not appear as a key in the port map
  - Does not start with `_` (the EHDL convention for intentionally
    unused ports)

  ...is reported as a warning.

  Clock ports are excluded — a clock port left out of the port map is
  often intentionally inherited or mapped differently. The CDC crossing
  rule handles clock-related issues separately.

  ## Example diagnostic

      warning[W056]: input port `:rst` on instance `:uart_tx` (Hw.UART.TX)
                     is not connected
        │
        │ HelloBoard.Top
        │
        │   instance :uart_tx, Hw.UART.TX,
        │     CLK_FREQ:  48_000_000,
        │     BAUD_RATE: 115_200,
        │     clk:       :clk_48,
        │     # rst: ???   ← missing
        │     data:      :cdc_rx_data,
        │     ...
        │
        └─ hint: add `rst: :rst` to connect the active-high reset,
                 or prefix the port with `_` on the child module if
                 reset is intentionally unused

  ## Priority

  Runs at priority 52, after undriven output (50) and before reset
  coverage (55) which is a specialization of this check.
  """

  @behaviour Hw.Analysis.Rule

  alias Hw.Analysis.{Diagnostic, Location}

  @impl Hw.Analysis.Rule
  def priority, do: 52

  # Port names that are excluded — clocks, params, and conventional skips
  @clock_port_names MapSet.new([:clk, :clk_48mhz, :clk_fast, :clk_src,
                                 :clk_in, :clock, :clk_dst])

  @impl Hw.Analysis.Rule
  def run(%{components: components}) do
    Enum.flat_map(components, fn comp ->
      check_component(comp, components)
    end)
  end

  defp check_component(comp, all_components) do
    Enum.flat_map(comp.instances, fn inst ->
      child_comp = find_component(all_components, inst.module)
      if child_comp do
        check_instance(inst, child_comp, comp)
      else
        # Unknown child module — skip (UnknownInterface rule handles that)
        []
      end
    end)
  end

  defp check_instance(inst, child_comp, parent_comp) do
    connected_ports =
      inst_conns(inst)
      |> Enum.map(fn {port, _wire} -> port end)
      |> MapSet.new()

    child_input_ports =
      child_comp.signals
      |> Enum.filter(&(&1.direction == :input))
      |> Enum.reject(&clock_port?(&1.name))
      |> Enum.reject(&intentionally_unused?(&1.name))

    Enum.flat_map(child_input_ports, fn sig ->
      if MapSet.member?(connected_ports, sig.name) do
        []
      else
        loc = inst[:source_location] || fallback(parent_comp.module)
        [Diagnostic.warning(
          :unconnected_input,
          "input port `:#{sig.name}` on instance `:#{inst.name}` " <>
          "(#{inspect(inst.module)}) is not connected",
          loc,
          context: %{
            port:     sig.name,
            instance: inst.name,
            module:   inst.module,
            parent:   parent_comp.module
          },
          related: Enum.reject([
            sig[:source_location] && %{
              location: sig[:source_location],
              message:  "port `:#{sig.name}` declared here"
            }
          ], &(&1 == false or &1 == nil))
        )]
      end
    end)
  end

  defp clock_port?(name), do: MapSet.member?(@clock_port_names, name)

  defp intentionally_unused?(name) do
    name |> Atom.to_string() |> String.starts_with?("_")
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
