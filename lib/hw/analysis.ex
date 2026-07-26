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
    diagnostics = run_all_rules(metadata) ++ run_ir_rules(modules)

    %{
      diagnostics:     Enum.uniq(diagnostics),
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
  def rules, do: rules(:all)

  @doc """
  Returns registered rules for one stage (`:metadata`, `:ir`, or `:all`),
  sorted by priority. See `Hw.Analysis.Rule` for what the stages mean.
  """
  def rules(stage) do
    {:ok, mods} = :application.get_key(:ehdl, :modules)

    mods
    |> Enum.filter(fn mod ->
      rule_namespace?(mod) and rule_behaviour?(mod) and
        (stage == :all or rule_stage(mod) == stage)
    end)
    |> Enum.sort_by(fn mod ->
      if (Code.ensure_loaded?(mod) and function_exported?(mod, :priority, 0)), do: mod.priority(), else: 50
    end)
  end

  defp rule_stage(mod) do
    if (Code.ensure_loaded?(mod) and function_exported?(mod, :stage, 0)) do
      mod.stage()
    else
      :metadata
    end
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
    rules(:metadata)
    |> Enum.reduce([], fn rule, acc ->
      acc ++ safe_run(rule, metadata)
    end)
    |> Diagnostic.sort()
  end

  # IR-stage rules need a flattened netlist, so each component is elaborated on
  # its own and handed to them. A component that cannot stand alone (it expects
  # a parent to drive its inputs) simply raises during elaboration and is
  # skipped — that is a property of the component, not a rule failure, so it is
  # not reported.
  defp run_ir_rules(modules) do
    case rules(:ir) do
      [] ->
        []

      ir_rules ->
        modules
        |> Enum.flat_map(fn mod ->
          case safe_elaborate(mod) do
            {:ok, design} -> Enum.flat_map(ir_rules, &safe_run(&1, design))
            :error -> []
          end
        end)
        |> Diagnostic.sort()
    end
  end

  defp safe_elaborate(module) do
    {:ok, Hw.Compile.Elaborate.elaborate(module)}
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  # A rule that raises must not take the whole suite down with it.
  #
  # Module discovery in `mix hw.check` used to return nothing, so the suite
  # never actually ran and a rule could rot unnoticed. Isolating failures means
  # one stale rule costs that rule's coverage and nothing else, and reports
  # itself instead of aborting the run.
  defp safe_run(rule, metadata) do
    rule.run(metadata)
  rescue
    e ->
      [
        Diagnostic.error(
          :analysis_rule_crashed,
          "analysis rule #{inspect(rule)} raised: " <> Exception.message(e),
          %Hw.Analysis.Location{file: "unknown", line: 0, module: rule},
          context: %{rule: rule, exception: Exception.message(e)}
        )
      ]
  end

  # ---------------------------------------------------------------------------
  # Stage 1: Collect metadata from compiled modules
  # ---------------------------------------------------------------------------

  defp collect(modules) do
    {components, interfaces} =
      Enum.split_with(modules, fn mod ->
        (Code.ensure_loaded?(mod) and function_exported?(mod, :__hw_signals__, 0))
      end)

    %{
      components:  Enum.map(components, &collect_component/1),
      interfaces:  Enum.map(interfaces, &collect_interface/1),
      connections: collect_connections(components)
    }
  end

  defp collect_component(module) do
    signals = if (Code.ensure_loaded?(module) and function_exported?(module, :__hw_signals__, 0)),
      do: module.__hw_signals__(), else: []

    clocks = if (Code.ensure_loaded?(module) and function_exported?(module, :__hw_clocks__, 0)),
      do: module.__hw_clocks__(), else: []

    instances = if (Code.ensure_loaded?(module) and function_exported?(module, :__hw_instances__, 0)),
      do: module.__hw_instances__(), else: []

    interfaces = if (Code.ensure_loaded?(module) and function_exported?(module, :__hw_interface_bindings__, 0)),
      do: module.__hw_interface_bindings__(), else: []

    # Logic, FSMs and tristates are part of a component's definition and rules
    # need them to answer "what drives this?". Without them a rule can only see
    # instance port maps, so every signal driven by a `comb` or `on :clk` block
    # looks undriven.
    logic = optional(module, :__hw_logic__)
    fsms = optional(module, :__hw_fsm__)
    tristates = optional(module, :__hw_tristates__)
    blackboxes = optional(module, :__hw_blackboxes__)

    %{
      module:     module,
      signals:    signals,
      clocks:     clocks,
      instances:  instances,
      interfaces: interfaces,
      logic:      logic,
      fsms:       fsms,
      tristates:  tristates,
      blackboxes: blackboxes
    }
  end

  defp optional(module, fun) do
    if Code.ensure_loaded?(module) and function_exported?(module, fun, 0) do
      case apply(module, fun, []) do
        list when is_list(list) -> list
        nil -> []
        other -> [other]
      end
    else
      []
    end
  end

  defp collect_interface(module) do
    signals = if (Code.ensure_loaded?(module) and function_exported?(module, :__hw_interface_signals__, 0)),
      do: module.__hw_interface_signals__(), else: []

    %{module: module, signals: signals}
  end

  defp collect_connections(component_modules) do
    Enum.flat_map(component_modules, fn mod ->
      if (Code.ensure_loaded?(mod) and function_exported?(mod, :__hw_connections__, 0)) do
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
