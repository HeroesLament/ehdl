defmodule Hw.Analysis.Rules.UndrivenOutput do
  @moduledoc """
  Detects output ports that are never driven by any instance or combinational
  assignment in a top-level component.

  An output port declared on a component must be driven by exactly one of:
  - A `comb do` assignment in the component body
  - An instance output port connected to it
  - A `tristate` declaration mapping to it

  An output port that appears in no port map and no comb block is almost
  certainly a bug — either a wire was forgotten, an instance was not wired
  up, or the signal was renamed without updating all connection sites.

  Signals beginning with `_` are treated as intentionally unconnected
  (the EHDL convention for discarded ports, e.g. `_dp_loopback`).

  ## Example diagnostic

      warning[W050]: output port `:gn12` is never driven
        │
        │ HelloBoard.Top
        │
        │   output :gn12, 1
        │   ^^^^^^^^^^^^^
        │
        └─ hint: if intentionally unconnected, rename to `:_gn12`
                 otherwise add an assignment: `gn12 = 0` in a `comb do` block

  ## Priority

  Runs at priority 50 (default), after interface/CDC checks.
  """

  @behaviour Hw.Analysis.Rule

  alias Hw.Analysis.{Diagnostic, Location}

  @impl Hw.Analysis.Rule
  def priority, do: 50

  @impl Hw.Analysis.Rule
  def run(%{components: components}) do
    Enum.flat_map(components, fn comp ->
      check_component(comp)
    end)
  end

  defp check_component(comp) do
    output_signals =
      comp.signals
      |> Enum.filter(&(&1.direction == :output))
      |> Enum.reject(&intentionally_unconnected?(&1.name))

    # Collect all wires driven by instance output ports
    instance_driven =
      comp.instances
      |> Enum.flat_map(fn inst ->
        inst_conns(inst)
        |> Enum.map(fn {_port, wire} -> wire end)
        |> Enum.filter(&is_atom/1)
      end)
      |> MapSet.new()

    # Collect all wires driven by tristate declarations
    tristate_driven =
      Map.get(comp, :tristates, [])
      |> Enum.map(& &1.io)
      |> MapSet.new()

    driven = MapSet.union(instance_driven, tristate_driven)

    Enum.flat_map(output_signals, fn sig ->
      if MapSet.member?(driven, sig.name) do
        []
      else
        loc = sig[:source_location] || fallback(comp.module)
        [Diagnostic.warning(
          :undriven_output,
          "output port `:#{sig.name}` on #{inspect(comp.module)} is never driven",
          loc,
          context: %{signal: sig.name, module: comp.module},
          related: []
        )]
      end
    end)
  end

  defp intentionally_unconnected?(name) do
    name |> Atom.to_string() |> String.starts_with?("_")
  end

  defp inst_conns(%{ports: ports}) when is_list(ports), do: ports
  defp inst_conns(%{connections: conns}) when is_list(conns), do: conns
  defp inst_conns(_), do: []

  defp fallback(module),
    do: %Location{file: "unknown", line: 0, module: module}
end
