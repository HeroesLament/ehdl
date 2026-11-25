defmodule Hw.CLI.Target do
  @moduledoc """
  Turns the design named on the command line into loaded modules.

  Two ways to name a design:

    * A source file (`blinky.ex`), outside any Mix project. The file is
      compiled in this VM against the ehdl the `ehdl` binary was built from.
      With no name at all, the one `.ex` file in the directory is used.

    * A module (`PicoBeam.Top`), in a directory with a `mix.exs`. The command
      is handed to `Hw.CLI.Project`, which re-runs it under `mix` so the
      project's own dependencies (and its own ehdl) are the ones in force.
      With no name, the project's one top-level component is used.
  """

  alias Hw.CLI

  defstruct [:source, :stem, components: [], interfaces: []]

  @type t :: %__MODULE__{
          source: :file | :project,
          stem: String.t() | nil,
          components: [module()],
          interfaces: [module()]
        }

  @doc "Load the design `name` refers to (`nil` for the directory's default)."
  @spec load(String.t() | nil) :: t()
  def load(name) do
    cond do
      CLI.Project.inside?() -> from_project(name)
      File.exists?("mix.exs") -> CLI.Project.delegate()
      true -> from_file(name)
    end
  end

  @doc """
  The top component of a loaded design: the one named by `top`, or the only
  component nothing else instantiates.
  """
  @spec top(t(), String.t() | nil) :: module()
  def top(%__MODULE__{components: components}, top) when is_binary(top) do
    module = to_module(top)

    if module in components do
      module
    else
      CLI.fail!("#{top} is not one of: #{names(components)}")
    end
  end

  def top(%__MODULE__{components: []}, nil) do
    CLI.fail!("no Hw.Component module found")
  end

  def top(%__MODULE__{components: components, source: source}, nil) do
    how = if source == :project, do: "name one", else: "pick one with --top"

    case roots(components) do
      [module] -> module
      [] -> CLI.fail!("every component is instantiated by another; #{how}")
      many -> CLI.fail!("more than one top-level component, #{how}:\n" <> listing(many))
    end
  end

  @doc "File stem for outputs: the source file's, or the top's design name."
  @spec stem(t(), module()) :: String.t()
  def stem(%__MODULE__{stem: stem}, _top) when is_binary(stem), do: stem
  def stem(%__MODULE__{}, top), do: to_string(top.__hw_design_name__())

  # --- single file -----------------------------------------------------------

  defp from_file(nil) do
    case Path.wildcard("*.ex") do
      [file] -> from_file(file)
      [] -> CLI.fail!("no .ex file here; name a design file")
      files -> CLI.fail!("more than one .ex file here, name one: #{Enum.join(files, ", ")}")
    end
  end

  defp from_file(file) do
    unless File.regular?(file) do
      CLI.fail!("#{file}: no such file (a module name needs a Mix project)")
    end

    modules = for {module, _beam} <- Code.compile_file(file), do: module

    %__MODULE__{
      source: :file,
      stem: file |> Path.basename() |> Path.rootname(),
      components: Enum.filter(modules, &component?/1),
      interfaces: Enum.filter(modules, &interface?/1)
    }
  end

  # --- Mix project -----------------------------------------------------------

  defp from_project(nil) do
    modules = CLI.Project.modules()

    %__MODULE__{
      source: :project,
      components: Enum.filter(modules, &component?/1),
      interfaces: Enum.filter(modules, &interface?/1)
    }
  end

  defp from_project(name) do
    if String.ends_with?(name, [".ex", ".exs"]) do
      CLI.fail!("inside a Mix project a design is named by module, not by file: #{name}")
    end

    module = to_module(name)

    cond do
      not Code.ensure_loaded?(module) ->
        CLI.fail!("module #{name} is not in this project")

      component?(module) ->
        %__MODULE__{source: :project, components: [module]}

      interface?(module) ->
        %__MODULE__{source: :project, interfaces: [module]}

      true ->
        CLI.fail!("#{name} is not an Hw.Component")
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp roots(components) do
    instantiated =
      for parent <- components,
          %{module: child} <- parent.__hw_instances__(),
          into: MapSet.new(),
          do: child

    Enum.reject(components, &MapSet.member?(instantiated, &1))
  end

  defp component?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__hw_design__, 0)
  end

  defp interface?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__hw_interface_signals__, 0)
  end

  defp to_module(name), do: name |> String.split(".") |> Module.concat()

  defp names(modules), do: Enum.map_join(modules, ", ", &inspect/1)

  defp listing(modules), do: Enum.map_join(modules, "\n", &("  " <> inspect(&1)))
end
