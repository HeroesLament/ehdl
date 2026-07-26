defmodule Hw.Analysis.Rules.RegisterAliasInComb do
  @moduledoc """
  Detects a combinational assignment whose right-hand side is *directly* a
  registered signal — i.e. `some_comb_wire = some_register` inside a `comb do`
  block (elaborated to an `Ops.Assign` whose input is a `Reg` output).

  ## Why this is a bug

  The simulation scheduler and the topological sort that orders combinational
  evaluation rely on a load-bearing invariant: **register outputs are opaque
  sources.** Reading a register during combinational evaluation returns its
  currently-latched value, so a register's output is deliberately excluded from
  the combinational dependency graph — this is what lets legitimate synchronous
  "loops" (a register feeding logic that feeds back into the register's own
  next-value) exist without being flagged as combinational cycles.

  A bare comb assignment `w = r` (r a register) smuggles the register's value
  into the combinational graph under a *new* name `w`. Any downstream logic that
  reads `w` now transitively depends on `r`'s combinational fan-in — and if that
  fan-in loops back through `w`, the scheduler sees a combinational cycle that
  does not actually exist in hardware. The failure surfaces far from the cause,
  as a giant "combinational loop detected" spanning dozens of anonymous
  intermediate signals, giving no hint that a single innocent-looking diagnostic
  passthrough was the trigger.

  This is the same class of defect as emitting `32'd0[6:0]`: a construct the
  language accepts and that behaves fine in isolation, but which violates a
  backend invariant and explodes downstream. It belongs in the rule layer so the
  user is told, at the exact source line, what went wrong and how to fix it.

  ## What is checked

  For every component, collect the set of `Ops.Reg` output signal names. Then
  flag any `Ops.Assign` (a combinational continuous assignment) whose `input` is
  a `Signal` whose name is in that set — a direct register-to-comb alias.

  Signals whose names start with `_` (compiler-generated intermediates) are not
  reported as the *target*, since those come from nested expressions the user did
  not write directly; the user-authored `w = r` always names a real `w`.

  ## The fix

  If you need a register's value on a combinational output (e.g. a diagnostic
  probe), take a **registered snapshot** in a clocked block instead of aliasing:

      # WRONG — comb alias of a register, breaks reg-opaqueness:
      comb do
        dbg_out = some_reg
      end

      # RIGHT — registered snapshot (1-cycle delayed, opaque, no false loop):
      on :clk do
        dbg_out = some_reg
      end

  If the downstream logic genuinely needs the register's *current* value, read
  the register directly at the point of use rather than aliasing it to a new
  combinational wire.

  ## Priority

  Runs at priority 60 — before `CombinationalLoop` (62), so the specific,
  actionable cause is reported ahead of the generic loop symptom it would
  otherwise produce.
  """

  @behaviour Hw.Analysis.Rule

  alias Hw.Analysis.{Diagnostic, Location}
  alias Hw.IR.Ops.{Assign, Reg}
  alias Hw.IR.Types.Signal

  @impl Hw.Analysis.Rule
  def priority, do: 60

  @impl Hw.Analysis.Rule
  def run(%{components: components}) do
    Enum.flat_map(components, fn comp ->
      case safe_design(comp.module) do
        nil    -> []
        design -> check_design(design, comp.module, comp.instances)
      end
    end)
  end

  defp check_design(design, module, instances) do
    # Names belonging to a flattened child instance. A component's own design
    # contains its children inlined, so without this every child's assignments
    # are re-reported once per ancestor — and the child is analysed on its own
    # anyway, where the diagnostic (if real) belongs.
    child_prefixes = Enum.map(instances, fn inst -> "#{inst.name}_" end)

    reg_outputs =
      design.ops
      |> Enum.filter(&match?(%Reg{}, &1))
      |> Enum.flat_map(fn %Reg{output: out} ->
        case out do
          %Signal{name: n} -> [n]
          _ -> []
        end
      end)
      |> MapSet.new()

    design.ops
    |> Enum.filter(&reg_alias?(&1, reg_outputs))
    |> Enum.reject(&from_child?(&1, child_prefixes))
    |> Enum.reject(&exposes_on_port?/1)
    |> Enum.map(fn %Assign{output: out, input: %Signal{name: src}} ->
      loc = location_of(out, module)

      Diagnostic.error(
        :combinational_loop,
        "combinational assignment `#{out.name} = #{src}` aliases registered " <>
          "signal `#{src}` into combinational logic, which breaks " <>
          "register-opaqueness and can surface as a false combinational loop",
        loc,
        context: %{target: out.name, register: src, module: module},
        related: [
          %{
            location: loc,
            message:
              "take a registered snapshot in a clocked block instead: " <>
                "`on :clk do #{out.name} = #{src} end` (1-cycle delayed, opaque), " <>
                "or read `#{src}` directly at the point of use"
          }
        ]
      )
    end)
  end

  # A comb Assign aliasing a register: input is a Signal whose name is a Reg
  # output, and the target is a user-named wire (not a `_`-prefixed intermediate).
  defp reg_alias?(%Assign{output: %Signal{name: out_name}, input: %Signal{name: src}}, reg_outputs) do
    MapSet.member?(reg_outputs, src) and not compiler_generated?(out_name)
  end

  defp reg_alias?(_, _), do: false

  # An assignment that came from a flattened child instance.
  defp from_child?(%Assign{output: %Signal{name: name}}, prefixes) do
    str = Atom.to_string(name)
    Enum.any?(prefixes, &String.starts_with?(str, &1))
  end

  defp from_child?(_, _), do: false

  # `comb do out = some_reg end` where `out` is an output port is how every
  # component exposes a registered value at its boundary. A port is the module
  # edge, not combinational logic that could close a loop, so this is the
  # idiom rather than a smell.
  defp exposes_on_port?(%Assign{output: %Signal{direction: :output}}), do: true
  defp exposes_on_port?(_), do: false

  defp compiler_generated?(name) do
    name |> Atom.to_string() |> String.starts_with?("_")
  end

  defp location_of(%Signal{source_location: %Location{} = loc}, _module), do: loc
  defp location_of(_out, module), do: %Location{file: "unknown", line: 0, module: module}

  defp safe_design(module) do
    try do
      if (Code.ensure_loaded?(module) and function_exported?(module, :__hw_design__, 0)), do: module.__hw_design__()
    rescue
      _ -> nil
    end
  end
end
