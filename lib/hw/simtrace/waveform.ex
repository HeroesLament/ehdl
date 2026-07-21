defmodule Hw.Simtrace.Waveform do
  @moduledoc """
  ASCII waveform rendering for sim register traces.

  Renders multi-valued signals (not just 1-bit) using a compact notation:

    - 1-bit signals: `_` for 0, `‾` for 1, `/` rising edge, `\\` falling edge
    - Multi-bit signals: numeric value changes shown inline, e.g.
        rx_state  0────1──2──────0──────

  Column width adapts to terminal width. Each column represents one
  recorded tick (one clock edge).
  """

  alias Hw.Simtrace
  alias Hw.Simtrace.Query

  @default_width   80
  @default_ticks   64
  @label_col_width 22

  # Signals shown by usb_waveform/2, grouped by entity
  @usb_signals %{
    phy: [:phase, :rx_state, :rx_ones, :tx_state, :tx_ones, :prev_diff],
    sie: [:rx_state, :tx_state, :sync_cnt, :bit_cnt, :send_handshake,
          :token_is_in_reg, :token_is_out_reg, :token_is_setup_reg,
          :token_addr_match_reg, :ep_in_nak, :ep_in_done, :ep_out_valid],
    cdc: [:dev_state, :ep0_state, :ep1_in_busy, :addr_pending,
          :ep_in_loaded, :ep_in_valid, :out_valid],
  }

  # ---------------------------------------------------------------------------
  # Public
  # ---------------------------------------------------------------------------

  def print(%Simtrace{} = st, entity, registers, opts) do
    width  = Keyword.get(opts, :width, @default_width)
    n_cols = width - @label_col_width

    tl = Query.timeline(st, entity, Keyword.take(opts, [:from, :to, :only]))
    tl = limit_ticks(tl, Keyword.get(opts, :ticks, @default_ticks))

    if Enum.empty?(tl) do
      IO.puts("(no data recorded for #{entity})")
      :ok
    else
      first_t = hd(tl).time_ps
      last_t  = List.last(tl).time_ps
      IO.puts("")
      IO.puts("#{entity}  t=#{fmt_ps(first_t)} → t=#{fmt_ps(last_t)}  (#{length(tl)} ticks)")
      IO.puts("")

      # Determine which registers to render
      regs = if registers == :all do
        hd(tl).state |> Map.keys() |> Enum.sort()
      else
        registers
      end

      Enum.each(regs, fn reg ->
        values = Enum.map(tl, fn e -> Map.get(e.state, reg, 0) end)
        widths = Map.new(
          st.schedule.signal_widths,
          &{elem(&1, 0), elem(&1, 1)}
        )
        sig_width = Map.get(widths, reg, 1)
        label     = String.pad_trailing("  #{reg}", @label_col_width)
        row       = render_signal(values, sig_width, n_cols)
        IO.puts(label <> row)
      end)

      IO.puts("")
      :ok
    end
  end

  def print_usb(%Simtrace{} = st, opts) do
    entities = Enum.filter(st.entity_names, &Map.has_key?(@usb_signals, &1))
    Enum.each(entities, fn entity ->
      regs = Map.get(@usb_signals, entity, [])
      print(st, entity, regs, opts)
    end)
  end

  # ---------------------------------------------------------------------------
  # Signal rendering
  # ---------------------------------------------------------------------------

  # 1-bit signal: use ‾ / _ with / \ for edges
  defp render_signal(values, 1, n_cols) do
    cols = sample_to_columns(values, n_cols)

    cols
    |> Enum.with_index()
    |> Enum.map(fn {v, i} ->
      prev = if i > 0, do: Enum.at(cols, i - 1), else: v
      cond do
        prev == 0 and v == 1 -> "/"
        prev == 1 and v == 0 -> "\\"
        v == 1               -> "‾"
        true                 -> "_"
      end
    end)
    |> IO.iodata_to_binary()
  end

  # Multi-bit signal: show value, pad with dashes until next change
  defp render_signal(values, _sig_width, n_cols) do
    cols = sample_to_columns(values, n_cols)

    # Build runs of equal value
    runs = Enum.chunk_by(cols, & &1)
    |> Enum.map(fn run -> {hd(run), length(run)} end)

    Enum.flat_map(runs, fn {val, len} ->
      label = Integer.to_string(val)
      if len <= String.length(label) + 1 do
        # Not enough room — just dashes
        List.duplicate("-", len)
      else
        # Value label followed by dashes to fill the run
        pad = len - String.length(label)
        [label | List.duplicate("─", pad)]
      end
    end)
    |> IO.iodata_to_binary()
  end

  # Downsample or upsample values list to exactly n_cols columns
  defp sample_to_columns(values, n_cols) do
    n = length(values)
    cond do
      n == 0     -> List.duplicate(0, n_cols)
      n <= n_cols ->
        # Upsample: repeat each value proportionally
        scale = n_cols / n
        Enum.flat_map(Enum.with_index(values), fn {v, i} ->
          count = round((i + 1) * scale) - round(i * scale)
          List.duplicate(v, max(count, 1))
        end)
        |> Enum.take(n_cols)
      true ->
        # Downsample: pick evenly spaced samples
        Enum.map(0..(n_cols - 1), fn col ->
          idx = round(col * (n - 1) / (n_cols - 1))
          Enum.at(values, idx, 0)
        end)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp limit_ticks(tl, n), do: Enum.take(tl, n)

  defp fmt_ps(ps) when ps >= 1_000_000_000, do: "#{Float.round(ps / 1_000_000_000, 2)}s"
  defp fmt_ps(ps) when ps >= 1_000_000,     do: "#{Float.round(ps / 1_000_000, 2)}μs"
  defp fmt_ps(ps) when ps >= 1_000,         do: "#{Float.round(ps / 1_000, 2)}ns"
  defp fmt_ps(ps),                           do: "#{ps}ps"
end
