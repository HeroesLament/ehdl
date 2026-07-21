defmodule Hw.Simtrace.Query do
  @moduledoc """
  All timeline and point-in-time queries against recorded sim state.
  Reads from ElixirScope's TraceDB — never touches the live sim.
  """

  alias Hw.Simtrace

  # ---------------------------------------------------------------------------
  # Discovery
  # ---------------------------------------------------------------------------

  def signals(%Simtrace{} = st) do
    Map.new(st.entity_names, fn name ->
      regs = case first_snapshot(st, name) do
        nil   -> []
        entry -> entry.state |> Map.keys() |> Enum.sort()
      end
      {name, regs}
    end)
  end

  def recorded(%Simtrace{} = st) do
    Map.new(st.entity_names, fn name ->
      {name, recorded_summary(st, name)}
    end)
  end

  def recorded_summary(%Simtrace{} = st, name) do
    # Pull only timestamps — don't materialise the full state maps
    entries = raw_timeline(st, name)
    case entries do
      [] -> %{first_ps: nil, last_ps: nil, ticks: 0}
      _  ->
        times = Enum.map(entries, & &1.timestamp)
        %{first_ps: Enum.min(times), last_ps: Enum.max(times), ticks: length(entries)}
    end
  end

  def ps_per_tick(%Simtrace{schedule: schedule}, clock_name) do
    clk = Enum.find(schedule.clocks, &(&1.name == clock_name))
    if clk, do: trunc(1_000_000 / clk.freq_mhz), else: nil
  end

  # ---------------------------------------------------------------------------
  # Point-in-time
  # ---------------------------------------------------------------------------

  def at(%Simtrace{} = st, entity, :last) do
    case raw_timeline(st, entity) |> Enum.max_by(& &1.timestamp, fn -> nil end) do
      nil   -> nil
      entry -> entry.state
    end
  end

  def at(%Simtrace{} = st, entity, time_ps) do
    # Most recent snapshot at or before time_ps
    raw_timeline(st, entity)
    |> Enum.filter(&(&1.timestamp <= time_ps))
    |> Enum.max_by(& &1.timestamp, fn -> nil end)
    |> case do
      nil   -> nil
      entry -> entry.state
    end
  end

  def get(%Simtrace{} = st, entity, register, time_ps) do
    case at(st, entity, time_ps) do
      nil   -> nil
      state -> Map.get(state, register)
    end
  end

  # ---------------------------------------------------------------------------
  # Timeline
  # ---------------------------------------------------------------------------

  def timeline(%Simtrace{} = st, entity, opts) do
    from_ps = Keyword.get(opts, :from)
    to_ps   = Keyword.get(opts, :to)
    only    = Keyword.get(opts, :only)

    raw_timeline(st, entity)
    |> maybe_filter_time(from_ps, to_ps)
    |> Enum.map(fn entry ->
      state = if only, do: Map.take(entry.state, only), else: entry.state
      %{time_ps: entry.timestamp, state: state}
    end)
  end

  def find_when(%Simtrace{} = st, entity, conditions) when is_function(conditions) do
    timeline(st, entity, [])
    |> Enum.filter(fn entry -> conditions.(entry.state) end)
  end

  def find_when(%Simtrace{} = st, entity, conditions) when is_list(conditions) do
    timeline(st, entity, [])
    |> Enum.filter(fn entry ->
      Enum.all?(conditions, fn {reg, val} ->
        Map.get(entry.state, reg) == val
      end)
    end)
  end

  def first(%Simtrace{} = st, entity, conditions) do
    Hw.Simtrace.Query.find_when(st, entity, conditions) |> List.first()
  end

  def transitions(%Simtrace{} = st, entity, register) do
    timeline(st, entity, [])
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn [a, b] ->
      v_a = Map.get(a.state, register)
      v_b = Map.get(b.state, register)
      if v_a != v_b do
        [%{time_ps: b.time_ps, from: v_a, to: v_b}]
      else
        []
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Diff
  # ---------------------------------------------------------------------------

  def diff(%Simtrace{} = st, entity, from_ps, to_ps) do
    snap_a = resolve_snapshot(st, entity, from_ps)
    snap_b = resolve_snapshot(st, entity, to_ps)

    case {snap_a, snap_b} do
      {nil, _} -> %{}
      {_, nil} -> %{}
      {a, b}   ->
        all_keys = MapSet.union(MapSet.new(Map.keys(a)), MapSet.new(Map.keys(b)))
        Enum.reduce(all_keys, %{}, fn k, acc ->
          va = Map.get(a, k)
          vb = Map.get(b, k)
          if va != vb, do: Map.put(acc, k, {va, vb}), else: acc
        end)
    end
  end

  defp resolve_snapshot(st, entity, :first) do
    case raw_timeline(st, entity) |> List.first() do
      nil   -> nil
      entry -> entry.state
    end
  end

  defp resolve_snapshot(st, entity, :last), do: at(st, entity, :last)
  defp resolve_snapshot(st, entity, time_ps), do: at(st, entity, time_ps)

  # ---------------------------------------------------------------------------
  # Cross-entity
  # ---------------------------------------------------------------------------

  def snapshot(%Simtrace{} = st, time_ps) do
    Map.new(st.entity_names, fn name ->
      {name, at(st, name, time_ps)}
    end)
  end

  def context(%Simtrace{} = st, entity_name, %{time_ps: time_ps, state: state}) do
    others = st.entity_names
    |> Enum.reject(&(&1 == entity_name))
    |> Map.new(fn name -> {name, at(st, name, time_ps)} end)

    %{
      time_ps: time_ps,
      origin:  %{entity: entity_name, state: state},
      others:  others,
    }
  end

  # ---------------------------------------------------------------------------
  # Internal: raw TraceDB access
  # ---------------------------------------------------------------------------

  # Fetch all :state events for a given entity pid from TraceDB,
  # returning them sorted by timestamp (picoseconds).
  defp raw_timeline(%Simtrace{watchers: watchers} = st, entity_name) do
    pid = case Map.get(watchers, entity_name) do
      nil -> nil
      _   -> lookup_entity_pid(st, entity_name)
    end

    if pid do
      # apply/3 because ElixirScope is an optional dep — no compile-time ref.
      apply(ElixirScope.TraceDB, :get_state_history, [pid])
      |> Enum.sort_by(& &1.timestamp)
    else
      []
    end
  end

  defp first_snapshot(st, entity_name) do
    raw_timeline(st, entity_name) |> List.first()
  end

  defp lookup_entity_pid(%Simtrace{sim_id: sim_id}, name) do
    registry = Hw.Sim.Scope.registry(sim_id)
    case Registry.lookup(registry, {:entity, name}) do
      [{pid, _}] -> pid
      []         -> nil
    end
  end

  defp maybe_filter_time(entries, nil, nil), do: entries

  defp maybe_filter_time(entries, from_ps, to_ps) do
    entries
    |> then(fn e ->
      if from_ps, do: Enum.filter(e, &(&1.timestamp >= from_ps)), else: e
    end)
    |> then(fn e ->
      if to_ps, do: Enum.filter(e, &(&1.timestamp <= to_ps)), else: e
    end)
  end
end
