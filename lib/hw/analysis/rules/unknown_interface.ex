defmodule Hw.Analysis.Rules.UnknownInterface do
  @moduledoc """
  Checks that every interface module referenced in `provides` or `consumes`
  declarations:

  1. Is a loaded module (exists and is compiled)
  2. Exports `__hw_interface_signals__/0` (was defined with `use Hw.Interface`)

  Reports `:unknown_interface` errors with the source location of the
  `provides`/`consumes` declaration so the IDE can underline exactly
  the right line.

  This rule runs after all modules are compiled so it is safe from
  parallel compilation ordering issues — a module that doesn't exist
  by analysis time genuinely doesn't exist.
  """

  @behaviour Hw.Analysis.Rule

  alias Hw.Analysis.Diagnostic

  @impl Hw.Analysis.Rule
  def priority, do: 10

  @impl Hw.Analysis.Rule
  @spec run(Hw.Analysis.metadata()) :: [Diagnostic.t()]
  def run(%{components: components}) do
    Enum.flat_map(components, fn component ->
      Enum.flat_map(component.interfaces, fn binding ->
        check_interface(binding, component.module)
      end)
    end)
  end

  defp check_interface(%{interface: iface_mod, role: role, name: name} = binding, component_mod) do
    loc = binding[:source_location] || fallback_location(component_mod)
    role_str = if role == :provider, do: "provides", else: "consumes"

    cond do
      not module_loaded?(iface_mod) ->
        [Diagnostic.error(
          :unknown_interface,
          "#{inspect(component_mod)} #{role_str} #{inspect(iface_mod)} as :#{name}, " <>
          "but #{inspect(iface_mod)} is not a loaded module. " <>
          "Check the module name and ensure it is compiled.",
          loc
        )]

      not function_exported?(iface_mod, :__hw_interface_signals__, 0) ->
        [Diagnostic.error(
          :unknown_interface,
          "#{inspect(component_mod)} #{role_str} #{inspect(iface_mod)} as :#{name}, " <>
          "but #{inspect(iface_mod)} is not a valid interface " <>
          "(missing `use Hw.Interface` or `__hw_interface_signals__/0`).",
          loc
        )]

      true ->
        []
    end
  end

  defp module_loaded?(module) do
    case Code.ensure_loaded(module) do
      {:module, _} -> true
      {:error, _}  -> false
    end
  end

  defp fallback_location(module) do
    %Hw.Analysis.Location{file: "unknown", line: 0, module: module}
  end
end
