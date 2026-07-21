defmodule Hw.Trace.Adapter.Live do
  @moduledoc """
  Adapter from the live GenServer engine to `Hw.Trace`.

  Two entry points:

    * `snapshot_trace/1` — materialize a `Hw.Trace` from a running sim by
      reading each entity's current `reg_state` once (a point-in-time capture).

    * `from_history/1` — materialize a `Hw.Trace` from a `%Hw.Simtrace{}`
      handle whose watchers have been recording commits into ElixirScope's
      TraceDB. Each entity's per-commit `reg_state` timeline is merged by
      `time_ps` into one unified trace.

  ## Why reg_state folds directly

  Entity `reg_state` keys are already fully-prefixed schedule names (e.g.
  `:cdc_dev_state`, `:sie_rx_state` — see `Hw.Sim.Entity`), which is exactly what
  `Hw.Trace.Scope.resolve/1` expects. So a reg_state map is a valid dense
  snapshot: no re-prefixing, it folds straight through `Hw.Trace.apply_snapshot/3`.

  ## ElixirScope

  ElixirScope is reached only from `from_history/1`, via `apply/3` (it is an
  optional dep). The rest of the unified query/render layer never touches it —
  this adapter is the single confinement point, which is the M4 goal: demote
  ElixirScope from a hard dependency of the trace subsystem to one storage
  backend of one adapter.
  """

  alias Hw.Sim.Schedule
  alias Hw.Trace

  @doc """
  Build a `Hw.Trace` metadata skeleton (no samples) from a sim's schedule,
  covering the given entities' signals. Shared by both entry points.

  `entity_names` selects which entities' signals to include; `nil` = all.
  """
  @spec new(Schedule.t(), [atom()] | nil) :: Trace.t()
  def new(%Schedule{} = schedule, entity_names \\ nil) do
    names = signal_names_for(schedule, entity_names)
    inits = Map.get(schedule, :signal_inits, %{})

    specs =
      Enum.map(names, fn name ->
        {name,
         %{
           width: Map.get(schedule.signal_widths, name, 1),
           init: Map.get(inits, name, 0)
         }}
      end)

    Trace.new(specs, clock: first_clock(schedule))
  end

  @doc """
  Capture a single dense snapshot of a running sim into a one-sample `Hw.Trace`.

  Reads each traced entity's `reg_state` via the registry + `:sys.get_state`.
  Useful for a point-in-time view without needing watchers/TraceDB.
  """
  @spec snapshot_trace(map(), keyword()) :: Trace.t()
  def snapshot_trace(sim, opts \\ []) do
    entity_names = resolve_entities(sim, opts)
    trace = new(sim.schedule, entity_names)

    {snap, time_ps} = live_snapshot(sim, entity_names)
    Trace.apply_snapshot(trace, snap, time_ps)
  end

  @doc """
  Materialize a full `Hw.Trace` from a `%Hw.Simtrace{}` recording handle.

  Merges every traced entity's per-commit `reg_state` timeline (from TraceDB)
  into one time-ordered sequence of dense snapshots.
  """
  @spec from_history(struct()) :: Trace.t()
  def from_history(%{schedule: schedule, entity_names: entity_names} = st) do
    trace = new(schedule, entity_names)

    # Gather each entity's timeline: [{time_ps, reg_state_map}], merge by time.
    merged =
      entity_names
      |> Enum.flat_map(fn name -> entity_history(st, name) end)
      |> Enum.group_by(fn {t, _state} -> t end, fn {_t, state} -> state end)
      |> Enum.sort_by(fn {t, _} -> t end)

    Enum.reduce(merged, trace, fn {time_ps, state_maps}, acc ->
      # If multiple entities committed at the same ps, merge their maps.
      combined = Enum.reduce(state_maps, %{}, &Map.merge(&2, &1))
      Trace.apply_snapshot(acc, combined, time_ps)
    end)
  end

  # ---------------------------------------------------------------------------
  # Private — signal/entity resolution
  # ---------------------------------------------------------------------------

  # All schedule signals belonging to the given entities (nil = all signals).
  defp signal_names_for(%Schedule{} = schedule, nil) do
    schedule.signal_widths |> Map.keys() |> Enum.sort()
  end

  defp signal_names_for(%Schedule{} = schedule, entity_names) do
    prefixes =
      entity_names
      |> Enum.map(&prefix_for_entity/1)
      |> Enum.reject(&(&1 == nil))

    all = schedule.signal_widths |> Map.keys() |> Enum.sort()

    Enum.filter(all, fn name ->
      str = Atom.to_string(name)
      # a signal belongs if its name starts with one of the entity prefixes,
      # OR it's a top-scope signal and :_top_ was requested
      Enum.any?(prefixes, fn
        "" -> not prefixed?(str)
        p -> String.starts_with?(str, p)
      end)
    end)
  end

  defp prefixed?(str) do
    Enum.any?(Schedule.instance_prefixes(), fn {p, _e, _d} -> String.starts_with?(str, p) end)
  end

  defp prefix_for_entity(:_top_), do: ""

  defp prefix_for_entity(entity) do
    case Enum.find(Schedule.instance_prefixes(), fn {_p, e, _d} -> e == entity end) do
      {prefix, _, _} -> prefix
      nil -> nil
    end
  end

  defp resolve_entities(sim, opts) do
    all = sim.schedule.entities |> Map.keys() |> Enum.sort()

    cond do
      Keyword.has_key?(opts, :entities) -> Keyword.fetch!(opts, :entities)
      Keyword.get(opts, :filter) == :usb -> Enum.filter(all, &(&1 in [:phy, :sie, :cdc]))
      true -> all
    end
  end

  # ---------------------------------------------------------------------------
  # Private — live capture
  # ---------------------------------------------------------------------------

  # Read each entity's current reg_state and merge into one dense snapshot.
  defp live_snapshot(sim, entity_names) do
    Enum.reduce(entity_names, {%{}, 0}, fn name, {acc, max_t} ->
      case lookup_entity_pid(sim.sim_id, name) do
        nil ->
          {acc, max_t}

        pid ->
          try do
            state = :sys.get_state(pid)
            t = Map.get(state, :time_ps, 0)
            {Map.merge(acc, state.reg_state), max(max_t, t)}
          rescue
            _ -> {acc, max_t}
          end
      end
    end)
  end

  # Per-entity commit history from TraceDB: [{time_ps, reg_state_map}].
  defp entity_history(st, entity_name) do
    case lookup_entity_pid(st.sim_id, entity_name) do
      nil ->
        []

      pid ->
        apply(ElixirScope.TraceDB, :get_state_history, [pid])
        |> Enum.map(fn ev -> {ev.timestamp, ev.state} end)
    end
  end

  defp lookup_entity_pid(sim_id, name) do
    registry = Hw.Sim.Scope.registry(sim_id)

    case Registry.lookup(registry, {:entity, name}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp first_clock(%Schedule{clocks: [clk | _]}), do: clk.name
  defp first_clock(_), do: nil
end
