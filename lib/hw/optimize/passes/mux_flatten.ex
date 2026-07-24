defmodule Hw.Optimize.Passes.MuxFlatten do
  @moduledoc """
  Mux-tree flattening and selector sharing. **Stub — implemented in Pass 2.**

  Two transforms will land here:

    * **Common-tail hoist** — when every arm of a `Mux` assigns the same value
      to a signal, that assignment is invariant: pull it out and delete the
      per-bit mux tree for it.
    * **Selector sharing** — sibling `Mux` ops over the *same* condition/selector
      (the CDC dispatch assigns 8+ EP-IN-bus signals under one `hdl_case`, i.e.
      8 independent mux trees replicating the same decode) share one decoded
      select. The big structural win against the `_case_` bucket.
  """
  @behaviour Hw.Optimize.Pass

  @impl true
  def name, do: :mux_flatten

  @impl true
  def run(design, _opts), do: design
end
