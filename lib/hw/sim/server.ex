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

  Keys are **fully-prefixed** register names, matching what the design emits:

      Hw.Sim.force_reg(sim, :cdc, %{cdc_dev_state: 3, cdc_ep1_in_toggle: 0})

  This example used to be written `%{dev_state: 3, ep1_in_toggle: 0}` — without
  the prefix, and therefore wrong. Nothing complained, because unknown keys were
  merged in and written where no one reads them, so the documented call silently
  forced nothing. Both the entity name and every key are now validated.
  """
  def force_reg(%{sim_id: sid, schedule: schedule}, entity_name, reg_values) do
    validate_force_reg!(schedule, entity_name, reg_values)
    Hw.Sim.Entity.force_reg(entity_name, reg_values, sid)
    Entity.eval_now(:_top_, sid)
    State.clear_top_dirty(sid)
  end

  # Both of these used to be undiagnosed, and between them they cost this repo a
  # test suite that could not be used as a gate.
  #
  # An entity name that does not exist reached `GenServer.call` on an unregistered
  # via-tuple and exited with `no process` from `setup`. Forty-one failures across
  # eight modules said that and nothing else; the actual cause was that
  # `designs/hello_board/top.ex` had been refactored to `Hw.ReEnum` and the string
  # `rst_sync` no longer appears in it at all, while seven test files still force
  # an `:rst_sync` entity.
  #
  # A *signal* name that does not exist was worse, because it was silent:
  # `handle_call({:force_reg, ...})` does `Map.merge(state.reg_state, reg_values)`,
  # which accepts any key whatsoever and writes it to ETS where nothing reads it.
  # A test could force `cdc_ep1_toggle` when the register is `cdc_ep1_in_toggle`,
  # get no complaint, and go on to exercise a state it never actually set up --
  # passing vacuously, or failing somewhere unrelated. The simulator is the
  # instrument every other claim in this project is measured with, so an
  # instrument that accepts a typo without comment is the most expensive kind of
  # bug available here.
  defp validate_force_reg!(schedule, entity_name, reg_values) do
    case Map.get(schedule.entities, entity_name) do
      nil ->
        known = schedule.entities |> Map.keys() |> Enum.sort() |> Enum.map_join(", ", &inspect/1)

        raise ArgumentError,
              "no entity #{inspect(entity_name)} in this design\n\n" <>
                "  entities : #{known}\n\n" <>
                "Entities are derived from signal-name prefixes, so an entity only\n" <>
                "exists if the design still produces signals with its prefix. If this\n" <>
                "name used to work, the design was probably refactored out from under\n" <>
                "the test.\n"

      entity ->
        known = MapSet.new(entity.regs, & &1.output.name)

        case Enum.reject(Map.keys(reg_values), &MapSet.member?(known, &1)) do
          [] ->
            :ok

          unknown ->
            plural = if length(unknown) > 1, do: "s", else: ""
            names = Enum.map_join(unknown, ", ", &inspect/1)
            regs = known |> Enum.sort() |> Enum.map_join(", ", &inspect/1)

            raise ArgumentError,
                  "#{inspect(entity_name)} has no register#{plural} #{names}\n\n" <>
                    "  registers : #{regs}\n" <>
                    suggestions(unknown, known, entity) <>
                    "\nKeys must be fully-prefixed register names. Unknown keys used to be\n" <>
                    "merged in silently and written where nothing reads them, so the forced\n" <>
                    "state never took effect.\n"
        end
    end
  end

  # The mistake worth spelling out: dropping the entity prefix. The docstring
  # example above this function once showed unprefixed keys, so it is not a
  # hypothetical confusion.
  defp suggestions(unknown, known, entity) do
    prefix = entity.prefix || ""

    hints =
      for name <- unknown,
          prefixed = :"#{prefix}#{name}",
          MapSet.member?(known, prefixed) do
        "    #{inspect(name)} -> #{inspect(prefixed)} (missing the #{inspect(prefix)} prefix)"
      end

    case hints do
      [] -> ""
      hints -> "\n  did you mean:\n" <> Enum.join(hints, "\n") <> "\n"
    end
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
