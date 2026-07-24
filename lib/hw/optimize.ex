defmodule Hw.Optimize do
  @moduledoc """
  IR-level optimizer: a pure `%Design{} -> %Design{}` transform that runs
  between `Design.finalize/1` and Verilog emission.

  ## Why this exists

  yosys already runs its full `opt`/`abc` gate pipeline and still lands the
  reference design at ~5,497 LUT4. The redundancy is *structural* — introduced
  by how the elaborator lowers nested `if`/`case`/`hdl_case` into per-signal,
  per-bit `Mux` trees — and it is gone by the time yosys sees flattened Verilog.
  The place to fix it is where the structure is still legible: the frozen
  `Hw.IR.Design`.

  ## Pass manager

  Runs an ordered list of passes to a fixpoint (re-running until the op count
  stabilises), so cheap passes (fold, DCE) get another shot after structural
  passes expose new opportunities. Each pass is a
  `Hw.Optimize.Pass` — a pure `%Design{} -> %Design{}`.

      Hw.Optimize.run(design, optimize: true)                 # full stack
      Hw.Optimize.run(design, optimize: true, only: [:cse])   # one pass
      Hw.Optimize.run(design, optimize: true, skip: [:cse])   # all but one

  The optimizer is **inert unless `opts[:optimize]` is truthy** — the emit path
  passes `opts` straight through, so nothing changes until a build explicitly
  asks for it.

  ## Metrics

  Every pass reports `{ops_before, ops_after, signals_removed}` so IR-level
  shrinkage is visible *before* paying for a synthesis run — and can be
  correlated with the LUT delta after. Metrics are logged via `Logger` at
  `:info` and also returned by `run_with_stats/2`.
  """

  require Logger

  alias Hw.IR.Design

  alias Hw.Optimize.Passes.{ConstFold, DeadCodeElim, CSE, MuxFlatten}

  # Ordered pipeline. ConstFold canonicalises shapes that feed CSE/MuxFlatten;
  # DCE runs after each structural pass to sweep orphaned intermediates.
  # In Pass 1 only CSE is implemented; the others are inert stubs.
  @default_passes [ConstFold, DeadCodeElim, CSE, MuxFlatten, DeadCodeElim]

  @max_fixpoint_iterations 20

  @type metrics :: %{
          pass: atom(),
          ops_before: non_neg_integer(),
          ops_after: non_neg_integer(),
          signals_removed: integer()
        }

  @doc """
  Optimize a design. Returns the (possibly) transformed `%Design{}`.

  A no-op unless `opts[:optimize]` is truthy.
  """
  @spec run(Design.t(), keyword()) :: Design.t()
  def run(%Design{} = design, opts \\ []) do
    {design, _stats} = run_with_stats(design, opts)
    design
  end

  @doc """
  Like `run/2` but also returns the per-pass metrics list (in execution order,
  across all fixpoint iterations).
  """
  @spec run_with_stats(Design.t(), keyword()) :: {Design.t(), [metrics()]}
  def run_with_stats(%Design{} = design, opts \\ []) do
    if Keyword.get(opts, :optimize) do
      passes = select_passes(opts)
      fixpoint(design, passes, opts, [], 0)
    else
      {design, []}
    end
  end

  # Resolve the pass list against opts[:only] / opts[:skip], matched by name/0.
  defp select_passes(opts) do
    only = normalize_names(Keyword.get(opts, :only))
    skip = normalize_names(Keyword.get(opts, :skip)) || []

    @default_passes
    |> Enum.filter(fn pass ->
      n = pass.name()
      (is_nil(only) or n in only) and n not in skip
    end)
  end

  defp normalize_names(nil), do: nil
  defp normalize_names(list) when is_list(list), do: Enum.map(list, &to_atom_name/1)
  defp normalize_names(one), do: [to_atom_name(one)]

  defp to_atom_name(a) when is_atom(a), do: a
  defp to_atom_name(s) when is_binary(s), do: String.to_atom(s)

  # Run the whole pass list once, then re-run until op count stops changing.
  defp fixpoint(design, passes, opts, stats_acc, iter) do
    before_count = length(design.ops)
    {design, iter_stats} = run_once(design, passes, opts)
    after_count = length(design.ops)
    stats_acc = stats_acc ++ iter_stats

    cond do
      after_count == before_count ->
        {design, stats_acc}

      iter + 1 >= @max_fixpoint_iterations ->
        Logger.warning(
          "Hw.Optimize: fixpoint not reached after #{@max_fixpoint_iterations} " <>
            "iterations (#{before_count} -> #{after_count} ops); stopping."
        )

        {design, stats_acc}

      true ->
        fixpoint(design, passes, opts, stats_acc, iter + 1)
    end
  end

  defp run_once(design, passes, opts) do
    Enum.reduce(passes, {design, []}, fn pass, {d, stats} ->
      ops_before = length(d.ops)
      sigs_before = length(d.signals)

      d2 = pass.run(d, opts)

      ops_after = length(d2.ops)
      sigs_after = length(d2.signals)

      m = %{
        pass: pass.name(),
        ops_before: ops_before,
        ops_after: ops_after,
        signals_removed: sigs_before - sigs_after
      }

      if ops_before != ops_after or m.signals_removed != 0 do
        Logger.info(
          "Hw.Optimize[#{m.pass}]: ops #{ops_before} -> #{ops_after} " <>
            "(#{ops_after - ops_before}), signals removed: #{m.signals_removed}"
        )
      end

      {d2, stats ++ [m]}
    end)
  end
end
