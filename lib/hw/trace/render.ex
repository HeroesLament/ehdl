defmodule Hw.Trace.Render do
  @moduledoc """
  The single ASCII waveform renderer for `Hw.Trace`.

  This merges the two near-duplicate renderers that previously lived in
  `Hw.Waveform` (cycle-indexed, hint-aware) and `Hw.Simtrace.Waveform`
  (ps-indexed, decimal-only). The row body is identical between them; the only
  real differences were value formatting (hint-aware vs `Integer.to_string`) and
  the index axis (cycle numbers vs `t=…ps`). Both collapse here: rows are
  rendered from `{label, width, hint, series}` + a column count, and the axis is
  a small header strategy on top.

  Signals render grouped by scope, so the output reads as a design tree
  (matching how GTKWave / Hardcaml's viewer present hierarchy).
  """

  import Bitwise

  alias Hw.Trace

  @label_col 22

  @doc """
  Render a trace as an ASCII waveform string.

  ## Options
    * `:signals` — list of signal refs to render (default: all tracked).
    * `:width`   — total display width in columns (default: 80).
    * `:group`   — `:scope` (default) groups rows under scope headers; `:flat`
                   renders a single ungrouped block.
    * `:axis`    — `:index` (default, cycle numbers) or `:time` (ps header).
    * `:window`  — a transaction-span label (or `%Hw.Trace.Window{}`): render
                   only the samples inside its ps bounds, with a labeled phase
                   band above the waveform.
  """
  @spec ascii(Trace.t(), keyword()) :: String.t()
  def ascii(%Trace{} = trace, opts \\ []) do
    width = Keyword.get(opts, :width, 80)
    group = Keyword.get(opts, :group, :scope)
    n_cols = max(width - @label_col, 8)

    metas = selected_metas(trace, Keyword.get(opts, :signals))

    # Resolve `window:` to the in-window sample indices (nil = all samples).
    window = Keyword.get(opts, :window)
    win_indices = window_indices(trace, window)

    series_fn = fn addr -> windowed_series(trace, addr, win_indices) end

    band = phase_band(trace, window, n_cols)
    header = axis_header(trace, Keyword.get(opts, :axis, :index), n_cols)

    body =
      case group do
        :flat ->
          Enum.map_join(metas, "\n", &render_row(&1, series_fn, n_cols))

        :scope ->
          metas
          |> Enum.group_by(fn %{addr: {scope, _}} -> List.first(scope) end)
          |> Enum.sort_by(fn {scope, _} -> Atom.to_string(scope) end)
          |> Enum.map_join("\n", fn {scope, group_metas} ->
            rows = Enum.map_join(group_metas, "\n", &render_row(&1, series_fn, n_cols))
            "#{scope}\n#{rows}"
          end)
      end

    [band, header, body] |> Enum.reject(&(&1 == "")) |> Enum.join("\n")
  end

  # --- window resolution ----------------------------------------------------

  defp window_indices(_trace, nil), do: :all

  defp window_indices(trace, window) do
    w = resolve_window_struct(trace, window)
    {from_ps, to_ps} = Hw.Trace.Window.bounds(w, trace.last_time_ps)

    trace
    |> Trace.samples()
    |> Enum.filter(fn s -> s.time_ps >= from_ps and s.time_ps <= to_ps end)
    |> Enum.map(& &1.index)
    |> MapSet.new()
  end

  defp resolve_window_struct(_trace, %Hw.Trace.Window{} = w), do: w

  defp resolve_window_struct(trace, label) do
    case Hw.Trace.window(trace, label) do
      nil -> raise ArgumentError, "unknown window #{inspect(label)}"
      w -> w
    end
  end

  defp windowed_series(trace, addr, :all), do: Trace.values(trace, addr)

  defp windowed_series(trace, addr, index_set) do
    init = trace.signals[addr].init

    trace
    |> Trace.samples()
    |> Enum.filter(fn s -> MapSet.member?(index_set, s.index) end)
    |> Enum.map(fn s -> Map.get(s.values, addr, init) end)
  end

  # A labeled band above the waveform naming the rendered phase.
  defp phase_band(_trace, nil, _n_cols), do: ""

  defp phase_band(trace, window, n_cols) do
    w = resolve_window_struct(trace, window)
    label = to_string(w.label)
    bar = String.duplicate("═", max(n_cols - String.length(label) - 2, 0))
    "  #{String.duplicate(" ", @label_col - 2)}╔ #{label} #{bar}"
  end

  # --- rows -----------------------------------------------------------------

  defp render_row(meta, series_fn, n_cols) do
    series = series_fn.(meta.addr)
    {_scope, leaf} = meta.addr
    label = leaf |> Atom.to_string() |> String.slice(0, @label_col - 3) |> String.pad_trailing(@label_col - 2)
    "  #{label}#{render_series(series, meta, n_cols)}"
  end

  @doc false
  # 1-bit signals render as edge glyphs; multi-bit as run labels + fill.
  def render_series(values, %{width: 1}, n_cols) do
    cols = sample_to_columns(values, n_cols)

    cols
    |> Enum.with_index()
    |> Enum.map_join("", fn {v, i} ->
      prev = if i > 0, do: Enum.at(cols, i - 1), else: v

      cond do
        prev == 0 and v == 1 -> "/"
        prev == 1 and v == 0 -> "\\"
        v == 1 -> "‾"
        true -> "_"
      end
    end)
  end

  def render_series(values, meta, n_cols) do
    cols = sample_to_columns(values, n_cols)

    Enum.chunk_by(cols, & &1)
    |> Enum.map(fn run -> {hd(run), length(run)} end)
    |> Enum.flat_map(fn {val, len} ->
      label = format_value(val, meta)

      if len <= String.length(label) + 1 do
        List.duplicate("─", len)
      else
        [label | List.duplicate("─", len - String.length(label))]
      end
    end)
    |> IO.iodata_to_binary()
  end

  @doc false
  # Resample a value series to exactly n_cols columns (upsample by proportional
  # repeat, downsample by even index picking). Lifted verbatim from the two
  # identical copies it replaces.
  def sample_to_columns(values, n_cols) do
    n = length(values)

    cond do
      n == 0 ->
        List.duplicate(0, n_cols)

      n <= n_cols ->
        scale = n_cols / n

        Enum.flat_map(Enum.with_index(values), fn {v, i} ->
          count = round((i + 1) * scale) - round(i * scale)
          List.duplicate(v, max(count, 1))
        end)
        |> Enum.take(n_cols)

      true ->
        Enum.map(0..(n_cols - 1), fn col ->
          idx = round(col * (n - 1) / (n_cols - 1))
          Enum.at(values, idx, 0)
        end)
    end
  end

  @doc false
  # The single hint-aware value formatter (previously duplicated 3×).
  def format_value(val, %{hint: :bit}), do: Integer.to_string(band(val, 1))
  def format_value(val, %{hint: :hex}), do: "0x" <> Integer.to_string(val, 16)
  def format_value(val, %{hint: :unsigned}), do: Integer.to_string(val)

  def format_value(val, %{hint: :signed, width: w}) do
    signed = if bsr(val, w - 1) == 1, do: val - bsl(1, w), else: val
    Integer.to_string(signed)
  end

  def format_value(val, %{hint: {:enum, map}}) do
    Map.get(map, val, Integer.to_string(val))
  end

  def format_value(val, _), do: Integer.to_string(val)

  # --- axis header ----------------------------------------------------------

  defp axis_header(trace, :index, n_cols) do
    n = Trace.count(trace)
    if n == 0, do: "", else: "  #{String.duplicate(" ", @label_col - 2)}#{index_ruler(n, n_cols)}"
  end

  defp axis_header(trace, :time, _n_cols) do
    samples = Trace.samples(trace)

    case samples do
      [] ->
        ""

      _ ->
        first = List.first(samples).time_ps
        last = List.last(samples).time_ps
        "  t=#{first}ps → t=#{last}ps  (#{Trace.count(trace)} samples)"
    end
  end

  defp index_ruler(n, n_cols) do
    cols = min(n, n_cols)

    0..(cols - 1)
    |> Enum.map_join("", fn c ->
      idx = round(c * (n - 1) / max(cols - 1, 1))
      Integer.to_string(rem(idx, 10))
    end)
  end

  # --- selection ------------------------------------------------------------

  defp selected_metas(trace, nil) do
    trace.signals |> Map.values() |> Enum.sort_by(&{Atom.to_string(elem(&1.addr, 0) |> List.first()), Atom.to_string(elem(&1.addr, 1))})
  end

  defp selected_metas(trace, refs) when is_list(refs) do
    refs
    |> Enum.map(&Trace.meta(trace, &1))
    |> Enum.reject(&is_nil/1)
  end
end
