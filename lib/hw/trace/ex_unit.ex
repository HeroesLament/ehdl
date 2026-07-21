defmodule Hw.Trace.ExUnit do
  @moduledoc """
  ExUnit assertions over a unified `Hw.Trace`.

  This is the engine-agnostic assertion surface: the same `assert_at`,
  `assert_stable`, `assert_sequence`, `assert_reaches`, and `assert_waveform`
  helpers that `Hw.Waveform.ExUnit` provided, but operating on a `Hw.Trace` — so
  the identical assertions run against NIF-backed traces AND live-engine traces
  (via `Hw.Simtrace.to_trace/1`).

  Signals are referenced by any form the trace resolves: a flat name (`:txd`),
  a dotted string/atom (`"sie.rx_state"`), or an `{scope, leaf}` address.

  ## Note on `assert_stable`

  The cycle number reported on failure is the *absolute* sample index at which
  the signal changed — correct even when the stability window does not start at
  cycle 0. (The predecessor in `Hw.Waveform.assert_stable` computed this from
  `range.first + 1`, which drifted for non-zero windows; that is fixed here.)
  """

  alias Hw.Trace
  alias Hw.Trace.{Query, Render}

  # ---------------------------------------------------------------------------
  # assert_at
  # ---------------------------------------------------------------------------

  @doc """
  Assert a signal's value at a specific cycle (sample index).

      assert_at trace, :count, cycle: 3, value: 3
  """
  @spec assert_at(Trace.t(), atom() | String.t() | Trace.addr(), keyword()) :: :ok
  def assert_at(%Trace{} = trace, signal, opts) do
    cycle = Keyword.fetch!(opts, :cycle)
    expected = Keyword.fetch!(opts, :value)
    actual = Trace.at(trace, signal, cycle)

    if actual != expected do
      meta = Trace.meta(trace, signal)

      raise ExUnit.AssertionError,
        left: actual,
        right: expected,
        message: """
        Trace signal mismatch at cycle #{cycle}
          signal:   #{inspect(signal)}
          expected: #{fmt(expected, meta)}
          actual:   #{fmt(actual, meta)}
        """
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # assert_stable
  # ---------------------------------------------------------------------------

  @doc """
  Assert a signal holds a constant value across a cycle range.

      assert_stable trace, :valid, during: 5..10
      assert_stable trace, :valid, value: 1, during: 5..10
  """
  @spec assert_stable(Trace.t(), atom() | String.t() | Trace.addr(), keyword()) :: :ok
  def assert_stable(%Trace{} = trace, signal, opts) do
    range =
      Keyword.get(opts, :during) ||
        window_cycle_range(trace, opts[:window]) ||
        0..(Trace.count(trace) - 1)

    expected = Keyword.get(opts, :value, nil)

    # Pair each in-range value with its ABSOLUTE cycle index, so a reported
    # "changed at cycle N" is correct for any window start.
    indexed =
      Enum.map(range, fn cycle -> {Trace.at(trace, signal, cycle), cycle} end)

    if indexed == [] do
      raise """
      Trace assertion failed: #{inspect(signal)} has no samples in range #{inspect(range)}
        (#{Trace.count(trace)} cycles recorded, range #{inspect(range)} out of bounds)
      """
    end

    [{head, _} | rest] = indexed
    expected = expected || head

    case Enum.find(rest, fn {v, _cycle} -> v != expected end) do
      nil ->
        :ok

      {actual, cycle} ->
        meta = Trace.meta(trace, signal)

        raise """
        Trace assertion failed: #{inspect(signal)} not stable during #{inspect(range)}
          expected: #{fmt(expected, meta)}
          changed to #{fmt(actual, meta)} at cycle #{cycle}
        """
    end
  end

  # ---------------------------------------------------------------------------
  # assert_sequence
  # ---------------------------------------------------------------------------

  @doc """
  Assert a signal transitions through a sequence of values across consecutive
  cycles, starting at `from:` (default 0).

      assert_sequence trace, :rx_state, [0, 1, 2, 1, 0]
      assert_sequence trace, :rx_state, [0, 1, 2], from: 5
  """
  @spec assert_sequence(Trace.t(), atom() | String.t() | Trace.addr(), [integer()], keyword()) :: :ok
  def assert_sequence(%Trace{} = trace, signal, expected_seq, opts \\ []) do
    start = Keyword.get(opts, :from, 0)
    last = start + length(expected_seq) - 1
    actual_seq = Enum.map(start..last, &Trace.at(trace, signal, &1))

    if actual_seq != expected_seq do
      meta = Trace.meta(trace, signal)
      actual_str = Enum.map_join(actual_seq, " ", &fmt(&1, meta))
      expected_str = Enum.map_join(expected_seq, " ", &fmt(&1, meta))

      raise """
      Trace assertion failed: #{inspect(signal)} sequence mismatch (cycles #{start}..#{last})
        expected: #{expected_str}
        actual:   #{actual_str}
      """
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # assert_reaches
  # ---------------------------------------------------------------------------

  @doc """
  Assert a signal reaches a target value by a given cycle.

      assert_reaches trace, :done, 1, by: 20
  """
  @spec assert_reaches(Trace.t(), atom() | String.t() | Trace.addr(), integer(), keyword()) :: :ok
  def assert_reaches(%Trace{} = trace, signal, target, opts \\ []) do
    # `window:` scopes the search to the window's cycle range; `by:` sets the
    # deadline (from cycle 0). window: takes precedence when given.
    search_range =
      case window_cycle_range(trace, opts[:window]) do
        nil -> 0..Keyword.get(opts, :by, Trace.count(trace) - 1)
        range -> range
      end

    found = Enum.any?(search_range, fn cycle -> Trace.at(trace, signal, cycle) == target end)

    unless found do
      meta = Trace.meta(trace, signal)
      final = Trace.at(trace, signal, Enum.max(search_range))

      raise """
      Trace assertion failed: #{inspect(signal)} never reached #{fmt(target, meta)} within #{inspect(search_range)}
        final value: #{fmt(final, meta)}
      """
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # assert_waveform / print_waveform
  # ---------------------------------------------------------------------------

  @doc """
  Assert the rendered waveform matches an expected ASCII string
  (whitespace-normalised). Expect-test style.
  """
  defmacro assert_waveform(trace, expected, opts \\ []) do
    quote bind_quoted: [trace: trace, expected: expected, opts: opts] do
      Hw.Trace.ExUnit.__assert_waveform__(trace, expected, opts)
    end
  end

  @doc false
  def __assert_waveform__(%Trace{} = trace, expected, opts) do
    actual = Render.ascii(trace, opts)
    na = normalise(actual)
    ne = normalise(expected)

    if na != ne do
      raise ExUnit.AssertionError,
        left: na,
        right: ne,
        message: "Waveform mismatch (normalised):\n--- expected ---\n#{ne}\n--- actual ---\n#{na}",
        expr: quote(do: assert_waveform)
    end

    :ok
  end

  @doc "Print the rendered waveform to stdout (no assertion)."
  @spec print_waveform(Trace.t(), keyword()) :: :ok
  def print_waveform(%Trace{} = trace, opts \\ []) do
    IO.puts("\n" <> Render.ascii(trace, opts))
    :ok
  end

  @doc "Convenience: `find_when` entries matching a condition (delegates to Query)."
  @spec find_when(Trace.t(), keyword(), fun() | keyword()) :: [map()]
  def find_when(%Trace{} = trace, opts, conditions), do: Query.find_when(trace, opts, conditions)

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  # Resolve a window label (or %Window{}, or nil) to its first..last in-window
  # sample-index range, or nil if there is no window / no samples in it.
  defp window_cycle_range(_trace, nil), do: nil

  defp window_cycle_range(%Trace{} = trace, window) do
    w =
      case window do
        %Hw.Trace.Window{} = w -> w
        label -> Trace.window(trace, label) || raise(ArgumentError, "unknown window #{inspect(label)}")
      end

    {from_ps, to_ps} = Hw.Trace.Window.bounds(w, trace.last_time_ps)

    indices =
      trace
      |> Trace.samples()
      |> Enum.filter(fn s -> s.time_ps >= from_ps and s.time_ps <= to_ps end)
      |> Enum.map(& &1.index)

    case indices do
      [] -> nil
      _ -> Enum.min(indices)..Enum.max(indices)
    end
  end

  defp fmt(nil, _), do: "nil"
  defp fmt(v, nil), do: Integer.to_string(v)
  defp fmt(v, %{hint: {:enum, m}}), do: Map.get(m, v, Integer.to_string(v))
  defp fmt(v, %{hint: :hex}), do: "0x" <> Integer.to_string(v, 16)
  defp fmt(v, _), do: Integer.to_string(v)

  defp normalise(str) do
    str
    |> String.trim()
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end
end
