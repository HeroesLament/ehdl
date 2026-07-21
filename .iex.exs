# Boot ElixirScope's TraceDB (backs the live Simtrace path) if available.
if Code.ensure_loaded?(ElixirScope) and is_nil(Process.whereis(ElixirScope.TraceDB)) do
  ElixirScope.setup(tracing_level: :states_only)
end

# ---------------------------------------------------------------------------
# Interactive convenience layer for the unified trace subsystem.
#
# Only affects the IEx prompt — never compilation or tests. Lets you drive a
# sim and poke at a trace without fully-qualified module names:
#
#     sched = Hw.Waveform.ExUnit.build_schedule(MyDesign)
#     {:ok, sim} = Backend.init(Backend.Nif, sched)
#     trace = Adapter.Nif.new(sched, signals: [:led, :counter])
#     {sim, trace} = Adapter.Nif.step_wave_each(sim, trace, :clk, 16)
#
#     find_when(trace, [], led: 1)          # bare, via `import`
#     transitions(trace, [], :led)
#     diff(trace, [], {:index, 2}, {:index, 5})
#     IO.puts Render.ascii(trace, width: 60)
#     assert_reaches(trace, "cdc.dev_state", 2, by: 2000)
# ---------------------------------------------------------------------------

# Aliases — short module names at the prompt.
alias Hw.Trace
alias Hw.Trace.{Render, VCD, Scope}
alias Hw.Trace.Adapter
alias Hw.Sim
alias Hw.Sim.Backend
alias Hw.Simtrace

# Imports — bare query + assertion verbs.
# (`import` is a macro requiring a literal module; import each directly.)
import Hw.Trace.Query
# ExUnit also re-exports find_when/3; exclude it so `find_when` stays unambiguous.
import Hw.Trace.ExUnit, except: [find_when: 3]

IO.puts([
  IO.ANSI.faint(),
  "ehdl: trace helpers loaded — Trace, Query (find_when/transitions/diff), ",
  "Render, VCD, Backend, Sim, Simtrace. See .iex.exs.",
  IO.ANSI.reset()
])
