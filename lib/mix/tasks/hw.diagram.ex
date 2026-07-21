defmodule Mix.Tasks.Hw.Diagram do
  @moduledoc """
  Generate a wiring diagram for one or more EHDL component modules.

  ## Usage

      mix hw.diagram HelloBoard.Top
      mix hw.diagram HelloBoard.Top --format svg --output diagram.svg
      mix hw.diagram HelloBoard.Top --format dot --output diagram.dot
      mix hw.diagram HelloBoard.Top --format mermaid

  ## Formats

    * `typst` (default) — Typst/fletcher source compiled to SVG or PDF.
      Requires `typst` on PATH. If not found, writes the `.typ` source
      and tells you how to compile it.

    * `svg` — Same as typst but compiles and writes `.svg` directly.

    * `pdf` — Same as typst but compiles to `.pdf`.

    * `dot` — Graphviz DOT source. Pipe to `dot -Tsvg` or open in
      any Graphviz viewer.

    * `mermaid` — Mermaid flowchart source wrapped in a markdown fence.
      Paste into GitHub, Notion, Obsidian, or any Mermaid-aware tool.

  ## Options

    * `--format` / `-f` — output format (default: `typst`)
    * `--output` / `-o` — output file path (default: `<module>_diagram.<ext>`)
    * `--open`          — open the output file after generation (macOS only)
    * `--print`         — print the generated source to stdout instead of a file

  ## Examples

      # Generate SVG wiring diagram for the top-level design
      mix hw.diagram HelloBoard.Top --format svg

      # Generate DOT and pipe to Graphviz
      mix hw.diagram HelloBoard.Top --format dot --print | dot -Tsvg > diagram.svg

      # Generate Mermaid for pasting into docs
      mix hw.diagram Hw.USB.CDCSerial --format mermaid --print
  """

  use Mix.Task

  @shortdoc "Generate a wiring diagram for an EHDL component"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("compile", [])

    {opts, positional, _invalid} = OptionParser.parse(args,
      aliases: [f: :format, o: :output],
      strict: [
        format: :string,
        output: :string,
        open:   :boolean,
        print:  :boolean
      ]
    )

    module_str = case positional do
      [m | _] -> m
      [] ->
        Mix.raise("""
        Usage: mix hw.diagram <Module> [options]
        Example: mix hw.diagram HelloBoard.Top --format svg
        """)
    end

    module = module_str
      |> String.split(".")
      |> Module.concat()

    case Code.ensure_loaded(module) do
      {:module, _} -> :ok
      {:error, reason} ->
        Mix.raise("Could not load #{module_str}: #{inspect(reason)}. " <>
                  "Make sure the module is in elixirc_paths and compiles cleanly.")
    end

    unless function_exported?(module, :__hw_instances__, 0) do
      Mix.raise("#{module_str} does not appear to be an Hw.Component " <>
                "(no __hw_instances__/0 exported). Is it compiled? " <>
                "If it lives under designs/, ensure \"designs\" is in elixirc_paths.")
    end

    format = (opts[:format] || "typst") |> String.to_atom()
    print? = Keyword.get(opts, :print, false)
    open?  = Keyword.get(opts, :open, false)

    {source, ext} = generate(module, format)

    if print? do
      IO.puts(source)
    else
      output_path = opts[:output] || default_output_path(module, format, ext)
      write_output(module, format, source, output_path, open?)
    end
  end

  # ---------------------------------------------------------------------------
  # Generation
  # ---------------------------------------------------------------------------

  defp generate(module, :typst),   do: {Hw.Diagram.typst(module),   "typ"}
  defp generate(module, :svg),     do: {Hw.Diagram.typst(module),   "typ"}
  defp generate(module, :pdf),     do: {Hw.Diagram.typst(module),   "typ"}
  defp generate(module, :dot),     do: {Hw.Diagram.dot(module),     "dot"}
  defp generate(module, :mermaid), do: {Hw.Diagram.mermaid(module), "md"}
  defp generate(_module, fmt),     do: Mix.raise("Unknown format: #{fmt}. Use typst, svg, pdf, dot, or mermaid.")

  # ---------------------------------------------------------------------------
  # Output writing
  # ---------------------------------------------------------------------------

  defp write_output(module, format, source, output_path, open?) do
    Mix.shell().info("==> hw.diagram #{inspect(module)}")

    case format do
      f when f in [:typst, :dot, :mermaid] ->
        File.write!(output_path, source)
        Mix.shell().info("    Written: #{output_path}")

        if f == :typst do
          hint_typst_compile(output_path)
        end

      f when f in [:svg, :pdf] ->
        # Write .typ first, then compile
        typ_path = Path.rootname(output_path) <> ".typ"
        File.write!(typ_path, source)

        out_ext  = if f == :svg, do: "svg", else: "pdf"
        out_path = Path.rootname(output_path) <> "." <> out_ext

        case compile_typst(typ_path, out_path, out_ext) do
          :ok ->
            File.rm(typ_path)
            Mix.shell().info("    Written: #{out_path}")

          {:error, reason} ->
            Mix.shell().info("    Typst source: #{typ_path}")
            Mix.shell().info("    #{reason}")
        end
    end

    if open? do
      open_file(output_path)
    end
  end

  defp compile_typst(typ_path, out_path, fmt) do
    case System.find_executable("typst") do
      nil ->
        {:error, "typst not found on PATH — install from https://github.com/typst/typst/releases"}

      typst ->
        Mix.shell().info("    Compiling with typst...")
        case System.cmd(typst, ["compile", "--format", fmt, typ_path, out_path],
               stderr_to_stdout: true) do
          {_, 0}      -> :ok
          {output, _} -> {:error, "typst compile failed:\n#{output}"}
        end
    end
  end

  defp hint_typst_compile(typ_path) do
    svg_path = Path.rootname(typ_path) <> ".svg"
    pdf_path = Path.rootname(typ_path) <> ".pdf"
    Mix.shell().info("""
        To compile:
          typst compile --format svg #{typ_path} #{svg_path}
          typst compile --format pdf #{typ_path} #{pdf_path}
    """)
  end

  defp default_output_path(module, format, ext) do
    base = module
      |> Module.split()
      |> Enum.map(&Macro.underscore/1)
      |> Enum.join("_")

    final_ext = case format do
      :svg    -> "svg"
      :pdf    -> "pdf"
      _       -> ext
    end

    "#{base}_diagram.#{final_ext}"
  end

  defp open_file(path) do
    case :os.type() do
      {:unix, :darwin} -> System.cmd("open", [path])
      _                -> Mix.shell().info("    --open is only supported on macOS")
    end
  end
end
