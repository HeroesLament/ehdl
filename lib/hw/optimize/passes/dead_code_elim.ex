defmodule Hw.Optimize.Passes.DeadCodeElim do
  @moduledoc """
  Dead code elimination. **Stub — implemented in Pass 2.**

  Will remove ops whose output signal is never used and is not an observable
  port (not output/inout, not a clock). This is the exact dual of the
  `Hw.Analysis.Rules.DeadRegister` rule — the same reachability walk, but it
  *deletes* what the rule *warns* about. Runs last (and again after each
  structural pass, to a fixpoint) to sweep intermediates the other passes
  orphan.
  """
  @behaviour Hw.Optimize.Pass

  @impl true
  def name, do: :dce

  @impl true
  def run(design, _opts), do: design
end
