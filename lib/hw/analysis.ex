defmodule Hw.Analysis do
  @moduledoc """
  Pure hardware design analysis pipeline.

  Takes a list of compiled component modules and returns a structured
  result containing diagnostics, an interface graph, and a signal index.

  This module is intentionally side-effect free — no IO, no compilation,
  no filesystem access. All output is in the returned `t:result/0`.

  ## Usage

      modules = [Hw.USB.SIE, Hw.USB.CDCSerial, HelloBoard.Top]
      result = Hw.Analysis.run(modules)

      if Hw.Analysis.Diagnostic.has_errors?(result.diagnostics) do
        Hw.Analysis.Formatter.print(result.diagnostics)
      end

  ## Architecture

  The pipeline runs in three stages:

  1. **Collect** — gather metadata from all module attributes
  2. **Rules** — run each analysis rule, accumulating diagnostics
  3. **Index** — build the signal and interface indices for LSP queries

  ## Rule Registration

  Rules are auto-discovered. Any module that:
  - Lives under the `Hw.Analysis.Rules.*` namespace
  - Adopts the `Hw.Analysis.Rule` behaviour
  - Implements `run/1` :: `(metadata -> [Diagnostic.t()])`

  ...will be picked up and run automatically. No changes to this file
  needed to add a new rule — just drop a new module in
  `lib/hw/analysis/rules/` and it runs.

  Rules run in priority order (`:priority` module attribute, default 50).
  Lower numbers run first. `UnknownInterface` runs at priority 10 so
  subsequent rules can safely assume interface modules are valid.
  """

  alias Hw.Analysis.{Diagnostic, Location}

  @type metadata :: %{
    components:  [component_meta()],
    interfaces:  [interface_meta()],
    connections: [connection_meta()]
  }

  @type component_meta :: %{
    module:     module(),
    signals:    [map()],
    clocks:     [map()],
    instances:  [map()],
    interfaces: [interface_binding()]
  }

  @type interface_binding :: %{
    name:            atom(),
    interface:       module(),
    role:            atom(),
    source_location: Location.t() | nil
  }

  @type interface_meta :: %{
    module:  module(),
    signals: [map()]
  }

  @type connection_meta :: %{
    provider_module:    module(),
    provider_interface: atom(),
    consumer_module:    module(),
    consumer_interface: atom(),
    source_location:    Location.t() | nil
  }

  @type result :: %{
    diagnostics:     [Diagnostic.t()],
    interface_graph: map(),
    signal_index:    map()
  }

  @doc """
  Run the full analysis pipeline over a list of modules.

  Returns a `t:result/0` with all diagnostics and indices.
  """
  @spec run([module()]) :: result()
  def run(modules) do
    metadata    = collect(modules)
    diagnostics = run_all_rules(metadata)

    %{
      diagnostics:     diagnostics,
      interface_graph: build_interface_graph(metadata),
      signal_index:    build_signal_index(metadata)
    }
  end

  # ---------------------------------------------------------------------------
  # Rule auto-discovery
  # ---------------------------------------------------------------------------

  @doc """
  Returns all registered analysis rules sorted by priority.
  Rules are discovered by scanning application modules for those that
  adopt the `Hw.Analysis.Rule` behaviour.
  """
  def rules do
    {:ok, mods} = :application.get_key(:ehdl, :modules)

    mods
    |> Enum.filter(fn mod ->
      rule_namespace?(mod) and rule_behaviour?(mod)
    end)
    |> Enum.sort_by(fn mod ->
      if function_exported?(mod, :priority, 0), do: mod.priority(), else: 50
    end)
  end

  defp rule_namespace?(mod) do
    mod
    |> Module.split()
    |> Enum.take(3)
    |> case do
      ["Hw", "Analysis", "Rules"] -> true
      _ -> false
    end
  end

  defp rule_behaviour?(mod) do
    behaviours = mod.module_info(:attributes)
      |> Keyword.get(:behaviour, [])
    Hw.Analysis.Rule in behaviours
  end

  defp run_all_rules(metadata) do
    rules()
    |> Enum.reduce([], fn rule, acc ->
      acc ++ rule.run(metadata)
    end)
    |> Diagnostic.sort()
  end

  # ---------------------------------------------------------------------------
  # Stage 1: Collect metadata from compiled modules
  # ---------------------------------------------------------------------------

  defp collect(modules) do
    {components, interfaces} =
      Enum.split_with(modules, fn mod ->
        function_exported?(mod, :__hw_signals__, 0)
      end)

    %{
      components:  Enum.map(components, &collect_component/1),
      interfaces:  Enum.map(interfaces, &collect_interface/1),
      connections: collect_connections(components)
    }
  end

  defp collect_component(module) do
    signals = if function_exported?(module, :__hw_signals__, 0),
      do: module.__hw_signals__(), else: []

    clocks = if function_exported?(module, :__hw_clocks__, 0),
      do: module.__hw_clocks__(), else: []

    instances = if function_exported?(module, :__hw_instances__, 0),
      do: module.__hw_instances__(), else: []

    interfaces = if function_exported?(module, :__hw_interface_bindings__, 0),
      do: module.__hw_interface_bindings__(), else: []

    %{
      module:     module,
      signals:    signals,
      clocks:     clocks,
      instances:  instances,
      interfaces: interfaces
    }
  end

  defp collect_interface(module) do
    signals = if function_exported?(module, :__hw_interface_signals__, 0),
      do: module.__hw_interface_signals__(), else: []

    %{module: module, signals: signals}
  end

  defp collect_connections(component_modules) do
    Enum.flat_map(component_modules, fn mod ->
      if function_exported?(mod, :__hw_connections__, 0) do
        mod.__hw_connections__()
      else
        []
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Stage 3: Build indices (for LSP hover, go-to-definition etc.)
  # ---------------------------------------------------------------------------

  defp build_signal_index(metadata) do
    for component <- metadata.components,
        signal <- component.signals,
        loc = Map.get(signal, :source_location),
        loc != nil,
        into: %{} do
      {{component.module, signal.name}, loc}
    end
  end

  defp build_interface_graph(metadata) do
    for component <- metadata.components,
        binding <- component.interfaces,
        into: %{} do
      {{component.module, binding.name}, binding}
    end
  end
end
