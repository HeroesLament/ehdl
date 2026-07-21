defmodule Hw.Simtrace.Attach do
  @moduledoc """
  Spawns external `:sys.trace` watchers for each entity in a sim.
  No changes to Hw.Sim or design modules required.

  One watcher process per entity. Each watcher:
    1. Calls `:sys.trace(entity_pid, true)` to enable tracing
    2. Waits for `{:trace, pid, :receive, {:commit, time_ps, _}}` messages
    3. Snapshots `reg_state` via `:sys.get_state/1` at that exact moment
    4. Stores the raw map into ElixirScope TraceDB with `time_ps` as timestamp
    5. Monitors the entity and stops cleanly on exit
  """

  alias Hw.Simtrace

  @usb_entities [:phy, :sie, :cdc]

  # ---------------------------------------------------------------------------
  # Public
  # ---------------------------------------------------------------------------

  @doc "Attach watchers to a sim and return a %Hw.Simtrace{} handle."
  def attach(sim, opts) do
    ensure_elixir_scope!()

    entities = resolve_entities(sim, opts)
    watchers = Map.new(entities, fn name ->
      pid = lookup_entity!(sim, name)
      watcher = spawn_watcher(pid, name, sim.sim_id)
      {name, watcher}
    end)

    %Simtrace{
      sim_id:       sim.sim_id,
      schedule:     sim.schedule,
      watchers:     watchers,
      entity_names: entities,
    }
  end

  @doc "Stop all watcher processes."
  def detach(watchers) do
    Enum.each(watchers, fn {_, watcher_pid} ->
      if Process.alive?(watcher_pid), do: Process.exit(watcher_pid, :normal)
    end)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Entity resolution
  # ---------------------------------------------------------------------------

  defp resolve_entities(sim, opts) do
    all = all_entity_names(sim)

    cond do
      Keyword.has_key?(opts, :entities) ->
        Keyword.fetch!(opts, :entities)
      Keyword.get(opts, :filter) == :usb ->
        Enum.filter(all, &(&1 in @usb_entities))
      true ->
        all
    end
  end

  defp all_entity_names(sim) do
    sim.schedule.entities
    |> Map.keys()
    |> Enum.sort()
  end

  defp lookup_entity!(sim, name) do
    registry = Hw.Sim.Scope.registry(sim.sim_id)
    case Registry.lookup(registry, {:entity, name}) do
      [{pid, _}] -> pid
      [] -> raise ArgumentError, "Entity #{inspect(name)} not found in sim #{inspect(sim.sim_id)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Watcher process
  # ---------------------------------------------------------------------------

  defp spawn_watcher(entity_pid, entity_name, sim_id) do
    spawn_link(fn ->
      ref = Process.monitor(entity_pid)
      me  = self()

      # :sys.install installs a debug handler on the GenServer.
      # dbg_fun signature: fun(func_state, event, proc_state) -> new_func_state
      # Events for incoming messages are {:in, msg} or {:in, msg, from}.
      # {:commit, time_ps, from: clock_pid} arrives via raw send so it's
      # routed through handle_info — appears as {:in, {:commit, time_ps, _}}.
      # :post_init also arrives via raw send.
      handler = fn
        func_state, {:in, {:commit, time_ps, _}}, _proc_state ->
          send(me, {:trace_commit, entity_pid, time_ps})
          func_state
        func_state, {:in, :post_init}, _proc_state ->
          send(me, {:trace_post_init, entity_pid})
          func_state
        func_state, _event, _proc_state ->
          func_state
      end

      :sys.install(entity_pid, {handler, :ok})

      watcher_loop(entity_pid, entity_name, sim_id, ref)
    end)
  end

  defp watcher_loop(entity_pid, entity_name, sim_id, monitor_ref) do
    receive do
      {:trace_commit, ^entity_pid, time_ps} ->
        snapshot_after_commit(entity_pid, entity_name, sim_id, time_ps)
        watcher_loop(entity_pid, entity_name, sim_id, monitor_ref)

      {:trace_post_init, ^entity_pid} ->
        snapshot_after_commit(entity_pid, entity_name, sim_id, 0)
        watcher_loop(entity_pid, entity_name, sim_id, monitor_ref)

      {:DOWN, ^monitor_ref, :process, ^entity_pid, _reason} ->
        :ok

      :stop ->
        :sys.remove(entity_pid, self())
        :ok
    end
  end

  # Snapshot the entity's reg_state and store into ElixirScope TraceDB.
  # :sys.get_state/1 is a synchronous call that returns the GenServer state
  # struct. We extract reg_state (the raw %{atom => integer} map) directly.
  defp snapshot_after_commit(entity_pid, entity_name, sim_id, time_ps) do
    try do
      # :sys.get_state blocks until the entity's message queue is clear,
      # so this always runs after the commit handler finishes.
      entity_state = :sys.get_state(entity_pid)
      reg_state    = entity_state.reg_state

      # Store into ElixirScope TraceDB via apply/3 — ElixirScope is an
      # optional dep so we can't call it directly at compile time.
      apply(ElixirScope.TraceDB, :store_event, [:state, %{
        pid:       entity_pid,
        module:    entity_name,
        sim_id:    sim_id,
        state:     reg_state,
        timestamp: time_ps,
        data:      %{callback: :commit, entity: entity_name}
      }])
    rescue
      _ -> :ok  # entity may have died between commit and get_state
    end
  end

  # ---------------------------------------------------------------------------
  # ElixirScope availability check
  # ---------------------------------------------------------------------------

  defp ensure_elixir_scope! do
    unless Code.ensure_loaded?(ElixirScope) do
      raise """
      ElixirScope is not available. Add it to your mix.exs:

          {:elixir_scope, "~> 0.1", optional: true}

      Then run: mix deps.get
      And start it before attaching: ElixirScope.setup(tracing_level: :states_only)
      """
    end

    unless Process.whereis(ElixirScope.TraceDB) do
      raise """
      ElixirScope.TraceDB is not running. Call ElixirScope.setup/1 first:

          ElixirScope.setup(tracing_level: :states_only)
      """
    end
  end
end
