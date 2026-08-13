defmodule HelloBoard.SimSetup do
  @moduledoc """
  Simulation setup shared by the `HelloBoard` tests.

  ## Why this module exists

  Eight test modules each carried their own copy of "put the reset generator into
  its released state", spelled as four forced registers of a `ResetSync`
  component. When `HelloBoard.Top` replaced `ResetSync` with `Hw.ReEnum` — a
  documented, deliberate refactor, noted in the design as *"Replaces the old
  ResetSync + rst_arm indirection"* — those eight copies were not updated, and
  every test in all eight modules failed in `setup`.

  That was 41 of the suite's failures: the entire pre-existing failure cluster,
  and the reason the suite could not be used as a gate. Not one bug, and nothing
  wrong with the simulator — just design knowledge copied into eight places and
  updated in one.

  So the knowledge lives here, next to the design that owns it. The next reset
  refactor changes one function.

  ## Why it was silent for so long

  `Hw.Sim.force_reg/3` used to `GenServer.call` an unregistered name and exit with
  `no process`, which named neither the entity nor the design. It also merged
  unknown register keys in without comment, so a stale *signal* name — as opposed
  to a stale entity — forced nothing at all and said nothing. Both are validated
  now; see `Hw.Sim.force_reg/3`.
  """

  @doc """
  Release the reset generator, as if power-on hold had expired with the PLL locked.

  `Hw.ReEnum` drives `rst = holding or not lock_s2`, so releasing reset means
  clearing `holding` and presenting a synchronised `pll_locked`. `hold_cnt` and
  `reenum` are cleared too, so the generator sits in a settled post-hold state
  rather than one cycle away from re-entering a window.

  These registers live in the `:_top_` entity rather than one of their own:
  `Hw.Sim.Schedule`'s entity partitioning works off a hardcoded signal-prefix
  table, and `reset_gen_` is not in it. Worth knowing before looking for a
  `:reset_gen` entity that does not exist.

  Callers should `Hw.Sim.set(sim, :pll_locked, 1)` first if they care about the
  state surviving subsequent ticks — the sync flops forced here will follow the
  input on the next edge.
  """
  def release_reset(sim) do
    Hw.Sim.force_reg(sim, :_top_, %{
      reset_gen_holding: 0,
      reset_gen_hold_cnt: 0,
      reset_gen_reenum: 0,
      reset_gen_lock_s1: 1,
      reset_gen_lock_s2: 1,
      reset_gen_locked_d: 1
    })

    sim
  end
end
