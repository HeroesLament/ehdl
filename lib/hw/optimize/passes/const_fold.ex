defmodule Hw.Optimize.Passes.ConstFold do
  @moduledoc """
  Constant folding and bit propagation. **Stub — implemented in Pass 2.**

  Will fold ops with constant inputs (`x & 0 -> 0`, `x | all-ones -> x`,
  `Concat` of constants -> one constant, compares against constants with a
  statically-known result, `Slice`/`Cast` of a constant) and propagate constant
  bits so downstream slices/muxes narrow. Runs first because it canonicalises
  shapes that make CSE and MuxFlatten hit more.
  """
  @behaviour Hw.Optimize.Pass

  @impl true
  def name, do: :const_fold

  @impl true
  def run(design, _opts), do: design
end
