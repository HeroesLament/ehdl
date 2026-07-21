defmodule Hw.Sim.Scope do
  @moduledoc """
  Per-simulation process name scoping.

  Each simulation instance gets a unique reference stored in the supervisor's
  process dictionary. All named processes derive their registered names from
  this ref so multiple sims can coexist.
  """

  @key :hw_sim_scope_id

  @doc "Store the sim_id in the calling process (supervisor)."
  def put(sim_id), do: Process.put(@key, sim_id)

  @doc "Read the sim_id from the calling process."
  def get, do: Process.get(@key)

  @doc "Registry name scoped to a sim_id."
  def registry(sim_id), do: :"Hw.Sim.Registry.#{inspect(sim_id)}"

  @doc "State GenServer name scoped to a sim_id."
  def state(sim_id), do: :"Hw.Sim.State.#{inspect(sim_id)}"

  @doc "TimeArbiter GenServer name scoped to a sim_id."
  def arbiter(sim_id), do: :"Hw.Sim.TimeArbiter.#{inspect(sim_id)}"

  @doc "Via tuple for a clock in this sim."
  def clock_via(sim_id, clock_name),
    do: {:via, Registry, {registry(sim_id), {:clock, clock_name}}}

  @doc "Via tuple for an entity in this sim."
  def entity_via(sim_id, entity_name),
    do: {:via, Registry, {registry(sim_id), {:entity, entity_name}}}
end
