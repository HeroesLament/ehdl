defmodule Hw.Sim.Backend do
  @moduledoc """
  Simulator backend behaviour for EHDL.

  This is EHDL's equivalent of Hardcaml's Cyclesim interface — the stable
  contract that all simulation backends must satisfy, so that higher-level
  tooling (waveform capture, testbenches, assertions) can be written once
  and run against any backend.

  ## Current backends

    - `Hw.Sim.Backend.Nif`    — Rust compiled automaton (fast, default)
    - `Hw.Sim.Backend.Elixir` — pure Elixir GenServer-per-entity (debuggable)

  ## Contract

  A backend is initialised with a compiled schedule, then driven through
  a simple interface:

      {:ok, sim} = Hw.Sim.Backend.Nif.init(schedule)
      {:ok, sim} = Hw.Sim.Backend.poke(sim, :dp, 1)
      {:ok, sim, changes} = Hw.Sim.Backend.step(sim, :clk_48, 10)
      {:ok, val} = Hw.Sim.Backend.peek(sim, :rx_state)
      {:ok, snap} = Hw.Sim.Backend.snapshot(sim)

  `changes` is a list of `{time_ps, signal_atom, old_val, new_val}` tuples —
  the same format returned by `Hw.Sim.Nif.tick/3` — and can be fed
  directly into `Hw.Waveform.record/2`.

  ## Waveform integration

  Because `step/3` always returns a change log in the same format, waveform
  capture is backend-agnostic:

      {sim, waves} = Hw.Waveform.attach(sim, schedule, signals: :ports)

      sim = Hw.Sim.Backend.poke!(sim, :incr, 1)
      {sim, waves} = Hw.Sim.Backend.step_wave(sim, waves, :clk_48, 5)

      IO.puts Hw.Waveform.render(waves)

  See `step_wave/4` for the combined step-and-record helper.
  """

  alias Hw.Waveform

  # Schedule doesn't define @type t/0, so we reference the struct directly
  # in specs rather than Schedule.t() to keep Dialyzer happy.
  @type schedule :: %Hw.Sim.Schedule{}

  # ---------------------------------------------------------------------------
  # Behaviour definition
  # ---------------------------------------------------------------------------

  @doc """
  Initialise a backend from a compiled schedule.

  Returns `{:ok, sim_ref}` where `sim_ref` is an opaque backend-specific
  handle. The initial signal state mirrors the schedule's `signal_inits`.
  """
  @callback init(%Hw.Sim.Schedule{}, keyword()) ::
    {:ok, term()} | {:error, term()}

  @doc """
  Write a signal value (testbench stimulus).

  Equivalent to driving an input port. The backend should update its
  internal state immediately; the change will be visible on the next
  combinational evaluation.
  """
  @callback poke(term(), atom(), integer()) ::
    {:ok, term()} | {:error, term()}

  @doc """
  Read the current value of a signal.

  For combinational signals, the returned value reflects all pokes applied
  before the most recent `step/3`. For registered signals, it reflects the
  state after the most recent clock edge.
  """
  @callback peek(term(), atom()) ::
    {:ok, integer()} | {:error, term()}

  @doc """
  Advance simulation by `n` rising edges of the named clock.

  Returns `{:ok, updated_sim, changes}` where `changes` is a list of
  `{time_ps, signal_atom, old_val, new_val}` tuples for every register
  that changed during the step.

  This is the single cycle-advance primitive. All timing and sequencing
  is expressed through repeated calls to `step/3`.
  """
  @callback step(term(), atom(), pos_integer()) ::
    {:ok, term(), [{non_neg_integer(), atom(), integer(), integer()}]}
    | {:error, term()}

  @doc """
  Snapshot the complete signal state as a flat map.

  Returns `{:ok, %{signal_atom => integer()}}` for every signal known
  to the backend. Used by `Hw.Waveform.record_snapshot/3` and for
  diagnostic dumps.
  """
  @callback snapshot(term()) ::
    {:ok, %{atom() => integer()}} | {:error, term()}

  @doc """
  Return metadata about the backend instance.

  At minimum should include `:backend` (module name) and `:clock_names`.
  """
  @callback metadata(term()) :: map()

  # ---------------------------------------------------------------------------
  # Optional callback
  # ---------------------------------------------------------------------------

  @optional_callbacks [metadata: 1]

  # ---------------------------------------------------------------------------
  # Shared helpers — backend-agnostic, operate on the {backend_module, sim_ref}
  # tuple returned by `init/2` below
  # ---------------------------------------------------------------------------

  @doc """
  Initialise a backend by module. Returns `{:ok, {mod, ref}}`.

  Prefer this over calling `mod.init/2` directly so that helpers like
  `poke/3`, `peek/2`, `step/3` work without knowing the backend.

      {:ok, sim} = Hw.Sim.Backend.init(Hw.Sim.Backend.Nif, schedule)
  """
  @spec init(module(), %Hw.Sim.Schedule{}, keyword()) :: {:ok, {module(), term()}} | {:error, term()}
  def init(backend_mod, %Hw.Sim.Schedule{} = schedule, opts \\ []) do
    case backend_mod.init(schedule, opts) do
      {:ok, ref} -> {:ok, {backend_mod, ref}}
      err        -> err
    end
  end

  @doc "Poke a signal. See `c:poke/3`."
  @spec poke({module(), term()}, atom(), integer()) :: {:ok, {module(), term()}} | {:error, term()}
  def poke({mod, ref}, signal, value) do
    case mod.poke(ref, signal, value) do
      {:ok, ref2} -> {:ok, {mod, ref2}}
      err         -> err
    end
  end

  @doc "Poke a signal. Raises on error."
  @spec poke!({module(), term()}, atom(), integer()) :: {module(), term()}
  def poke!(sim, signal, value) do
    case poke(sim, signal, value) do
      {:ok, updated}   -> updated
      {:error, reason} -> raise "Hw.Sim.Backend.poke!/3 failed for #{signal}: #{inspect(reason)}"
    end
  end

  @doc "Peek a signal. See `c:peek/2`."
  @spec peek({module(), term()}, atom()) :: {:ok, integer()} | {:error, term()}
  def peek({mod, ref}, signal), do: mod.peek(ref, signal)

  @doc "Peek a signal. Raises on error."
  @spec peek!({module(), term()}, atom()) :: integer()
  def peek!(sim, signal) do
    case peek(sim, signal) do
      {:ok, val}       -> val
      {:error, reason} -> raise "Hw.Sim.Backend.peek!/2 failed for #{signal}: #{inspect(reason)}"
    end
  end

  @doc "Step the simulation. See `c:step/3`."
  @spec step({module(), term()}, atom(), pos_integer()) ::
    {:ok, {module(), term()}, list()} | {:error, term()}
  def step({mod, ref}, clock, n \\ 1) do
    case mod.step(ref, clock, n) do
      {:ok, ref2, changes} -> {:ok, {mod, ref2}, changes}
      err                  -> err
    end
  end

  @doc """
  Step and record into a waveform in one call.

  Returns `{{mod, ref}, updated_waves}`.

      {sim, waves} = Hw.Sim.Backend.step_wave(sim, waves, :clk_48, 10)
  """
  @spec step_wave({module(), term()}, Waveform.t(), atom(), pos_integer()) ::
    {{module(), term()}, Waveform.t()} | {:error, term()}
  def step_wave(sim, %Waveform{} = waves, clock, n \\ 1) do
    case step(sim, clock, n) do
      {:ok, updated_sim, changes} ->
        {updated_sim, Waveform.record(waves, changes)}
      err ->
        err
    end
  end

  @doc """
  Step `n` times, recording one waveform sample per tick.

  Unlike `step_wave/4` which records a single sample for the entire batch,
  this steps one tick at a time so every clock edge becomes its own cycle
  in the waveform. Combinational signals are captured via a full snapshot
  after each tick, since they don't appear in the sparse change log.

      {sim, waves} = Hw.Sim.Backend.step_wave_each(sim, waves, :clk, 80)
  """
  @spec step_wave_each({module(), term()}, Waveform.t(), atom(), pos_integer()) ::
    {{module(), term()}, Waveform.t()} | {:error, term()}
  def step_wave_each(sim, %Waveform{} = waves, clock, n) do
    Enum.reduce_while(1..n, {sim, waves}, fn _, {s, w} ->
      case step(s, clock, 1) do
        {:ok, updated_sim, _changes} ->
          # Use a full snapshot so combinational signals (which never appear
          # in the sparse change log) are recorded with their correct values.
          case snapshot(updated_sim) do
            {:ok, snap} ->
              {:cont, {updated_sim, Waveform.record_snapshot(w, snap, w.last_time_ps)}}
            {:error, _} ->
              # Snapshot not available — record a blank cycle to advance counter
              {:cont, {updated_sim, Waveform.record(w, [])}}
          end
        err ->
          {:halt, err}
      end
    end)
  end

  @doc "Snapshot the full signal state. See `c:snapshot/1`."
  @spec snapshot({module(), term()}) :: {:ok, map()} | {:error, term()}
  def snapshot({mod, ref}), do: mod.snapshot(ref)

  @doc "Return backend metadata. See `c:metadata/1`."
  @spec metadata({module(), term()}) :: map()
  def metadata({mod, ref}) do
    if (Code.ensure_loaded?(mod) and function_exported?(mod, :metadata, 1)) do
      mod.metadata(ref)
    else
      %{backend: mod}
    end
  end
end

# ---------------------------------------------------------------------------
# Nif backend implementation
# ---------------------------------------------------------------------------

defmodule Hw.Sim.Backend.Nif do
  @moduledoc """
  `Hw.Sim.Backend` implementation backed by the Rust NIF automaton.

  This is the primary production backend. Simulation runs entirely in Rust
  on a dirty CPU scheduler — no BEAM message round-trips mid-tick.

  ## Usage

      schedule = Hw.Sim.Schedule.build(design)
      {:ok, sim} = Hw.Sim.Backend.init(Hw.Sim.Backend.Nif, schedule)

      {:ok, sim} = Hw.Sim.Backend.poke(sim, :dp, 1)
      {:ok, sim, changes} = Hw.Sim.Backend.step(sim, :clk_48, 100)
      {:ok, val} = Hw.Sim.Backend.peek(sim, :dp)

  Or use `Hw.Sim.Backend` helpers directly (same thing):

      {sim, waves} = Hw.Sim.Backend.step_wave(sim, waves, :clk_48, 10)
  """

  @behaviour Hw.Sim.Backend

  alias Hw.Sim.{Nif, Compiler}

  @impl true
  def init(%Hw.Sim.Schedule{} = schedule, _opts \\ []) do
    compiled     = Compiler.compile(schedule)
    signal_names = schedule.signal_widths |> Map.keys() |> Enum.sort()

    case Nif.compile(compiled) do
      {:ok, auto} -> {:ok, {auto, signal_names}}
      err         -> err
    end
  end

  @impl true
  def poke({auto, names}, signal, value) do
    case Nif.set_signal(auto, signal, value) do
      :ok -> {:ok, {auto, names}}
      err -> err
    end
  end

  @impl true
  def peek({auto, _names}, signal) do
    Nif.get_signal(auto, signal)
  end

  @impl true
  def step({auto, names}, clock, n) do
    case Nif.tick(auto, clock, n) do
      {:ok, changes} -> {:ok, {auto, names}, changes}
      err            -> err
    end
  end

  @impl true
  def snapshot({auto, names}) do
    result =
      Enum.reduce_while(names, %{}, fn name, acc ->
        case Nif.get_signal(auto, name) do
          {:ok, val} -> {:cont, Map.put(acc, name, val)}
          err        -> {:halt, {:error, err}}
        end
      end)

    case result do
      {:error, _} = err -> err
      map               -> {:ok, map}
    end
  end

  @impl true
  def metadata({auto, names}) do
    t = case Nif.get_time(auto) do
      {:ok, t} -> t
      _        -> nil
    end
    %{backend: __MODULE__, time_ps: t, signal_count: length(names)}
  end
end
