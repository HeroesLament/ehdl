defmodule Hw.Sim.Entity do
  @moduledoc """
  An entity process represents one EHDL instance in simulation.

  Each entity:
  - Owns its register state (current values in process state, next values
    computed during Phase 1 and latched during Phase 2)
  - Reads inputs from ETS (written by other entities or testbench)
  - Writes outputs to ETS after each evaluation
  - Subscribes to its clock domain's ClockProcess for edge notifications
  - Participates in the two-phase commit protocol per clock edge

  Two-phase protocol per clock edge:
    Phase 1: receive {:edge, :rising, time_ps}
             → read all inputs from ETS
             → evaluate all reg next-values
             → reply {:eval_done, self(), next_reg_values}

    Phase 2: receive {:commit, time_ps}
             → latch next_reg_values into reg state
             → evaluate comb ops using new reg state
             → write outputs to ETS

  Comb-only entities (no regs, e.g. :_top_) skip Phase 1 and just
  evaluate on commit.
  """

  use GenServer

  alias Hw.Sim.{State, Eval}
  alias Hw.IR.Ops.{Reg, Mem, Blackbox, Assign}

  defstruct [
    :spec,          # %EntitySpec{} from schedule
    :sim_id,        # unique ref for this simulation instance
    :reg_state,     # %{atom => integer} current register values
    :reg_next,      # %{atom => integer} computed next values (cleared after commit)
    :clock_pid,     # pid of this entity's ClockProcess (nil for comb-only)
    :widths,        # %{atom => integer} signal widths for masking
    :memories,      # %{atom => list} memory contents
    :comb_ops,      # [op] pre-filtered: only non-Reg, non-Mem ops
    :time_ps,       # integer current sim time
  ]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link({spec, widths, memories, clock_pid, sim_id}) do
    GenServer.start_link(__MODULE__, {spec, widths, memories, clock_pid, sim_id},
      name: Hw.Sim.Scope.entity_via(sim_id, spec.name))
  end

  def via(sim_id, name), do: Hw.Sim.Scope.entity_via(sim_id, name)

  @doc "Trigger initial comb evaluation after ETS has been populated."
  def post_init(name, sim_id) do
    case Registry.lookup(Hw.Sim.Scope.registry(sim_id), {:entity, name}) do
      [{pid, _}] -> send(pid, :post_init)
      [] -> :not_found
    end
  end

  @doc "Force an entity to re-evaluate its comb ops immediately (used by testbench)."
  def eval_now(name, sim_id) do
    GenServer.call(via(sim_id, name), :eval_now)
  end

  @doc """
  Directly set register values in an entity's reg_state, bypassing the clock.
  Also writes to ETS and triggers a comb re-eval so dependent signals update.
  Used by testbench to put entities into a specific state without burning ticks.
  """
  def force_reg(entity_name, reg_values, sim_id) do
    GenServer.call(via(sim_id, entity_name), {:force_reg, reg_values, sim_id})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init({spec, widths, memories, clock_pid, sim_id}) do
    # Initialize reg state from ETS
    reg_state = Map.new(spec.regs, fn %Reg{output: out} ->
      {out.name, State.get(out.name, sim_id)}
    end)

    # Collect names of all signals that have a Reg op — these are latched.
    # Any Assign op that writes to the same signal name is an elaborator
    # intermediate (the mux-tree input to the Reg) and must NOT be in
    # comb_ops, otherwise force_reg values get overwritten by comb eval.
    reg_output_names = MapSet.new(spec.ops, fn
      %Reg{output: out} -> out.name
      _ -> nil
    end) |> MapSet.delete(nil)

    comb_ops = Enum.reject(spec.ops, fn op ->
      match?(%Reg{}, op) or match?(%Mem{}, op) or match?(%Blackbox{}, op) or
      (match?(%Assign{}, op) and MapSet.member?(reg_output_names, op.output.name))
    end)

    state = %__MODULE__{
      spec:      spec,
      reg_state:   reg_state,
      reg_next:    %{},
      clock_pid:   clock_pid,
      widths:    widths,
      memories:  memories,
      comb_ops:  comb_ops,
      time_ps:   0,
      sim_id:    sim_id,
    }

    clock_pids = List.wrap(clock_pid) |> Enum.reject(&is_nil/1)
    if clock_pids != [] do
      {:ok, state, {:continue, :subscribe}}
    else
      {:ok, state, {:continue, :init_eval}}
    end
  end

  @impl true
  def handle_continue(:init_eval, state) do
    # Fires too early — post_init handles the actual initial eval
    {:noreply, state}
  end

  @impl true
  def handle_continue(:subscribe, state) do
    List.wrap(state.clock_pid)
    |> Enum.reject(&is_nil/1)
    |> Enum.each(fn pid ->
      GenServer.cast(pid, {:subscribe, self(), state.spec.name})
    end)
    {:noreply, state}
  end

  @impl true
  def handle_info(:post_init, state) do
    reg_state = Map.new(state.spec.regs, fn %Reg{output: out} ->
      {out.name, State.get(out.name, state.sim_id)}
    end)
    state = %{state | reg_state: reg_state, reg_next: reg_state}
    state = do_eval_comb(state, 0)
    {:noreply, state}
  end

  @impl true
  def handle_info({:edge, :rising, time_ps, from: clock_pid}, state) do
    # Build eval env from ETS + current reg state
    env = build_env(state)

    # Evaluate comb ops first so internal signals (like uart_tx_tick) are
    # available when computing reg-next values below.
    {comb_env, _} = Enum.reduce(state.comb_ops, {env, []}, fn op, {env, acc} ->
      results = Eval.eval(op, env, state.widths, state.memories)
      new_env = Enum.reduce(results, env, fn {name, val}, e -> Map.put(e, name, val) end)
      {new_env, results ++ acc}
    end)

    # Compute next value for each register using the enriched env
    reg_next = Map.new(state.spec.regs, fn reg ->
      Eval.eval_reg_next(reg, comb_env, state.widths)
    end)

    # Reply eval_done to clock process
    send(clock_pid, {:eval_done, self(), state.spec.name, reg_next})

    {:noreply, %{state | reg_next: reg_next, time_ps: time_ps}}
  end

  # ---------------------------------------------------------------------------
  # Phase 2: Commit — latch regs, evaluate comb, write ETS
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:settle, time_ps}, state) do
    # Re-evaluate comb with post-commit ETS state.
    # Used by _top_ to pick up reg values written by other entities during commit.
    state = do_eval_comb(state, time_ps)
    {:noreply, state}
  end

  @impl true
  def handle_info({:commit, time_ps, from: clock_pid}, state) do
    # Latch reg next-values
    new_reg_state = Map.merge(state.reg_state, state.reg_next)
    state = %{state | reg_state: new_reg_state, reg_next: %{}, time_ps: time_ps}

    # Write reg values to ETS so other entities and testbench can read them
    State.put_many(new_reg_state, time_ps, state.sim_id)

    # Evaluate comb ops and write to ETS
    state = do_eval_comb(state, time_ps)

    # Notify the clock that sent this commit that we're done
    send(clock_pid, {:commit_done, self()})

    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Testbench: force immediate comb re-evaluation
  # ---------------------------------------------------------------------------

  @impl true
  def handle_call(:eval_now, _from, state) do
    state = do_eval_comb(state, state.time_ps)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:force_reg, reg_values, sim_id}, _from, state) do
    # reg_values keys must be fully-prefixed signal names (e.g. :cdc_dev_state)
    # Patch both reg_state (current) and reg_next (survives next commit)
    new_reg_state = Map.merge(state.reg_state, reg_values)
    new_reg_next  = Map.merge(state.reg_next,  reg_values)
    state = %{state | reg_state: new_reg_state, reg_next: new_reg_next}
    State.put_many(reg_values, state.time_ps, sim_id)
    state = do_eval_comb(state, state.time_ps)
    {:reply, :ok, state}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Build the evaluation environment: targeted ETS reads for external inputs
  # plus current reg state for this entity's own registers.
  # _top_ uses a full snapshot since it reads signals from all entities.
  defp build_env(%{spec: %{name: :_top_}} = state) do
    ets_vals = Hw.Sim.State.snapshot(state.sim_id)
    Map.merge(ets_vals, state.reg_state)
  end

  defp build_env(state) do
    ets_vals = state.spec.inputs
      |> Enum.map(fn sig -> {sig, State.get(sig, state.sim_id)} end)
      |> Map.new()
    Map.merge(ets_vals, state.reg_state)
  end

  # Evaluate all comb ops in order, accumulating outputs, then write to ETS
  defp do_eval_comb(state, time_ps) do
    env = build_env(state)

    {_env, outputs} = Enum.reduce(state.comb_ops, {env, []}, fn op, {env, acc} ->
      results = Eval.eval(op, env, state.widths, state.memories)
      new_env = Enum.reduce(results, env, fn {name, val}, e -> Map.put(e, name, val) end)
      {new_env, results ++ acc}
    end)

    State.put_many(outputs, time_ps, state.sim_id)

    state
  end

end
