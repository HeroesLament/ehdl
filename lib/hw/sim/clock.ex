defmodule Hw.Sim.Clock do
  @moduledoc """
  ClockProcess — drives clock edges for one domain and coordinates
  the two-phase commit barrier.

  One ClockProcess per clock domain (clk_48, clk_fast, etc.).
  External clocks (clk_25mhz) don't need a ClockProcess since no
  entity registers against them — they're just input signals.

  The two-phase protocol per edge:

    1. TimeArbiter grants this clock permission to fire its next edge
    2. ClockProcess broadcasts {:edge, :rising, time_ps, from: self()} to all
       subscribed entities
    3. ClockProcess waits for {:eval_done, pid, name, next_regs} from each entity
    4. Once all entities reply, ClockProcess broadcasts {:commit, time_ps}
    5. ClockProcess notifies TimeArbiter {:edge_complete, self(), next_edge_ps}
    6. TimeArbiter schedules the next edge grant

  Rising edges only for now (posedge clocks). Falling edges can be added
  later for negedge-triggered designs.
  """

  use GenServer

  defstruct [
    :name,              # :clk_48 | :clk_fast
    :sim_id,            # unique ref for this simulation instance
    :period_ps,         # integer full period in picoseconds
    :half_period_ps,    # integer half period (edge to edge)
    :next_edge_ps,      # integer time of next rising edge
    :phase,             # :rising | :falling
    :subscribers,       # [{pid, entity_name}] entities subscribed to this clock
    :top_pid,           # pid of _top_ entity (kept for reference, settle now inline)
    :pending_evals,     # MapSet of pids waiting for eval_done (phase 1)
    :pending_commits,   # MapSet of pids waiting for commit_done (phase 2)
    :arbiter_pid,       # pid of TimeArbiter
    :time_ps,           # current sim time
    :cross_settle_ops,    # [op] minimal ops to propagate cross-entity comb signals
    :cross_settle_inputs, # [atom] ETS signal names needed by cross_settle_ops
    :signal_widths,       # %{atom => integer} for eval masking
  ]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link({name, freq_mhz, arbiter_pid, sim_id, cross_settle_ops, cross_settle_inputs, signal_widths}) do
    GenServer.start_link(__MODULE__, {name, freq_mhz, arbiter_pid, sim_id, cross_settle_ops, cross_settle_inputs, signal_widths},
      name: Hw.Sim.Scope.clock_via(sim_id, name))
  end

  def via(sim_id, name), do: Hw.Sim.Scope.clock_via(sim_id, name)

  @doc "Subscribe an entity process to this clock's edges."
  def subscribe(sim_id, clock_name, entity_pid, entity_name) do
    GenServer.cast(via(sim_id, clock_name), {:subscribe, entity_pid, entity_name})
  end

  @doc "Request the clock to fire N rising edges, blocking until complete."
  def tick(clock_name, n, from_pid, sim_id) do
    Hw.Sim.TimeArbiter.tick(clock_name, n, from_pid, sim_id)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init({name, freq_mhz, arbiter_pid, sim_id, cross_settle_ops, cross_settle_inputs, signal_widths}) do
    period_ps = trunc(1_000_000 / freq_mhz)  # MHz → ps

    state = %__MODULE__{
      name:                 name,
      sim_id:               sim_id,
      period_ps:            period_ps,
      half_period_ps:       div(period_ps, 2),
      next_edge_ps:         0,
      phase:                :rising,
      subscribers:          [],
      top_pid:              nil,
      pending_evals:        MapSet.new(),
      pending_commits:      MapSet.new(),
      arbiter_pid:          arbiter_pid,
      time_ps:              0,
      cross_settle_ops:     cross_settle_ops,
      cross_settle_inputs:  cross_settle_inputs,
      signal_widths:        signal_widths,
    }

    # Register with arbiter immediately
    send(arbiter_pid, {:register_clock, self(), name, 0})

    {:ok, state, {:continue, :lookup_top}}
  end

  @impl true
  def handle_continue(:lookup_top, state) do
    # _top_ may not be registered yet — it's looked up lazily on first commit_done
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Subscription
  # ---------------------------------------------------------------------------

  @impl true
  def handle_cast({:subscribe, pid, entity_name}, state) do
    {:noreply, %{state | subscribers: [{pid, entity_name} | state.subscribers]}}
  end

  # ---------------------------------------------------------------------------
  # Tick request — queue N edges to fire
  # ---------------------------------------------------------------------------

  @impl true
  def handle_cast({:tick, n, from_pid}, state) do
    # Store the tick request — will be fulfilled as arbiter grants edges
    {:noreply, Map.put(state, :tick_queue, {n, from_pid})}
  end

  # ---------------------------------------------------------------------------
  # Arbiter grants permission to fire next edge
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:edge_granted, time_ps}, state) do
    state = %{state | time_ps: time_ps}

    if Enum.empty?(state.subscribers) do
      # No entities subscribed — advance immediately
      next_ps = time_ps + state.half_period_ps
      send(state.arbiter_pid, {:edge_complete, self(), state.name, next_ps})
      {:noreply, %{state | next_edge_ps: next_ps}}
    else
      # Broadcast edge to all subscribed entities
      pids = Enum.map(state.subscribers, fn {pid, _} -> pid end)
      Enum.each(pids, fn pid ->
        send(pid, {:edge, :rising, time_ps, from: self()})
      end)

      pending = MapSet.new(pids)
      {:noreply, %{state | pending_evals: pending, next_edge_ps: time_ps}}
    end
  end

  # ---------------------------------------------------------------------------
  # Collect eval_done replies from entities
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:eval_done, pid, _entity_name, _next_regs}, state) do
    pending = MapSet.delete(state.pending_evals, pid)

    if MapSet.size(pending) == 0 do
      # Phase 2: broadcast commit — entities latch regs and write to ETS
      Enum.each(state.subscribers, fn {pid, _} ->
        send(pid, {:commit, state.time_ps, from: self()})
      end)

      # Track pending commits — wait for all before settling
      pending_commits = state.subscribers
        |> Enum.map(fn {pid, _} -> pid end)
        |> MapSet.new()

      {:noreply, %{state | pending_evals: MapSet.new(),
                           pending_commits: pending_commits}}
    else
      {:noreply, %{state | pending_evals: pending}}
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 2b: collect commit_done, then settle _top_ and notify arbiter
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:commit_done, pid}, state) do
    pending = MapSet.delete(state.pending_commits, pid)

    if MapSet.size(pending) == 0 do
      # Resolve _top_ pid lazily and cache it
      top_pid = state.top_pid || case Registry.lookup(Hw.Sim.Scope.registry(state.sim_id), {:entity, :_top_}) do
        [{pid, _}] -> pid
        [] -> nil
      end

      # Inline cross-entity comb settle: read only the ~5 ETS signals needed,
      # evaluate the ~9-op closure, write results back to ETS — all synchronously
      # in the clock process before notifying the arbiter. This guarantees cross-
      # entity combinational signals (e.g. rst = bnot(rst_sync_ready)) are correct
      # in ETS before any entity reads them on the next edge.
      if state.cross_settle_ops != [] do
        env = Map.new(state.cross_settle_inputs, fn name ->
          {name, Hw.Sim.State.get(name, state.sim_id)}
        end)
        {_, results} = Enum.reduce(state.cross_settle_ops, {env, []}, fn op, {env, acc} ->
          outputs = Hw.Sim.Eval.eval(op, env, state.signal_widths, %{})
          new_env = Enum.reduce(outputs, env, fn {k, v}, e -> Map.put(e, k, v) end)
          {new_env, acc ++ outputs}
        end)
        Hw.Sim.State.put_many(results, state.time_ps, state.sim_id)
      end

      # Notify arbiter edge is complete — next edge won't fire until this arrives
      next_ps = state.time_ps + state.half_period_ps
      send(state.arbiter_pid, {:edge_complete, self(), state.name, next_ps})

      {:noreply, %{state | pending_commits: MapSet.new(),
                           next_edge_ps: next_ps,
                           top_pid: top_pid}}
    else
      {:noreply, %{state | pending_commits: pending}}
    end
  end
end


defmodule Hw.Sim.TimeArbiter do
  @moduledoc """
  Serializes clock edge firing across all domains.

  Tick-driven: the arbiter does NOT run freely. Instead, testbench calls
  `tick(clock_name, n, caller_pid)` which advances simulation until n edges
  of the named clock have fired, then replies {:tick_complete, clock_name}
  to caller_pid.

  Internally, the arbiter fires ALL clocks in time order — clk_fast edges
  interleave correctly with clk_48 edges. The tick counter only tracks the
  requested clock, not all clocks.
  """

  use GenServer

  defstruct [
    :queue,         # [{time_ps, pid, name}] sorted ascending by time_ps
    :pid_to_name,   # %{pid => name}
    :tick_request,  # {clock_name, remaining, caller_pid} | nil
    :firing,        # pid | nil — clock currently processing an edge
  ]

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Request n edges of clock_name, notifying caller_pid when done."
  def tick(clock_name, n, caller_pid, sim_id) do
    GenServer.cast(Hw.Sim.Scope.arbiter(sim_id), {:tick, clock_name, n, caller_pid})
  end

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{
      queue:        [],
      pid_to_name:  %{},
      tick_request: nil,
      firing:       nil,
    }}
  end

  @doc "Synchronously settle all entities: broadcast post_init and wait for all acks."
  def settle(entity_pids, sim_id) do
    GenServer.call(Hw.Sim.Scope.arbiter(sim_id), {:settle, entity_pids})
  end

  @impl true
  def handle_call({:settle, entity_pids}, _from, state) do
    arbiter_pid = self()
    Enum.each(entity_pids, fn pid -> send(pid, {:post_init, arbiter_pid}) end)
    Enum.each(entity_pids, fn _ ->
      receive do
        :post_init_done -> :ok
      end
    end)
    {:reply, :ok, state}
  end


  @impl true
  def handle_info({:register_clock, pid, name, first_edge_ps}, state) do
    queue      = insert_sorted(state.queue, {first_edge_ps, pid, name})
    pid_to_name = Map.put(state.pid_to_name, pid, name)
    {:noreply, %{state | queue: queue, pid_to_name: pid_to_name}}
  end

  @impl true
  def handle_info({:edge_complete, pid, _name, next_edge_ps}, state) do
    # The clock that just fired reports its next edge time
    # Remove it from the head of the queue (it was just the lowest)
    # and re-insert at next_edge_ps
    clock_name = Map.get(state.pid_to_name, pid, :unknown)
    queue = state.queue
      |> Enum.reject(fn {_, p, _} -> p == pid end)
      |> insert_sorted({next_edge_ps, pid, clock_name})

    # Check if this completes a tick request
    state = %{state | queue: queue, firing: nil}
    state = maybe_complete_tick(state, clock_name)
    state = maybe_fire_next(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:tick, clock_name, n, caller_pid}, state) do
    state = %{state | tick_request: {clock_name, n, caller_pid}}
    state = maybe_fire_next(state)
    {:noreply, state}
  end

  # Fire the next clock edge if we have a pending tick request and nothing firing
  defp maybe_fire_next(%{tick_request: nil} = state), do: state
  defp maybe_fire_next(%{firing: pid} = state) when not is_nil(pid), do: state
  defp maybe_fire_next(%{queue: []} = state), do: state
  defp maybe_fire_next(state) do
    [{time_ps, pid, _name} | _] = state.queue
    send(pid, {:edge_granted, time_ps})
    %{state | firing: pid}
  end

  defp maybe_complete_tick(state, fired_clock_name) do
    case state.tick_request do
      {^fired_clock_name, 1, caller_pid} ->
        send(caller_pid, {:tick_complete, fired_clock_name})
        %{state | tick_request: nil}
      {^fired_clock_name, n, caller_pid} when n > 1 ->
        %{state | tick_request: {fired_clock_name, n - 1, caller_pid}}
      _ ->
        state
    end
  end

  defp insert_sorted([], entry), do: [entry]
  defp insert_sorted([{t, _, _} = head | rest], {new_t, _, _} = entry) when new_t >= t do
    [head | insert_sorted(rest, entry)]
  end
  defp insert_sorted(list, entry), do: [entry | list]
end
