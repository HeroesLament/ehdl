defmodule Hw.Analysis.Rules.LatchInference do
  @moduledoc """
  Detects combinational outputs that are not assigned on every path through
  a `comb do` block, which would cause a synthesis tool to infer a latch.

  ## Background

  In synchronous RTL design, latches are almost never intentional. They
  arise when a `comb do` block assigns a signal in one branch of an `if`
  but not in another, and the synthesizer must "hold" the value —
  creating a level-sensitive latch rather than a flip-flop.

  EHDL emits `assign` statements for `comb do` blocks. A latch is
  inferred when the elaborated IR produces a `Mux` op whose `default`
  arm feeds back the output signal itself — i.e. the mux holds its
  current value when no condition is true.

  ## What is checked

  For every `Ops.Mux` in the design whose `default` value is the same
  signal as the `output`, the mux is self-referential in its default
  arm. In combinational logic this means "hold the current value" —
  which is a latch.

  This is structurally distinct from a register (which has an explicit
  `Ops.Reg` with a clock). A combinational mux that holds itself is
  always a latch.

  ## Example diagnostic

      error[E070]: combinational signal `:ep0_state` holds its value when
                   no condition is matched — this infers a latch
        │
        │ Hw.USB.CDCSerial
        │
        │   comb do
        │     if some_condition do
        │       ep0_state = next_state   ← only assigned in one branch
        │     end                        ← no else: latch inferred
        │   end
        │
        └─ hint: add a default assignment before the conditional:
                 `ep0_state = current_ep0_state` or use a register (`on :clk do`)

  ## Priority

  Runs at priority 60 — after connectivity checks, operating on IR.
  """

  @behaviour Hw.Analysis.Rule

  @dialyzer {:nowarn_function, check_design: 2}

  alias Hw.Analysis.{Diagnostic, Location}
  alias Hw.IR.Ops.{Mux, Assign}
  alias Hw.IR.Types.Signal

  @impl Hw.Analysis.Rule
  def priority, do: 60

  @impl Hw.Analysis.Rule
  def run(%{components: components}) do
    Enum.flat_map(components, fn comp ->
      design = safe_design(comp.module)
      if design, do: check_design(design, comp.module), else: []
    end)
  end

  defp check_design(design, module) do
    # Build set of signals driven by Reg ops — these are intentional
    # self-references (hold value via register, not latch)
    reg_driven =
      design.ops
      |> Enum.filter(&match?(%Hw.IR.Ops.Reg{}, &1))
      |> MapSet.new(& &1.output.name)

    # Find Assign ops that drive a Mux whose default is self-referential
    assign_targets =
      design.ops
      |> Enum.filter(&match?(%Assign{}, &1))
      |> Map.new(fn %Assign{output: out, input: inp} -> {out.name, inp} end)

    Enum.flat_map(design.ops, fn
      %Mux{output: out, default: default} ->
        if latch_default?(default, out, assign_targets) and
           not MapSet.member?(reg_driven, out.name) do
          loc = signal_loc(out, design) || fallback(module)
          [Diagnostic.error(
            :latch_inference,
            "combinational signal `:#{out.name}` holds its value when no " <>
            "condition matches — latch will be inferred",
            loc,
            context: %{signal: out.name, module: module}
          )]
        else
          []
        end
      _ -> []
    end)
  end

  # The default is self-referential if it is the output signal itself,
  # or if it traces through an Assign chain back to the output signal.
  defp latch_default?(%Signal{name: name}, %Signal{name: name}, _), do: true
  defp latch_default?(%Signal{name: src}, %Signal{name: dst}, assign_targets) when src != dst do
    # Follow assign chain: is src ultimately driven by dst?
    case Map.get(assign_targets, src) do
      nil -> false
      inp -> latch_default?(inp, %Signal{name: dst, width: 1, signed: :unsigned, direction: :internal}, assign_targets)
    end
  end
  defp latch_default?(_, _, _), do: false

  defp signal_loc(signal, design) do
    Enum.find_value(design.signals, fn s ->
      if s.name == signal.name, do: s.source_location
    end)
  end

  defp safe_design(module) do
    try do
      if (Code.ensure_loaded?(module) and function_exported?(module, :__hw_design__, 0)), do: module.__hw_design__()
    rescue
      _ -> nil
    end
  end

  defp fallback(module),
    do: %Location{file: "unknown", line: 0, module: module}
end
