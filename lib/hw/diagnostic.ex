defmodule Hw.Diagnostic do
  @moduledoc """
  Diagnostic formatter for EHDL compile errors and warnings.

  Renders errors in a style blending Rust/Cargo, Mix output, and
  Elixir compiler conventions:

  - Mix `==>` stage headers and `** (Exception)` footers
  - Elixir `│` gutter, `└─` anchors, `·` ellipsis
  - Cargo-style `^^^^^` primary carets and `-----` secondary underlines
  - ANSI color when the terminal supports it, plain text otherwise

  ## Color roles

    bold red     — error label, exception footer
    red          — primary carets ^^^^, mismatched values
    bold yellow  — warning label
    yellow       — warning carets, note annotations
    bold cyan    — gutter │, └─, ·, line numbers
    cyan         — secondary underlines -----, declaration sites
    bold green   — help/hint lines and hint code
    bold white   — signal names in backticks in source lines
    white        — normal source code text
  """

  # ANSI escape codes
  @reset       IO.ANSI.reset()
  @bold        IO.ANSI.bright()
  @red         IO.ANSI.red()
  @bold_red    IO.ANSI.red()    <> IO.ANSI.bright()
  @yellow      IO.ANSI.yellow()
  @bold_yellow IO.ANSI.yellow() <> IO.ANSI.bright()
  @cyan        IO.ANSI.cyan()
  @bold_cyan   IO.ANSI.cyan()   <> IO.ANSI.bright()
  @green       IO.ANSI.green()
  @bold_green  IO.ANSI.green()  <> IO.ANSI.bright()
  @white       IO.ANSI.white()
  @bold_white  IO.ANSI.white()  <> IO.ANSI.bright()

  # ── Public API ─────────────────────────────────────────────────────────────

  @doc "Render and print an error diagnostic."
  def error(opts), do: render(:error, opts) |> IO.puts()

  @doc "Render and print a warning diagnostic."
  def warning(opts), do: render(:warning, opts) |> IO.puts()

  @doc "Render and print a note diagnostic."
  def note(opts), do: render(:note, opts) |> IO.puts()

  @doc """
  Render a diagnostic from a `Hw.Compile.Validate.Error`, with optional
  location hint (file, line, col).
  """
  def from_validate_error(%Hw.Compile.Validate.Error{} = err, opts \\ []) do
    file  = Keyword.get(opts, :file)
    line  = Keyword.get(opts, :line)
    col   = Keyword.get(opts, :col, 1)
    hint  = Keyword.get(opts, :hint)
    notes = Keyword.get(opts, :notes, [])

    base = [code: "E031", message: err.message, notes: notes, hint: hint]

    full_opts = if file && line,
      do:   base ++ [file: file, line: line, col: col],
      else: base

    render(:error, full_opts) |> IO.puts()
  end

  @doc "Render a diagnostic to a string (for testing or capturing)."
  def render(severity, opts) do
    color? = IO.ANSI.enabled?()
    build_lines(severity, opts, color?) |> Enum.join("\n")
  end

  # ── Top-level builder ──────────────────────────────────────────────────────

  defp build_lines(severity, opts, color?) do
    code      = Keyword.get(opts, :code)
    message   = Keyword.get(opts, :message, "")
    file      = Keyword.get(opts, :file)
    line      = Keyword.get(opts, :line)
    primary   = Keyword.get(opts, :primary)    # {col, len, label} | nil
    secondary = Keyword.get(opts, :secondary, [])  # [{col, len, label}]
    notes     = Keyword.get(opts, :notes, [])
    hint      = Keyword.get(opts, :hint)
    decl      = Keyword.get(opts, :decl)       # {file, line} | nil

    source_lines = if file && line, do: read_source(file, line), else: %{}

    label = if code,
      do:   "#{severity_label(severity)}[#{code}]",
      else: severity_label(severity)

    out = []

    # "error[E031]: mux value width mismatch"
    out = [format_header(label, message, severity, color?) | out]

    # "  │\n  │ lib/hw/std/usb/fs_phy.ex\n  │"
    out = if file,
      do:   [format_location_header(file, color?) | out],
      else: out

    # Declaration site snippet (where signal was declared)
    out = if decl do
      {decl_file, decl_line} = decl
      decl_src = read_source(decl_file, decl_line)
      [format_source_block(decl_file, decl_line, decl_src, nil, [], :secondary, color?) | out]
    else
      out
    end

    # "  ·" ellipsis if declaration and use are far apart
    out = if decl && line && abs(elem(decl, 1) - line) > 3,
      do:   [format_gutter_char("·", color?) | out],
      else: out

    # Primary source block with carets
    out = if file && line,
      do:   [format_source_block(file, line, source_lines, primary, secondary, :primary, color?) | out],
      else: out

    # Notes
    out = Enum.reduce(notes, out, fn text, acc ->
      [format_note(text, color?) | acc]
    end)

    # Hint/help
    out = if hint,
      do:   [format_hint(hint, color?) | out],
      else: out

    # Exception footer for errors
    out = if severity == :error,
      do:   [format_footer("Hw.Compile.Validate.Error", message, color?) | out],
      else: out

    Enum.reverse(out)
  end

  # ── Line formatters ────────────────────────────────────────────────────────

  defp format_header(label, message, severity, color?) do
    if color? do
      lc = severity_label_color(severity)
      "#{lc}#{label}#{@reset}#{@bold}: #{message}#{@reset}"
    else
      "#{label}: #{message}"
    end
  end

  defp format_location_header(file, color?) do
    g = g(color?)
    if color? do
      "#{g}\n#{g} #{@bold_white}#{file}#{@reset}\n#{g}"
    else
      "  │\n  │ #{file}\n  │"
    end
  end

  defp format_source_block(file, line, source_lines, primary, secondary, role, color?) do
    g    = g(color?)
    anc  = anc(color?)
    rows = []

    # Context line above
    rows = if src = Map.get(source_lines, line - 1) do
      [format_source_line(line - 1, src, color?) | rows]
    else
      rows
    end

    # The subject line
    rows = if src = Map.get(source_lines, line) do
      [format_source_line(line, src, :subject, role, color?) | rows]
    else
      rows
    end

    # Underline row
    rows = if primary || secondary != [] do
      [format_underlines(primary, secondary, role, color?) | rows]
    else
      rows
    end

    # Blank gutter
    rows = [g | rows]

    # File:line anchor
    loc_str = "#{file}:#{line}"
    rows = if color? do
      ["#{anc} #{@bold_cyan}#{loc_str}#{@reset}" | rows]
    else
      ["#{anc} #{loc_str}" | rows]
    end

    rows |> Enum.reverse() |> Enum.join("\n")
  end

  # Plain context line (line above)
  defp format_source_line(num, src, color?) do
    n = String.pad_leading("#{num}", 3)
    if color? do
      "#{@bold_cyan}#{n}│#{@reset}   #{@white}#{src}#{@reset}"
    else
      "#{n}│   #{src}"
    end
  end

  # Subject line — colored differently for primary (error site) vs secondary (decl)
  defp format_source_line(num, src, :subject, role, color?) do
    n = String.pad_leading("#{num}", 3)
    src_colored = if color? do
      # Highlight backtick-quoted names in bold white
      src_hl = Regex.replace(~r/`[^`]+`/, src, fn m ->
        "#{@bold_white}#{m}#{@reset}#{@white}"
      end)
      case role do
        :primary   -> "#{@bold_cyan}#{n}│#{@reset}   #{@white}#{src_hl}#{@reset}"
        :secondary -> "#{@bold_cyan}#{n}│#{@reset}   #{@cyan}#{src_hl}#{@reset}"
      end
    else
      "#{n}│   #{src}"
    end
    src_colored
  end

  defp format_underlines(primary, secondary, role, color?) do
    # Collect all underline specs: [{col, len, label, kind}]
    all = []
    all = if primary,
      do:   [{primary, :primary} | all],
      else: all
    all = all ++ Enum.map(secondary, &{&1, :secondary})

    # Sort by column position
    all = Enum.sort_by(all, fn {{col, _len, _label}, _kind} -> col end)

    # Build caret string
    {caret_str, _} = Enum.reduce(all, {"   │   ", 0}, fn {{col, len, _label}, kind}, {buf, pos} ->
      pad   = max(col - pos - 1, 0)
      char  = if kind == :primary, do: "^", else: "-"
      chars = String.duplicate(char, max(len, 1))
      {buf <> String.duplicate(" ", pad) <> chars, pos + pad + len}
    end)

    # Build label string
    {label_str, _} = Enum.reduce(all, {"   │   ", 0}, fn {{col, len, label}, _kind}, {buf, pos} ->
      if label && label != "" do
        pad = max(col - pos - 1, 0)
        {buf <> String.duplicate(" ", pad) <> label, pos + pad + String.length(label)}
      else
        {buf, pos + max(len, 1)}
      end
    end)

    if color? do
      # Color carets by role
      caret_colored = caret_str
        |> String.replace(~r/\^+/, fn m ->
          case role do
            :primary   -> "#{@bold_red}#{m}#{@reset}"
            :secondary -> "#{@red}#{m}#{@reset}"
          end
        end)
        |> String.replace(~r/-+/, fn m -> "#{@cyan}#{m}#{@reset}" end)

      # Color labels
      label_colored = label_str
        |> String.replace(~r/width \d+/, fn m -> "#{@yellow}#{m}#{@reset}" end)
        |> String.replace(~r/`[^`]+`/, fn m -> "#{@bold_white}#{m}#{@reset}" end)

      "#{caret_colored}\n#{label_colored}"
    else
      "#{caret_str}\n#{label_str}"
    end
  end

  defp format_note(text, color?) do
    text_colored = if color? do
      text
      |> String.replace(~r/`[^`]+`/, fn m -> "#{@bold_white}#{m}#{@yellow}" end)
    else
      text
    end

    if color? do
      "  #{@bold_cyan}└─#{@reset} #{@yellow}note:#{@reset} #{@yellow}#{text_colored}#{@reset}"
    else
      "  └─ note: #{text}"
    end
  end

  defp format_hint(text, color?) do
    if color? do
      # Hint text: bold green label, then monospace-style code in green
      text_colored = text
        |> String.replace(~r/`[^`]+`/, fn m -> "#{@bold_white}#{m}#{@green}" end)
      "  #{@bold_cyan}└─#{@reset} #{@bold_green}hint:#{@reset} #{@green}#{text_colored}#{@reset}"
    else
      "  └─ hint: #{text}"
    end
  end

  defp format_footer(mod, message, color?) do
    if color? do
      "\n#{@bold_red}** (#{mod})#{@reset} #{@white}#{message}#{@reset}"
    else
      "\n** (#{mod}) #{message}"
    end
  end

  defp format_gutter_char(char, color?) do
    if color?,
      do:   "  #{@bold_cyan}#{char}#{@reset}",
      else: "  #{char}"
  end

  # ── Source reading ─────────────────────────────────────────────────────────

  defp read_source(file, line) do
    case File.read(file) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {_, n} -> n >= line - 1 and n <= line + 1 end)
        |> Map.new(fn {text, n} -> {n, text} end)
      {:error, _} ->
        %{}
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp severity_label(:error),   do: "error"
  defp severity_label(:warning), do: "warning"
  defp severity_label(:note),    do: "note"

  defp severity_label_color(:error),   do: @bold_red
  defp severity_label_color(:warning), do: @bold_yellow
  defp severity_label_color(:note),    do: @bold_cyan

  # Gutter │ character
  defp g(true),  do: "  #{@bold_cyan}│#{@reset}"
  defp g(false), do: "  │"

  # Anchor └─ character
  defp anc(true),  do: "  #{@bold_cyan}└─#{@reset}"
  defp anc(false), do: "  └─"
end
