defmodule Hw.Sim.Nif do
  @moduledoc """
  Rustler NIF wrapper for the hw_sim_nif crate.

  Provides a fast Rust-based simulation loop that replaces the Elixir
  GenServer-per-entity architecture for bulk tick execution.

  The NIF compiles a `%Hw.Sim.Schedule{}` into an opaque Rust automaton
  resource, then drives it N ticks at a time entirely in Rust — no BEAM
  message round-trips, no ETS, no Elixir involvement mid-tick.

  ## Usage

      {:ok, auto} = Hw.Sim.Nif.compile(schedule)
      {:ok, auto, changes} = Hw.Sim.Nif.tick(auto, :clk_48, 480_000)
      {:ok, val} = Hw.Sim.Nif.get_signal(auto, :dp_diff)
      :ok = Hw.Sim.Nif.set_signal(auto, :dp_diff, 1)

  `changes` is a list of `{time_ps, signal_name_atom, old_val, new_val}`
  tuples for every register that changed value during the tick run.
  These can be fed directly into ElixirScope or used for DSL export.
  """

  use Rustler,
    otp_app: :ehdl,
    crate: :hw_sim_nif,
    path: "native/hw_sim_nif"

  @doc """
  Compile a schedule into a Rust automaton resource.

  `compiled` is the map produced by `Hw.Sim.Compiler.compile/1`.
  Returns `{:ok, automaton_ref}`.
  """
  def compile(_compiled), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Run `n` rising edges of `clock_name` on the automaton.

  Runs in a dirty CPU scheduler — safe to call for large N.
  Returns `{:ok, changes}` where changes is
  `[{time_ps, signal_atom, old_val, new_val}]`.

  The automaton resource is mutated in-place (behind a Mutex).
  """
  def tick(_automaton, _clock_name, _n), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Read a signal value by name atom."
  def get_signal(_automaton, _name), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Write a signal value by name atom (testbench stimulus)."
  def set_signal(_automaton, _name, _value), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Get current simulation time in picoseconds."
  def get_time(_automaton), do: :erlang.nif_error(:nif_not_loaded)
end
