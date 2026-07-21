defmodule Hw.Sim do
  @moduledoc """
  EHDL simulator — run elaborated designs as BEAM processes.

  Multiple simulations can run concurrently. Each `start/2` returns a `sim`
  handle that scopes all API calls to that instance.

      {:ok, sim} = Hw.Sim.start(HelloBoard.Top)
      Hw.Sim.set(sim, :wifi_txd, 0)
      Hw.Sim.tick(sim, :clk_48, 10)
      Hw.Sim.get(sim, :cdc_tx_valid)
      Hw.Sim.stop(sim)
  """

  alias Hw.Sim.{State, Entity, Testbench, Scope}

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Start a simulation. Returns {:ok, sim} where sim is an opaque handle."
  def start(design_module, opts \\ []) do
    vcd_path = Keyword.get(opts, :vcd)
    sim_id   = make_ref()

    design   = Hw.Compile.Elaborate.elaborate(design_module)
    schedule = Hw.Sim.Schedule.build(design, design_module)

    {:ok, sup} = Hw.Sim.Supervisor.start_link({schedule, vcd_path, sim_id})

    sim = %{sup: sup, sim_id: sim_id, schedule: schedule}

    # Populate ETS with correct initial values
    State.init_signals(schedule, sim_id)

    # Cache closures + widths in the process dictionary keyed by sim_id so
    # Testbench.get can retrieve them without an ETS round-trip on every call.
    Process.put({:hw_sim_closures, sim_id}, schedule.top_signal_closures)
    Process.put({:hw_sim_widths, sim_id}, schedule.signal_widths)

    Enum.each(schedule.entities, fn {name, _} -> Entity.post_init(name, sim_id) end)

    {:ok, sim}
  end

  @doc "Stop a simulation and clean up all processes."
  def stop(%{sup: sup}) do
    try do
      Supervisor.stop(sup, :normal)
    catch
      :exit, _ -> :ok
    end
  end

  @doc "Read the current value of a signal."
  def get(%{sim_id: sid}, signal_name) do
    Testbench.get(signal_name, sid)
  end

  @doc "Drive a signal to a value."
  def set(%{sim_id: sid}, signal_name, value),
    do: Testbench.set(signal_name, value, sid)

  @doc """
  Directly force register values in a named entity, bypassing the clock.
  Use this in tests to put hardware state machines into a specific state
  without simulating the ticks needed to get there naturally.

      Hw.Sim.force_reg(sim, :cdc, %{dev_state: 3, ep1_in_toggle: 0})
  """
  def force_reg(%{sim_id: sid}, entity_name, reg_values) do
    Hw.Sim.Entity.force_reg(entity_name, reg_values, sid)
    Entity.eval_now(:_top_, sid)
    State.clear_top_dirty(sid)
  end

  @doc """
  Force a single signal value by name, auto-routing to the correct entity.
  Used by the defhw interpreter to drive signals without knowing entity topology.
  """
  def force_reg_raw(%{sim_id: sid, schedule: schedule} = sim, signal_name, value) do
    # Find which entity owns this signal
    entity_name = schedule.entities
      |> Enum.find(fn {_, e} ->
        Enum.any?(e.regs, fn r -> r.output.name == signal_name end)
      end)
      |> then(fn
        {name, _} -> name
        nil -> :_top_
      end)

    Hw.Sim.Entity.force_reg(entity_name, %{signal_name => value}, sid)
    Entity.eval_now(:_top_, sid)
    State.clear_top_dirty(sid)
    sim
  end

  @doc """
  Resolve the signal prefix for a component module in this simulation.

  Returns `""` for standalone designs, `"uart_tx_"` etc. for instances.
  """
  def prefix(sim, module, opts \\ []) do
    Hw.Sim.DefhwInterpreter.resolve_prefix(sim, module, opts)
  end

  @doc """
  Apply a defhw against a live simulation.

  Combinational defhws execute instantly (no clock cycles consumed).
  Sequential defhws tick the component's clock until `on` conditions are met.

      Hw.UART.TX.send(sim, 0x55)
      # which internally calls:
      Hw.Sim.apply_defhw(sim, Hw.UART.TX, :send, [0x55])
  """
  def apply_defhw(sim, module, name, args \\ [], opts \\ []) do
    Hw.Sim.DefhwInterpreter.apply(sim, module, name, args, opts)
  end

  @doc "Advance simulation by n rising edges of the named clock (blocking)."
  def tick(%{sim_id: sid}, clock_name, n \\ 1) do
    Testbench.tick(clock_name, n, sid)
  end

  @doc "Wait for a signal to reach a value."
  def wait_for(%{sim_id: sid}, signal_name, value, opts \\ []),
    do: Testbench.wait_for(signal_name, value, sid, opts)

  @doc "Assert a signal value. Raises on mismatch."
  def assert(%{sim_id: sid}, signal_name, expected),
    do: Testbench.assert(signal_name, expected, sid)

  @doc "Send a UART byte on the given signal line."
  def uart_send(%{sim_id: sid}, signal_name, byte, opts \\ []) do
    result = Testbench.uart_send(signal_name, byte, sid, opts)
    Entity.eval_now(:_top_, sid)
    result
  end

  @doc "Receive a UART byte from the given signal line."
  def uart_recv(%{sim_id: sid}, signal_name, opts \\ []),
    do: Testbench.uart_recv(signal_name, sid, opts)

end


defmodule Hw.Sim.Supervisor do
  @moduledoc "Supervisor for a single simulation run."
  use Supervisor

  alias Hw.Sim.{State, TimeArbiter, Clock, Entity, Scope}

  def start_link({schedule, vcd_path, sim_id}) do
    Supervisor.start_link(__MODULE__, {schedule, vcd_path, sim_id})
  end

  @impl true
  def init({schedule, vcd_path, sim_id}) do
    registry_name = Scope.registry(sim_id)
    state_name    = Scope.state(sim_id)
    arbiter_name  = Scope.arbiter(sim_id)

    entity_clock_domains = schedule.entities
      |> Enum.map(fn {_, e} -> e.domain end)
      |> Enum.reject(&is_nil/1)

    # Also include clocks used directly by _top_ logic blocks (flat components
    # with no child instances have all logic in _top_ with domain nil, but the
    # design still declares clocks that must be started for tick/2 to work).
    design_clock_names = schedule.clocks |> Enum.map(& &1.name)

    active_clocks = (entity_clock_domains ++ design_clock_names) |> Enum.uniq()

    clock_specs = schedule.clocks
      |> Enum.filter(fn clk -> clk.name in active_clocks end)

    children = [
      {Registry, keys: :unique, name: registry_name},
      {State, [sim_id: sim_id, name: state_name, schedule: schedule]},
      {TimeArbiter, [sim_id: sim_id, name: arbiter_name]},
    ]

    clock_children = Enum.map(clock_specs, fn clk ->
      %{
        id: {:clock, clk.name},
        start: {Clock, :start_link, [{clk.name, clk.freq_mhz, arbiter_name, sim_id,
                                       schedule.cross_settle_ops, schedule.cross_settle_inputs,
                                       schedule.signal_widths}]},
      }
    end)

    entity_children = Enum.map(schedule.entities, fn {name, entity} ->
      clock_pid = cond do
        entity.domain  -> Scope.clock_via(sim_id, entity.domain)
        true           -> nil
      end

      %{
        id: {:entity, name},
        start: {Entity, :start_link,
                [{entity, schedule.signal_widths, schedule.memories, clock_pid, sim_id}]},
      }
    end)

    vcd_children = if vcd_path do
      [%{id: :vcd, start: {Hw.Sim.VCD, :start_link, [{vcd_path, schedule, sim_id}]}}]
    else
      []
    end

    Supervisor.init(
      children ++ clock_children ++ entity_children ++ vcd_children,
      strategy: :one_for_one
    )
  end
end
