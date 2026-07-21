defmodule Hw.Sim.State do
  @moduledoc "ETS signal fabric — one instance per simulation."
  use GenServer

  alias Hw.Sim.Scope

  # ---------------------------------------------------------------------------
  # Public API — all calls require sim_id to target the right instance
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def init_signals(schedule, sim_id) do
    GenServer.call(Scope.state(sim_id), {:init_signals, schedule})
  end

  def get(signal_name, sim_id) do
    table = signals_table(sim_id)
    case :ets.lookup(table, signal_name) do
      [{_, value, _}] -> value
      [] -> 0
    end
  end

  def top_closures(sim_id) do
    case :ets.lookup(signals_table(sim_id), :_top_closures) do
      [{_, closures, _}] -> closures
      [] -> %{}
    end
  end

  def stored_signal_widths(sim_id) do
    case :ets.lookup(signals_table(sim_id), :_signal_widths) do
      [{_, widths, _}] -> widths
      [] -> %{}
    end
  end


  def top_dirty?(sim_id) do
    case :ets.lookup(signals_table(sim_id), :_top_dirty) do
      [{_, 1, _}] -> true
      _ -> false
    end
  end

  def mark_top_dirty(sim_id) do
    :ets.insert(signals_table(sim_id), {:_top_dirty, 1, 0})
  end

  def clear_top_dirty(sim_id) do
    :ets.insert(signals_table(sim_id), {:_top_dirty, 0, 0})
  end

  def put(signal_name, value, time_ps, sim_id) do
    :ets.insert(signals_table(sim_id), {signal_name, value, time_ps})
    :ets.insert(changes_table(sim_id), {signal_name, value, time_ps})
  end

  def put_many(kvs, time_ps, sim_id) do
    entries = Enum.map(kvs, fn {name, value} -> {name, value, time_ps} end)
    :ets.insert(signals_table(sim_id), entries)
    :ets.insert(changes_table(sim_id), entries)
  end

  def snapshot(sim_id) do
    :ets.tab2list(signals_table(sim_id))
    |> Map.new(fn {name, value, _} -> {name, value} end)
  end

  def drain_changes(sim_id) do
    changes = :ets.tab2list(changes_table(sim_id))
    :ets.delete_all_objects(changes_table(sim_id))
    changes
  end

  def signals_table(sim_id), do: :"hw_sim_signals_#{inspect(sim_id)}"
  def changes_table(sim_id), do: :"hw_sim_changes_#{inspect(sim_id)}"

  @doc """
  Async cross-entity comb settle. Evaluates a minimal set of ops whose outputs
  are cross-entity signals, writing results back to ETS. Cast so the clock
  process is not blocked — the settle completes before the next edge fires
  because the arbiter's message queue is ordered after this cast.
  """
  def cross_settle(ops, widths, time_ps, sim_id) do
    GenServer.cast(Scope.state(sim_id), {:cross_settle, ops, widths, time_ps})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    sim_id   = Keyword.fetch!(opts, :sim_id)
    schedule = Keyword.get(opts, :schedule)

    signals = :ets.new(signals_table(sim_id), [:named_table, :public, :set,
      read_concurrency: true, write_concurrency: true])
    changes = :ets.new(changes_table(sim_id), [:named_table, :public, :set,
      write_concurrency: true])

    # If schedule is provided at startup, populate ETS immediately so entity
    # processes read correct reset-value-based initial reg state when they start.
    if schedule do
      entries = schedule.signal_widths
        |> Enum.map(fn {name, _} ->
          {name, Map.get(schedule.signal_inits, name, 0), 0}
        end)
      :ets.insert(signals_table(sim_id), entries)

      Enum.each(schedule.memories, fn {name, init_list} ->
        :ets.insert(signals_table(sim_id), {name, init_list, 0})
      end)
    end

    {:ok, %{sim_id: sim_id, signals: signals, changes: changes}}
  end

  @impl true
  def handle_call({:init_signals, schedule}, _from, state) do
    sim_id = state.sim_id
    entries = schedule.signal_widths
      |> Enum.map(fn {name, _} ->
        {name, Map.get(schedule.signal_inits, name, 0), 0}
      end)
    :ets.insert(signals_table(sim_id), entries)

    Enum.each(schedule.memories, fn {name, init_list} ->
      :ets.insert(signals_table(sim_id), {name, init_list, 0})
    end)

    # Store per-signal closures and widths for lazy _top_ eval in Testbench.get
    :ets.insert(signals_table(sim_id), {:_top_closures, schedule.top_signal_closures, 0})
    :ets.insert(signals_table(sim_id), {:_signal_widths, schedule.signal_widths, 0})

    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:cross_settle, ops, widths, time_ps}, state) do
    sim_id = state.sim_id
    ets_state = snapshot(sim_id)
    results = Enum.flat_map(ops, fn op ->
      Hw.Sim.Eval.eval(op, ets_state, widths, %{})
    end)
    put_many(results, time_ps, sim_id)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    sim_id = state.sim_id
    for table <- [signals_table(sim_id), changes_table(sim_id)] do
      if :ets.whereis(table) != :undefined, do: :ets.delete(table)
    end
    state
  end
end
