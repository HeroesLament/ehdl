defmodule Hw.Analysis.Rules.SignalWidthMatch do
  @moduledoc """
  Checks that signal widths match between provider and consumer across
  every interface connection.

  For parameterized widths (`{:param, name}` or `{:param, name, fun}`),
  widths are resolved against the component's param bindings before
  comparison. If a param is unresolved, this rule skips the width check
  (the ParamResolution rule will report the unresolved param separately).

  Reports `:width_mismatch` errors with both sides of the mismatch shown,
  including source locations for rich IDE display.
  """

  @behaviour Hw.Analysis.Rule

  alias Hw.Analysis.Diagnostic

  @impl Hw.Analysis.Rule
  def priority, do: 30

  @impl Hw.Analysis.Rule
  @spec run(Hw.Analysis.metadata()) :: [Diagnostic.t()]
  def run(%{components: components, connections: connections}) do
    Enum.flat_map(connections, fn conn ->
      provider = find_component(components, conn.provider_module)
      consumer = find_component(components, conn.consumer_module)

      if provider == nil or consumer == nil do
        []
      else
        provider_binding = find_binding(provider, conn.provider_interface)
        consumer_binding = find_binding(consumer, conn.consumer_interface)

        if provider_binding == nil or consumer_binding == nil do
          []
        else
          interface_mod = provider_binding.interface
          specs = interface_mod.__hw_interface_signals__()

          provider_params = extract_params(provider)
          consumer_params = extract_params(consumer)

          Enum.flat_map(specs, fn spec ->
            provider_sig = find_signal(provider, spec.name)
            consumer_sig = find_signal(consumer, spec.name)

            if provider_sig == nil or consumer_sig == nil do
              # Missing signal reported by InterfaceCompleteness rule
              []
            else
              check_width_match(
                spec, provider_sig, consumer_sig,
                provider_params, consumer_params,
                provider, consumer, conn
              )
            end
          end)
        end
      end
    end)
  end

  defp check_width_match(
    spec, provider_sig, consumer_sig,
    provider_params, consumer_params,
    provider, consumer, conn
  ) do
    with {:ok, pw} <- resolve(provider_sig.width, provider_params),
         {:ok, cw} <- resolve(consumer_sig.width, consumer_params) do
      if pw == cw do
        []
      else
        loc = conn.location || fallback_location(provider.module)

        [Diagnostic.error(
          :width_mismatch,
          "Signal :#{spec.name} width mismatch across connection " <>
          "#{inspect(provider.module)}(:#{conn.provider_interface}) → " <>
          "#{inspect(consumer.module)}(:#{conn.consumer_interface})",
          loc,
          context: %{
            signal:          spec.name,
            provider_width:  pw,
            consumer_width:  cw,
            provider_loc:    provider_sig.source_location,
            consumer_loc:    consumer_sig.source_location,
            provider_label:  short_module(provider.module),
            consumer_label:  short_module(consumer.module)
          },
          related: Enum.reject([
            provider_sig.source_location && %{
              location: provider_sig.source_location,
              message:  "provider signal :#{spec.name} declared here (#{pw}-bit)"
            },
            consumer_sig.source_location && %{
              location: consumer_sig.source_location,
              message:  "consumer signal :#{spec.name} declared here (#{cw}-bit)"
            }
          ], &(&1 == false or &1 == nil))
        )]
      end
    else
      # Unresolved param — skip, ParamResolution rule handles it
      {:error, _} -> []
    end
  end

  defp resolve(width, _params) when is_integer(width), do: {:ok, width}
  defp resolve({:param, name}, params) do
    Hw.Interface.resolve_width({:param, name}, params)
  end
  defp resolve({:param, name, fun}, params) do
    Hw.Interface.resolve_width({:param, name, fun}, params)
  end

  defp extract_params(component) do
    if (Code.ensure_loaded?(component.module) and function_exported?(component.module, :__hw_params__, 0)) do
      component.module.__hw_params__()
      |> Enum.map(fn p -> {p.name, p.value} end)
      |> Map.new()
    else
      %{}
    end
  end

  defp find_component(components, module) do
    Enum.find(components, &(&1.module == module))
  end

  defp find_binding(component, interface_name) do
    Enum.find(component.interfaces, &(&1.name == interface_name))
  end

  defp find_signal(component, name) do
    Enum.find(component.signals, &(&1.name == name))
  end

  defp short_module(module) do
    module |> Module.split() |> List.last()
  end

  defp fallback_location(module) do
    %Hw.Analysis.Location{file: "unknown", line: 0, module: module}
  end
end
