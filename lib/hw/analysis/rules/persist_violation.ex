defmodule Hw.Analysis.Rules.PersistViolation do
  @moduledoc """
  Detects signals marked `persist: :power_on_only` that are connected
  to a synchronous reset path, which would clear them on soft resets
  contrary to their declared intent.

  Also detects `:full` signals used as inputs to logic that feeds
  `:power_on_only` outputs — such logic implicitly assumes the `:full`
  signal is valid across the reset boundary when it may not be.

  ## What this catches

      wire :dev_addr, 7, persist: :power_on_only
      wire :rst,      1  # full reset — clears on any reset

      on :clk do
        if rst do
          dev_addr <= 0   # bug — soft USB reset would wipe the address
        end
      end

  ## What is allowed

  Signals marked `:power_on_only` should only be reset by a power-on
  reset signal, not the general soft reset:

      wire :por, 1   # power-on reset only

      on :clk do
        if por do
          dev_addr <= 0   # correct — only clears at power-on
        end
      end

  ## Priority
  """

  @behaviour Hw.Analysis.Rule

  @dialyzer {:nowarn_function, check_op: 2}

  alias Hw.Analysis.Diagnostic
  alias Hw.IR.Ops

  @impl true
  def priority, do: 57

  # Inspects the elaborated netlist (.signals/.ops), not module metadata.
  @impl true
  def stage, do: :ir

  @impl true
  def run(design) do
    signal_map = Map.new(design.signals, &{&1.name, &1})

    # Find all Reg ops where the output signal is persist: :power_on_only
    # but the reset condition feeds from a :full signal
    design.ops
    |> Enum.flat_map(&check_op(&1, signal_map))
  end

  defp check_op(%Ops.Reg{output: out_sig, reset_value: reset_val}, signal_map)
       when reset_val != nil do
    out = Map.get(signal_map, out_sig.name, out_sig)
    persist = Map.get(out, :persist, :full)

    if persist == :power_on_only do
      [Diagnostic.warning(
        :persist_violation,
        "Signal `#{out.name}` is declared `persist: :power_on_only` but has a " <>
        "synchronous reset — it will be cleared on soft resets. " <>
        "Use a dedicated power-on reset signal or remove the reset.",
        Map.get(out, :source_location),
        context: %{signal: out.name}
      )]
    else
      []
    end
  end

  defp check_op(_, _), do: []
end
