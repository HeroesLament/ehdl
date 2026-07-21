defmodule Hw.Analysis.Rules.InterfaceCompleteness do
  @moduledoc """
  Checks that every signal declared in an interface definition is present
  on both the provider and consumer components.

  Reports `:missing_signal` errors with suggestions for likely typos.
  """

  @behaviour Hw.Analysis.Rule

  alias Hw.Analysis.Diagnostic

  @impl Hw.Analysis.Rule
  def priority, do: 20

  @doc "Run the completeness rule over collected metadata."
  @impl Hw.Analysis.Rule
  @spec run(Hw.Analysis.metadata()) :: [Diagnostic.t()]
  def run(%{components: components, connections: connections}) do
    Enum.flat_map(connections, fn conn ->
      provider = find_component(components, conn.provider_module)
      consumer = find_component(components, conn.consumer_module)

      if provider == nil or consumer == nil do
        # Unknown instance errors are reported by UnknownInstance rule
        []
      else
        provider_binding = find_binding(provider, conn.provider_interface)
        consumer_binding = find_binding(consumer, conn.consumer_interface)

        if provider_binding == nil or consumer_binding == nil do
          []
        else
          interface_mod = provider_binding.interface
          specs = interface_mod.__hw_interface_signals__()

          provider_signals = MapSet.new(provider.signals, & &1.name)
          consumer_signals = MapSet.new(consumer.signals, & &1.name)

          Enum.flat_map(specs, fn spec ->
            check_signal_present(spec, provider_signals, provider, conn, :provider) ++
            check_signal_present(spec, consumer_signals, consumer, conn, :consumer)
          end)
        end
      end
    end)
  end

  defp check_signal_present(spec, signal_set, component, conn, role) do
    if MapSet.member?(signal_set, spec.name) do
      []
    else
      suggestion = find_suggestion(spec.name, signal_set)

      suggestion_opts = case suggestion do
        nil -> []
        {name, loc} -> [suggestion: ":#{name}", suggestion_loc: loc]
      end

      loc = conn.location || %Hw.Analysis.Location{
        file: "unknown", line: 0, module: component.module
      }

      role_str = if role == :provider, do: "provides", else: "consumes"
      component_str = inspect(component.module)

      [Diagnostic.error(
        :missing_signal,
        "#{component_str}(#{conn.provider_interface}) #{role_str} interface " <>
        "#{inspect(spec.name |> to_string())} but signal :#{spec.name} is not declared.",
        loc,
        context: Map.new(suggestion_opts)
      )]
    end
  end

  defp find_component(components, module) do
    Enum.find(components, &(&1.module == module))
  end

  defp find_binding(component, interface_name) do
    Enum.find(component.interfaces, &(&1.name == interface_name))
  end

  # Find the closest signal name by Levenshtein distance (suggestion for typos)
  defp find_suggestion(name, signal_set) do
    name_str = Atom.to_string(name)

    signal_set
    |> MapSet.to_list()
    |> Enum.map(fn sig ->
      {sig, levenshtein(name_str, Atom.to_string(sig))}
    end)
    |> Enum.filter(fn {_, d} -> d <= 3 end)
    |> Enum.sort_by(fn {_, d} -> d end)
    |> case do
      [] -> nil
      [{best, _} | _] -> {best, nil}   # location filled in by caller if available
    end
  end

  # Simple iterative Levenshtein distance
  defp levenshtein(a, b) do
    _a_len = String.length(a)
    b_len = String.length(b)
    a_chars = String.graphemes(a)
    b_chars = String.graphemes(b)

    row = Enum.to_list(0..b_len)

    Enum.reduce(Enum.with_index(a_chars), row, fn {a_char, i}, prev_row ->
      [i + 1 | Enum.reduce(Enum.with_index(b_chars), {i + 1, prev_row}, fn
        {b_char, j}, {left, [diag | rest_prev]} ->
          cost = if a_char == b_char, do: 0, else: 1
          up = hd(rest_prev) |> then(fn _ -> Enum.at(prev_row, j + 1) end)
          new_val = Enum.min([left + 1, up + 1, diag + cost])
          {new_val, rest_prev}
      end) |> elem(0) |> then(fn last -> [last] end)]
      |> Enum.reverse()
    end)
    |> List.last()
  end
end
