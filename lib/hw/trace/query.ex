defmodule Hw.Trace.Query do
  @moduledoc """
  Engine-agnostic query verbs over a `Hw.Trace`.

  These are the ports of the `Hw.Simtrace` verbs (`timeline`, `find_when`,
  `first`, `transitions`, `diff`, `snapshot`), now operating on `Hw.Trace`
  samples instead of ElixirScope's per-entity `reg_state` timeline. Because a
  trace holds one unified signal space, every verb works across *both* engines
  and — the headline win — across top-level ports as well as entity registers,
  which `Hw.Simtrace` never reached.

  ## Scope

  Verbs take an optional `scope:` filter. Within a scope, conditions and diffs
  key on the bare leaf name (`rx_state: 2`), matching how `Hw.Simtrace` scoped by
  entity. Without a scope, they key on any signal reference the trace resolves
  (flat name, dotted `"top.led"`, or an `{scope, leaf}` address) and range across
  the whole design.

  ## Axis

  A trace carries both a sample `index` (cycle number) and a `time_ps`. Queries
  return entries `%{index:, time_ps:, state:}` so callers can key on either.
  `diff/4` and `at/3` accept `{:index, n}`, `{:time, ps}`, `:first`, or `:last`.
  """

  alias Hw.Trace

  @type point :: :first | :last | {:index, non_neg_integer()} | {:time, non_neg_integer()}

  @doc """
  The ordered timeline of samples as `[%{index, time_ps, state}]`, where `state`
  is a leaf/value map.

  ## Options
    * `:scope` — restrict `state` to one scope's signals, keyed by leaf name.
      Without it, `state` keys are `{scope, leaf}` addresses (whole design).
    * `:only` — list of signal refs to keep in `state`.
    * `:from` / `:to` — inclusive `time_ps` window.
    * `:window` — a transaction-span label (or `%Hw.Trace.Window{}`) whose ps
      bounds scope the query. Sugar over `:from`/`:to`; an explicit `:from`/`:to`
      overrides it. Every verb that funnels through `timeline/2` (`find_when`,
      `transitions`, `diff`, `snapshot`) inherits `:window`.
  """
  @spec timeline(Trace.t(), keyword()) :: [map()]
  def timeline(%Trace{} = trace, opts \\ []) do
    scope = Keyword.get(opts, :scope)
    only = Keyword.get(opts, :only)
    # `window:` resolves a named span's ps bounds into from:/to:. An explicit
    # from:/to: still takes precedence if given alongside it. This is the ONE
    # place window resolution happens — every verb funnels through timeline/2,
    # so find_when/transitions/diff/snapshot all inherit `window:` for free.
    {win_from, win_to} = resolve_window(trace, Keyword.get(opts, :window))
    from_ps = Keyword.get(opts, :from, win_from)
    to_ps = Keyword.get(opts, :to, win_to)

    only_addrs = only && Enum.map(only, &Trace.address(trace, &1)) |> reject_nils()

    trace
    |> Trace.samples()
    |> filter_time(from_ps, to_ps)
    |> Enum.map(fn sample ->
      %{index: sample.index, time_ps: sample.time_ps, state: project(sample.values, scope, only_addrs)}
    end)
  end

  @doc """
  All timeline entries where a condition holds.

  Conditions are either a `fn state -> boolean end` or a keyword list. With a
  `scope:`, keyword keys are leaf names; without, they are any resolvable signal
  ref.

      find_when(trace, [scope: :sie], rx_state: 2, tx_state: 0)
      find_when(trace, [], "top.led": 0xFF)          # a PORT — new capability
      find_when(trace, [], fn s -> s[{[:sie], :rx_state}] == 2 end)
  """
  @spec find_when(Trace.t(), keyword(), fun() | keyword()) :: [map()]
  def find_when(%Trace{} = trace, opts, conditions) when is_function(conditions, 1) do
    trace |> timeline(opts) |> Enum.filter(fn e -> conditions.(e.state) end)
  end

  def find_when(%Trace{} = trace, opts, conditions) when is_list(conditions) do
    scope = Keyword.get(opts, :scope)
    keyed = normalize_conditions(trace, scope, conditions)

    trace
    |> timeline(opts)
    |> Enum.filter(fn e ->
      Enum.all?(keyed, fn {key, val} -> Map.get(e.state, key) == val end)
    end)
  end

  @doc "First timeline entry matching a condition, or nil."
  @spec first(Trace.t(), keyword(), fun() | keyword()) :: map() | nil
  def first(%Trace{} = trace, opts, conditions) do
    trace |> find_when(opts, conditions) |> List.first()
  end

  @doc """
  Edge list for one signal: `[%{index, time_ps, from, to}]`, one per change.

  `signal` is a bare leaf (with `scope:`) or any resolvable ref.
  """
  @spec transitions(Trace.t(), keyword(), atom() | String.t() | Trace.addr()) :: [map()]
  def transitions(%Trace{} = trace, opts, signal) do
    scope = Keyword.get(opts, :scope)
    key = condition_key(trace, scope, signal)

    trace
    |> timeline(opts)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [a, b] ->
      va = Map.get(a.state, key)
      vb = Map.get(b.state, key)
      if va != vb, do: [%{index: b.index, time_ps: b.time_ps, from: va, to: vb}], else: []
    end)
  end

  @doc """
  Signals that changed between two points, as `%{key => {before, after}}`.

  Points are `:first`, `:last`, `{:index, n}`, or `{:time, ps}`. Keys follow the
  same scope rule as `timeline/2`.
  """
  @spec diff(Trace.t(), keyword(), point(), point()) :: map()
  def diff(%Trace{} = trace, opts, point_a, point_b) do
    a = snapshot_at(trace, opts, point_a)
    b = snapshot_at(trace, opts, point_b)

    case {a, b} do
      {nil, _} ->
        %{}

      {_, nil} ->
        %{}

      {a, b} ->
        MapSet.union(MapSet.new(Map.keys(a)), MapSet.new(Map.keys(b)))
        |> Enum.reduce(%{}, fn k, acc ->
          va = Map.get(a, k)
          vb = Map.get(b, k)
          if va != vb, do: Map.put(acc, k, {va, vb}), else: acc
        end)
    end
  end

  @doc """
  Full design state at a point, as the `state` map (scope-projected per `opts`).
  Returns nil if there are no samples.
  """
  @spec snapshot(Trace.t(), keyword(), point()) :: map() | nil
  def snapshot(%Trace{} = trace, opts \\ [], point \\ :last) do
    snapshot_at(trace, opts, point)
  end

  @doc """
  Tier 2 window extraction: every *maximal interval* where `pred` holds, as a
  list of `%Hw.Trace.Window{}` (one per contiguous run), all labeled `label`.

  `pred` is a `fn state -> boolean end` over the (optionally scope-projected)
  timeline state — the same state shape `find_when/3`'s function form sees. Use
  this when no producer marked the region: e.g. "every window where the SIE bus
  is active."

      Query.where(trace, [scope: :sie], :bus_active, fn s -> s[:rx_state] > 0 end)

  Each window's `from` is the ps of the first sample entering the run and `to`
  is the ps of the last sample still in the run. A run that reaches the end of
  the trace is closed at the last sample's ps.
  """
  @spec where(Trace.t(), keyword(), atom() | String.t(), (map() -> boolean())) :: [Hw.Trace.Window.t()]
  def where(%Trace{} = trace, opts, label, pred) when is_function(pred, 1) do
    trace
    |> timeline(opts)
    |> Enum.chunk_while(
      nil,
      fn entry, run ->
        case {pred.(entry.state), run} do
          {true, nil} -> {:cont, %{from: entry.time_ps, to: entry.time_ps}}
          {true, r} -> {:cont, %{r | to: entry.time_ps}}
          {false, nil} -> {:cont, nil}
          {false, r} -> {:cont, r, nil}
        end
      end,
      fn
        nil -> {:cont, nil}
        r -> {:cont, r, nil}
      end
    )
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn %{from: f, to: t} ->
      %Hw.Trace.Window{id: make_ref(), label: label, from: f, to: t, axis: :time}
    end)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  # Project a sample's full {addr => val} map to the query's key space.
  defp project(values, nil, nil), do: values

  defp project(values, nil, only_addrs) when is_list(only_addrs) do
    Map.take(values, only_addrs)
  end

  defp project(values, scope, only_addrs) do
    values
    |> Enum.filter(fn {{s, _leaf}, _v} -> List.first(s) == scope end)
    |> Enum.filter(fn {addr, _v} -> is_nil(only_addrs) or addr in only_addrs end)
    |> Map.new(fn {{_s, leaf}, v} -> {leaf, v} end)
  end

  # In a scoped query, condition/transition keys are bare leaves; unscoped, they
  # are the resolved {scope, leaf} address.
  defp normalize_conditions(trace, scope, conditions) do
    Enum.map(conditions, fn {k, v} -> {condition_key(trace, scope, k), v} end)
  end

  defp condition_key(_trace, scope, key) when not is_nil(scope) and is_atom(key), do: key

  defp condition_key(trace, nil, ref) do
    Trace.address(trace, ref) || ref
  end

  defp snapshot_at(trace, opts, point) do
    case entry_at(trace, opts, point) do
      nil -> nil
      entry -> entry.state
    end
  end

  defp entry_at(trace, opts, :first), do: trace |> timeline(opts) |> List.first()
  defp entry_at(trace, opts, :last), do: trace |> timeline(opts) |> List.last()

  defp entry_at(trace, opts, {:index, n}) do
    trace |> timeline(opts) |> Enum.find(&(&1.index == n))
  end

  defp entry_at(trace, opts, {:time, ps}) do
    # most-recent entry at or before ps (matches Simtrace at/3 semantics)
    trace
    |> timeline(opts)
    |> Enum.filter(&(&1.time_ps <= ps))
    |> List.last()
  end

  # Resolve a `window:` option into {from_ps, to_ps}. Accepts a label (looked up,
  # must be unambiguous), a %Window{} directly, or nil (no window → no bounds).
  defp resolve_window(_trace, nil), do: {nil, nil}

  defp resolve_window(_trace, %Hw.Trace.Window{} = w) do
    Hw.Trace.Window.bounds(w, :infinity) |> normalize_open()
  end

  defp resolve_window(%Trace{} = trace, label) do
    case Hw.Trace.window(trace, label) do
      nil ->
        raise ArgumentError, "unknown window #{inspect(label)}"

      %Hw.Trace.Window{} = w ->
        default_to = trace.last_time_ps
        Hw.Trace.Window.bounds(w, default_to)
    end
  end

  # An open span resolved with :infinity means "to end" → no upper bound.
  defp normalize_open({from, :infinity}), do: {from, nil}
  defp normalize_open(bounds), do: bounds

  defp filter_time(samples, nil, nil), do: samples

  defp filter_time(samples, from_ps, to_ps) do
    Enum.filter(samples, fn s ->
      (is_nil(from_ps) or s.time_ps >= from_ps) and (is_nil(to_ps) or s.time_ps <= to_ps)
    end)
  end

  defp reject_nils(list), do: Enum.reject(list, &is_nil/1)
end
