defmodule Hw.Analysis.Rules.PolarityMismatch do
  @moduledoc """
  Detects signals with mismatched sense (active polarity) being connected
  directly or used in boolean contexts without explicit inversion.

  ## What this catches

  Active-low signals (sense: :low) used as-is in boolean conditions, or
  directly assigned to active-high signals, are almost always bugs:

      wire :btn_pwr_n, 1, sense: :low   # active low — pressed = 0

      # Bug: treating active-low as active-high
      if btn_pwr_n do   # fires when button is NOT pressed
        ...
      end

      # Bug: connecting opposite senses directly
      wire :rst, 1, sense: :high
      comb do
        rst = btn_pwr_n   # polarity inversion — rst is high when button released
      end

  ## What is allowed

  Explicit inversion via `bnot()` acknowledges the polarity crossing:

      comb do
        rst = bnot(btn_pwr_n)   # correct — rst high when button pressed (btn_pwr_n = 0)
      end

  ## Priority
  """

  @behaviour Hw.Analysis.Rule

  @dialyzer {:nowarn_function, check_op: 2}

  alias Hw.Analysis.Diagnostic
  alias Hw.IR.Ops

  @impl true
  def priority, do: 25

  @impl true
  def run(design) do
    signal_map = Map.new(design.signals, &{&1.name, &1})

    design.ops
    |> Enum.flat_map(&check_op(&1, signal_map))
  end

  # Check Assign ops — direct wire connections
  defp check_op(%Ops.Assign{output: out_sig, input: in_sig}, signal_map) do
    out = Map.get(signal_map, out_sig.name, out_sig)
    inp = Map.get(signal_map, in_sig.name, in_sig)

    out_sense = Map.get(out, :sense, :high)
    inp_sense = Map.get(inp, :sense, :high)

    if out_sense != inp_sense and inp_sense != nil and out_sense != nil do
      [Diagnostic.warning(
        :polarity_mismatch,
        "Signal `#{inp.name}` (sense: #{inp_sense}) assigned directly to " <>
        "`#{out.name}` (sense: #{out_sense}) — polarity mismatch, use bnot() if intentional",
        Map.get(inp, :source_location),
        context: %{signal: inp.name, target: out.name,
                   input_sense: inp_sense, output_sense: out_sense}
      )]
    else
      []
    end
  end

  defp check_op(_, _), do: []
end
