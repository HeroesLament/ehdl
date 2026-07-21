defmodule Hw.Analysis.Rules.ResetCoverage do
  @moduledoc """
  Warns when a component declares a reset signal but one or more of its
  instances does not connect that reset to its `rst` port.

  In a well-organized FPGA design, reset is explicit and uniform. A
  component that wires reset to most instances but forgets one is a
  common source of hard-to-reproduce bring-up failures — the forgotten
  instance starts in an undefined state that depends on FPGA power-up
  randomness and is not reproducible under simulation reset.

  ## What is checked

  For each top-level component that has a signal named `rst` or `reset`
  (output or wire), this rule checks every child instance:
  - Does the instance's module declare an input port named `rst` or `reset`?
  - If so, is that port connected in the instance port map?

  If the port exists but is unconnected, a warning is emitted.

  ## Known exceptions

  Instances of CDC primitives (`Hw.CDC.*`) and PLL modules are excluded
  — they have their own reset semantics and are commonly not driven by
  the top-level reset signal.

  ## Example diagnostic

      warning[W051]: instance `:uart_tx` has an unconnected `rst` port
        │
        │ HelloBoard.Top
        │
        │   instance :uart_tx, Hw.UART.TX, [
        │     clk: :clk_48,
        │     ...  ← no `rst:` key
        │   ]
        │
        └─ hint: add `rst: :rst` to the port map,
                 or rename to `:_rst` on the child if reset is intentionally omitted

  ## Priority

  Runs at priority 55, after undriven-output check.
  """

  @behaviour Hw.Analysis.Rule

  alias Hw.Analysis.{Diagnostic, Location}

  @impl Hw.Analysis.Rule
  def priority, do: 55

  # Modules that manage their own reset — excluded from this check
  @cdc_namespace_prefix ["Hw", "CDC"]
  @pll_namespace_prefix ["ULX3S"]
  @reset_port_names [:rst, :reset, :areset, :nreset]

  @impl Hw.Analysis.Rule
  def run(%{components: components}) do
    Enum.flat_map(components, fn comp ->
      if has_reset_signal?(comp) do
        check_component(comp, components)
      else
        []
      end
    end)
  end

  defp has_reset_signal?(comp) do
    Enum.any?(comp.signals, fn sig ->
      sig.name in @reset_port_names and sig.direction in [:output, :internal]
    end)
  end

  defp check_component(comp, all_components) do
    Enum.flat_map(comp.instances, fn inst ->
      if excluded_module?(inst.module) do
        []
      else
        check_instance_reset(inst, comp, all_components)
      end
    end)
  end

  defp check_instance_reset(inst, parent_comp, all_components) do
    child_comp = find_component(all_components, inst.module)

    child_reset_port =
      case child_comp do
        nil  -> infer_reset_port(inst)
        comp -> declared_reset_port(comp)
      end

    case child_reset_port do
      nil ->
        # Child has no reset port — nothing to check
        []

      port_name ->
        conns = inst_conns(inst)
        if Enum.any?(conns, fn {port, _wire} -> port == port_name end) do
          []
        else
          loc = inst[:source_location] || fallback(parent_comp.module)
          [Diagnostic.warning(
            :unconnected_reset,
            "instance `:#{inst.name}` (#{inspect(inst.module)}) has " <>
            "an unconnected `#{port_name}` port",
            loc,
            context: %{
              instance:   inst.name,
              module:     inst.module,
              reset_port: port_name,
              parent:     parent_comp.module
            }
          )]
        end
    end
  end

  # If we have the component metadata, look for declared reset inputs
  defp declared_reset_port(comp) do
    Enum.find_value(comp.signals, fn sig ->
      if sig.name in @reset_port_names and sig.direction == :input do
        sig.name
      end
    end)
  end

  # Heuristic: if the module is not in our metadata (e.g. blackbox or
  # external), check the port map keys for common reset names.
  defp infer_reset_port(inst) do
    conns = inst_conns(inst)
    Enum.find_value(@reset_port_names, fn name ->
      if Enum.any?(conns, fn {port, _} -> port == name end), do: name
    end)
  end

  defp excluded_module?(module) do
    parts = Module.split(module)
    List.starts_with?(parts, @cdc_namespace_prefix) or
      List.starts_with?(parts, @pll_namespace_prefix)
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
