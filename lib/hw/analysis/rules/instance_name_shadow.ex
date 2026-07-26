defmodule Hw.Analysis.Rules.InstanceNameShadow do
  @moduledoc """
  Detects a signal declared in a component that shares its name with an
  *internal* signal of one of that component's instances.

  Elaboration flattens the whole hierarchy into a single module, giving each
  child signal a `<instance>_` prefix. During that flattening the child's
  signals are also known by their unprefixed names, so a parent signal and a
  child internal signal with the same name occupy the same key.

  The elaborator resolves this in the parent's favour — the parent's `foo` is
  its own `foo`, and the child's becomes `inst_foo` — so this is a **warning,
  not an error**. Nothing is miscompiled. But two different wires sharing one
  source-level name is genuinely confusing to read, and it used to be a silent
  miscompilation, so it is worth surfacing.

  ## Why this rule exists

  Before the scope fix, the child's names were merged *over* the parent's and
  handed back to the enclosing scope. A parent signal whose name collided with
  any instance's internal signal would then resolve to the child's wire. It
  announced itself as a confusing "multiple drivers" error when the parent also
  wrote the name — and not at all when the parent's wire was driven by a
  different instance's output port, in which case the design simply came out
  wrong.

  Two collisions of the first kind were hit while writing the CAN controller
  (`bit_in` against `Hw.CAN.CRC15`'s port, `gap_cnt` against
  `Hw.Diag.SerialReport`'s internal counter). Both cost real debugging time. The
  scope is fixed now; this rule means nobody has to rediscover the shape of the
  problem to know a name is doing double duty.

  ## What is checked

  For each instance, every child signal that is

    * declared on the child module, and
    * **not** connected through the instance's port map, and
    * named the same as a signal declared on the parent

  ...is reported. Signals that appear in the port map are excluded: a child port
  `clk` wired to the parent's `clk` is the normal, intended aliasing, not a
  shadow.

  ## Example diagnostic

      warning: instance `:report` (Hw.Diag.SerialReport) has an internal signal
               `gap_cnt` with the same name as a signal declared in
               CanControllerBringup.Top
        └─ hint: the parent's `gap_cnt` wins and the child's becomes
                 `report_gap_cnt`. Rename one of them so the source reads
                 unambiguously.

  ## Priority

  Runs at 54, after unconnected input (52) and before reset coverage (55).
  """

  @behaviour Hw.Analysis.Rule

  alias Hw.Analysis.{Diagnostic, Location}

  @impl Hw.Analysis.Rule
  def priority, do: 54

  @impl Hw.Analysis.Rule
  def run(%{components: components}) do
    Enum.flat_map(components, fn comp ->
      check_component(comp, components)
    end)
  end

  def run(_), do: []

  defp check_component(comp, all_components) do
    parent_names = MapSet.new(comp.signals, & &1.name)

    Enum.flat_map(comp.instances, fn inst ->
      case find_component(all_components, inst.module) do
        nil -> []
        child_comp -> check_instance(inst, child_comp, comp, parent_names)
      end
    end)
  end

  defp check_instance(inst, child_comp, parent_comp, parent_names) do
    connected =
      inst
      |> inst_conns()
      |> Enum.map(fn {port, _wire} -> port end)
      |> MapSet.new()

    child_comp.signals
    |> Enum.reject(&MapSet.member?(connected, &1.name))
    |> Enum.filter(&MapSet.member?(parent_names, &1.name))
    |> Enum.map(fn sig ->
      loc = inst[:source_location] || fallback(parent_comp.module)

      Diagnostic.warning(
        :instance_name_shadow,
        "instance `:#{inst.name}` (#{inspect(inst.module)}) has an internal signal " <>
          "`#{sig.name}` with the same name as a signal declared in " <>
          "#{inspect(parent_comp.module)}",
        loc,
        context: %{
          signal: sig.name,
          instance: inst.name,
          module: inst.module,
          parent: parent_comp.module,
          resolved_to: :"#{inst.name}_#{sig.name}"
        },
        related:
          Enum.reject(
            [
              sig[:source_location] &&
                %{
                  location: sig[:source_location],
                  message: "child signal `#{sig.name}` declared here"
                }
            ],
            &(&1 == false or &1 == nil)
          )
      )
    end)
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
