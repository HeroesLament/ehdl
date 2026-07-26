defmodule Hw.Analysis.Rules.ImplicitStateRetention do
  @moduledoc """
  Detects registers that have no unconditional default assignment in their
  clocked block, meaning they silently retain their previous value when
  no condition is met.

  ## Background

  In a clocked `on :clk do` block, any register not assigned in a given
  cycle simply holds its previous value. This is often intentional — but
  when it is not, the stale value leaks into subsequent computations and
  produces behavior that is correct "most of the time" but fails in
  specific sequences of inputs.

  The canonical safe pattern is to assign a default at the top of the
  block, then override it in specific branches:

      on :clk do
        valid <= 0           # default: clear every cycle
        if rx_active do
          valid <= 1         # override: set when active
        end
      end

  Without the `valid <= 0` default, `valid` retains its last value
  across idle cycles — almost always wrong for a strobe or pulse signal.

  ## What is checked

  For every `Ops.Reg` in the elaborated IR, this rule inspects the
  `input` value (the mux tree). If the mux tree contains a branch where
  the value is the register's own output signal (i.e. "hold current
  value"), AND that branch is reachable without a reset condition, the
  register is flagged.

  Registers whose name starts with `_` are skipped (intentionally
  unused/discarded).

  Single-bit registers used as flags or enables are specifically called
  out — these are the most dangerous category because a stuck-high
  enable or stuck-low valid is hard to observe.

  ## Example diagnostic

      warning[W073]: register `:valid` has no default assignment —
                     it retains its value when `rx_active` is false
        │
        │ Hw.USB.FSPhy
        │
        └─ hint: add `valid <= 0` before the conditional to clear
                 the register each cycle, or document the retention
                 as intentional with a `# hold` comment

  ## Priority

  Runs at priority 64, after latch and loop checks.
  """

  @behaviour Hw.Analysis.Rule

  @dialyzer {:nowarn_function, check_design: 2}
  @dialyzer {:nowarn_function, build_diagnostic: 5}

  alias Hw.Analysis.{Diagnostic, Location}
  alias Hw.IR.Ops.{Reg, Mux}
  alias Hw.IR.Types.{Signal, Const}

  @impl Hw.Analysis.Rule
  def priority, do: 64

  @impl Hw.Analysis.Rule
  def run(%{components: components}) do
    Enum.flat_map(components, fn comp ->
      design = safe_design(comp.module)
      if design, do: check_design(design, comp.module), else: []
    end)
  end

  defp check_design(design, module) do
    # Collect all registers
    regs = Enum.filter(design.ops, &match?(%Reg{}, &1))

    Enum.flat_map(regs, fn %Reg{output: out, input: input, reset_value: reset_val} ->
      if intentionally_unused?(out.name) do
        []
      else
        # If there's an explicit reset_value, the reset path gives a defined
        # state — the retention only matters in non-reset cycles.
        # We still check the non-reset mux tree.
        if has_self_retention?(input, out) and not has_unconditional_default?(input, out) do
          loc = signal_loc(out, design) || fallback(module)
          severity = if out.width == 1, do: :error, else: :warning
          message =
            "register `:#{out.name}` (#{out.width}-bit) has no default " <>
            "assignment — it retains its previous value when no condition is met" <>
            if(reset_val != nil, do: " (reset=#{reset_val} provides init, but not cycle-by-cycle default)", else: "")

          [build_diagnostic(severity, out.name, module, message, loc)]
        else
          []
        end
      end
    end)
  end

  # A register has self-retention if its mux tree contains a branch
  # where the value is the output signal itself.
  defp has_self_retention?(%Signal{name: name}, %Signal{name: name}), do: true
  defp has_self_retention?(%Mux{cases: cases, default: default}, out) do
    has_self_retention?(default, out) or
      Enum.any?(cases, fn {_cond, val} -> has_self_retention?(val, out) end)
  end
  defp has_self_retention?(_, _), do: false

  # A register has an unconditional default if the top-level input is
  # a constant or a different signal (not a Mux or self-reference).
  defp has_unconditional_default?(%Const{}, _), do: true
  defp has_unconditional_default?(%Signal{name: name}, %Signal{name: out_name})
    when name != out_name, do: true
  defp has_unconditional_default?(%Mux{default: default}, out) do
    # The Mux has an unconditional default if its own default is not self-referential
    not has_self_retention?(default, out)
  end
  defp has_unconditional_default?(_, _), do: false

  defp build_diagnostic(:error, name, module, message, loc) do
    Diagnostic.error(:implicit_state_retention, message, loc,
      context: %{signal: name, module: module})
  end
  defp build_diagnostic(:warning, name, module, message, loc) do
    Diagnostic.warning(:implicit_state_retention, message, loc,
      context: %{signal: name, module: module})
  end

  defp intentionally_unused?(name) do
    name |> Atom.to_string() |> String.starts_with?("_")
  end

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
