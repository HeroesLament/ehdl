defmodule Hw.CLI.Diagram do
  @moduledoc """
  `ehdl diagram`: a wiring diagram of a component.

      ehdl diagram HelloBoard.Top
      ehdl diagram HelloBoard.Top --format svg -o diagram.svg
      ehdl diagram blinky.ex --format mermaid -o -

  ## Formats

    * `typst` (default): Typst/fletcher source. Compile it with `typst`.
    * `svg`, `pdf`: the Typst source compiled with `typst` from PATH. Without
      `typst`, the `.typ` source is left in place.
    * `dot`: Graphviz DOT source.
    * `mermaid`: a Mermaid flowchart in a markdown fence.
  """

  use Cheer.Command

  alias Hw.CLI.Target

  @formats %{"typst" => :typst, "svg" => :svg, "pdf" => :pdf, "dot" => :dot, "mermaid" => :mermaid}

  command "diagram" do
    about "Draw a wiring diagram of a component"

    argument :design, help: "Design file (blinky.ex) or, in a Mix project, module"
    option :top, value_name: "MODULE", help: "Top component, when the design has several"
    option :format, short: :f, default: "typst", choices: Map.keys(@formats), help: "Output format"
    option :out, short: :o, value_name: "FILE", help: "Output file, or - for the source on stdout"
    option :open, type: :boolean, help: "Open the output when written (macOS)"
  end

  @impl Cheer.Command
  def run(args, _raw) do
    target = Target.load(args[:design])
    module = Target.top(target, args[:top])
    format = Map.fetch!(@formats, args.format)

    {source, ext} = generate(module, format)

    case args[:out] do
      "-" ->
        IO.puts(source)

      out ->
        path = out || default_output_path(module, format, ext)
        write_output(format, source, path, args[:open] == true)
    end

    :ok
  end

  defp generate(module, :typst), do: {Hw.Diagram.typst(module), "typ"}
  defp generate(module, :svg), do: {Hw.Diagram.typst(module), "typ"}
  defp generate(module, :pdf), do: {Hw.Diagram.typst(module), "typ"}
  defp generate(module, :dot), do: {Hw.Diagram.dot(module), "dot"}
  defp generate(module, :mermaid), do: {Hw.Diagram.mermaid(module), "md"}

  # ---------------------------------------------------------------------------
  # Output writing
  # ---------------------------------------------------------------------------

  defp write_output(format, source, output_path, open?) do
    case format do
      f when f in [:typst, :dot, :mermaid] ->
        File.write!(output_path, source)
        IO.puts(output_path)

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
            IO.puts(out_path)

          {:error, reason} ->
            IO.puts("    Typst source: #{typ_path}")
            IO.puts("    #{reason}")
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
        IO.puts("    Compiling with typst...")
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
    IO.puts("""
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
      _                -> IO.puts("    --open is only supported on macOS")
    end
  end
end
