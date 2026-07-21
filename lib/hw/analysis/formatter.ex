defmodule Hw.Analysis.Formatter do
  @moduledoc """
  Renders `Hw.Analysis.Diagnostic` structs as human-readable CLI output.

  Output style is inspired by the Rust compiler — each diagnostic gets
  a header line with severity and location, a body with context, and
  related locations shown as secondary annotations.

  ## Example output

      ── Width Mismatch ──────────────────── lib/hw/usb/top.ex:42 ──

        connect :sie, :tx → :cdc, :tx

        signal :byte_data
          SIE  provides  Signal.t(8)    lib/hw/usb/sie.ex:31
          CDC  consumes  Signal.t(16)   lib/hw/usb/cdc.ex:28
                                ^^^
                                expected 1-bit, got 16-bit

      ── Missing Signal ──────────────────── lib/hw/usb/top.ex:42 ──

        CDC(:tx) consumes :pkt_ack but SIE(:tx) does not provide it.

        hint: did you mean :pkt_done? (declared at lib/hw/usb/sie.ex:45)

      2 errors, 0 warnings.
  """

  alias Hw.Analysis.{Diagnostic, Location}

  # ANSI colour codes — disabled when not a TTY or when mix env is test
  @red     "\e[31m"
  @yellow  "\e[33m"
  @cyan    "\e[36m"
  @grey    "\e[90m"
  @bold    "\e[1m"
  @reset   "\e[0m"
  @width   80

  @doc """
  Render a list of diagnostics to a string suitable for printing to stderr.

  Pass `ansi: false` to disable colour codes (e.g. for CI or log files).
  """
  @spec render([Diagnostic.t()], keyword()) :: String.t()
  def render(diagnostics, opts \\ []) do
    ansi = Keyword.get(opts, :ansi, ansi_enabled?())
    sorted = Diagnostic.sort(diagnostics)

    body = sorted
    |> Enum.map(&render_diagnostic(&1, ansi))
    |> Enum.join("\n")

    summary = render_summary(diagnostics, ansi)

    if body == "" do
      summary
    else
      body <> "\n" <> summary
    end
  end

  @doc """
  Print diagnostics to stderr and return `:ok` or `:error`.
  """
  @spec print([Diagnostic.t()], keyword()) :: :ok | :error
  def print(diagnostics, opts \\ []) do
    IO.write(:stderr, render(diagnostics, opts))
    if Diagnostic.has_errors?(diagnostics), do: :error, else: :ok
  end

  # ---------------------------------------------------------------------------
  # Private rendering
  # ---------------------------------------------------------------------------

  defp render_diagnostic(%Diagnostic{} = d, ansi) do
    header = render_header(d, ansi)
    body   = render_body(d, ansi)
    related = render_related(d.related, ansi)

    [header, body, related]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp render_header(%Diagnostic{severity: sev, code: code, location: loc}, ansi) do
    label     = format_code(code)
    loc_str   = Location.to_string(loc)
    sev_color = severity_color(sev, ansi)

    # ── Width Mismatch ──────────────────── lib/hw/usb/top.ex:42 ──
    title     = "#{sev_color}── #{label}#{color(:reset, ansi)}"
    right     = "#{color(:grey, ansi)} #{loc_str} ──#{color(:reset, ansi)}"

    # Fill dashes between title and right
    # Strip ANSI for length calculation
    title_len = String.length(strip_ansi(title))
    right_len = String.length(strip_ansi(right))
    dashes    = max(2, @width - title_len - right_len)
    fill      = String.duplicate("─", dashes)

    "\n#{title}#{color(:grey, ansi)}#{fill}#{color(:reset, ansi)}#{right}"
  end

  defp render_body(%Diagnostic{message: msg, context: ctx, code: code}, ansi) do
    base = "\n  #{msg}"
    extra = render_context(code, ctx, ansi)
    if extra == "", do: base, else: base <> "\n" <> extra
  end

  # Code-specific context rendering
  defp render_context(:width_mismatch, ctx, ansi) do
    %{signal: sig, provider_width: pw, consumer_width: cw,
      provider_loc: ploc, consumer_loc: cloc,
      provider_label: plabel, consumer_label: clabel} = ctx

    pw_str = "Signal.t(#{pw})"
    cw_str = "Signal.t(#{cw})"
    max_label = max(String.length(plabel), String.length(clabel))
    max_type  = max(String.length(pw_str), String.length(cw_str))

    p_line = "    #{String.pad_trailing(plabel, max_label)}  provides  " <>
             "#{String.pad_trailing(pw_str, max_type)}  " <>
             "#{color(:grey, ansi)}#{Location.short(ploc)}#{color(:reset, ansi)}"

    c_line = "    #{String.pad_trailing(clabel, max_label)}  consumes  " <>
             "#{String.pad_trailing(cw_str, max_type)}  " <>
             "#{color(:grey, ansi)}#{Location.short(cloc)}#{color(:reset, ansi)}"

    mismatch_col = String.length("    #{String.pad_trailing(plabel, max_label)}  consumes  ")
    arrow = String.duplicate(" ", mismatch_col) <>
            color(:red, ansi) <>
            String.duplicate("^", String.length(cw_str)) <>
            color(:reset, ansi)

    "\n  #{color(:bold, ansi)}signal #{sig}#{color(:reset, ansi)}\n" <>
    p_line <> "\n" <>
    c_line <> "\n" <>
    arrow

  end

  defp render_context(:missing_signal, ctx, ansi) do
    case ctx[:suggestion] do
      nil -> ""
      suggestion ->
        loc_str = if ctx[:suggestion_loc],
          do: " (declared at #{Location.short(ctx.suggestion_loc)})",
          else: ""
        "\n  #{color(:grey, ansi)}hint: did you mean #{suggestion}?#{loc_str}#{color(:reset, ansi)}"
    end
  end

  defp render_context(_code, _ctx, _ansi), do: ""

  defp render_related([], _ansi), do: ""
  defp render_related(related, ansi) do
    lines = Enum.map(related, fn r ->
      loc = Location.to_string(r.location)
      "  #{color(:grey, ansi)}→ #{loc}: #{r.message}#{color(:reset, ansi)}"
    end)
    "\n" <> Enum.join(lines, "\n")
  end

  defp render_summary(diagnostics, ansi) do
    errors   = Enum.count(diagnostics, &(&1.severity == :error))
    warnings = Enum.count(diagnostics, &(&1.severity == :warning))
    hints    = Enum.count(diagnostics, &(&1.severity == :hint))

    e_str = if errors > 0,
      do: "#{color(:red, ansi)}#{errors} error#{plural(errors)}#{color(:reset, ansi)}",
      else: "#{color(:grey, ansi)}0 errors#{color(:reset, ansi)}"

    w_str = if warnings > 0,
      do: "#{color(:yellow, ansi)}#{warnings} warning#{plural(warnings)}#{color(:reset, ansi)}",
      else: "#{color(:grey, ansi)}0 warnings#{color(:reset, ansi)}"

    h_str = if hints > 0,
      do: "#{hints} hint#{plural(hints)}",
      else: nil

    parts = [e_str, w_str, h_str] |> Enum.reject(&is_nil/1)
    "\n" <> Enum.join(parts, ", ") <> ".\n"
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp format_code(code) do
    code
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp severity_color(:error,   ansi), do: color(:red, ansi)    <> color(:bold, ansi)
  defp severity_color(:warning, ansi), do: color(:yellow, ansi) <> color(:bold, ansi)
  defp severity_color(:hint,    ansi), do: color(:cyan, ansi)
  defp severity_color(:info,    ansi), do: color(:grey, ansi)

  defp color(:red,   true),   do: @red
  defp color(:yellow, true),  do: @yellow
  defp color(:cyan,  true),   do: @cyan
  defp color(:grey,  true),   do: @grey
  defp color(:bold,  true),   do: @bold
  defp color(:reset, true),   do: @reset
  defp color(_,      false),  do: ""

  defp strip_ansi(str) do
    Regex.replace(~r/\e\[[0-9;]*m/, str, "")
  end

  defp plural(1), do: ""
  defp plural(_), do: "s"

  defp ansi_enabled? do
    System.get_env("NO_COLOR") == nil and
    System.get_env("MIX_ENV") != "test" and
    match?({:ok, _}, :io.columns())
  end
end
