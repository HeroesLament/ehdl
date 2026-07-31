defmodule Hw.Compile.Elaborate.Gensym do
  @moduledoc """
  Deterministic name counter for elaboration-generated signals.

  ## Why this exists

  Elaboration names its intermediate signals `_mux_42628`, `_eq_42596` and so
  on. Those numbers used to come from `:erlang.unique_integer([:positive])`,
  which is unique per NODE and never resets. Two consecutive builds of the same
  unchanged design therefore produced Verilog that was structurally identical --
  same line count, same topology -- with every generated name shifted by a
  constant offset, because the counter's starting value depended on how much
  unrelated work the BEAM had done before elaboration began.

  That is not cosmetic. yosys and nextpnr order, hash and tie-break on net
  names, so a rename changes placement, which changes routing. The observable
  consequence was that seed 4 routed the radio one evening and failed to route
  it the next, against byte-identical nextpnr source.

  Which means every seed sweep this project has ever run -- 377 seeds here, 755
  there -- was sweeping a moving target. "Seed N routes" was never a property of
  seed N. A recorded winning seed could not be trusted to rebuild, and a route
  rate measured across seeds was conflating two different sources of variance.

  ## How

  A counter in the process dictionary, reset at the start of each elaboration.
  The process dictionary rather than threading a counter through `design`
  because the latter would touch all ~60 call sites in expr.ex and
  sequential.ex for no behavioural gain, and elaboration already runs in a
  single process.

  That last part is the load-bearing assumption: **if elaboration is ever made
  concurrent, this silently goes back to being nondeterministic** -- worse than
  before, because it will look fixed. Anything parallelising elaboration must
  replace this with a counter threaded through the design struct.
  """

  @key :hw_gensym_counter

  @doc "Reset the counter. Call once at the start of each elaboration."
  def reset, do: Process.put(@key, 0)

  @doc "Next value in this elaboration. Deterministic given a deterministic traversal."
  def next do
    n = Process.get(@key, 0)
    Process.put(@key, n + 1)
    n
  end
end
