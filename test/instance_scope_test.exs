defmodule InstanceScopeTest do
  @moduledoc """
  A component's own signals must not be shadowed by an instance's internal
  signals of the same name.

  Elaboration flattens the hierarchy and, while doing so, knows each child's
  signals by their unprefixed names. If that child-keyed map is handed back to
  the enclosing scope, a parent signal whose name collides resolves to the
  child's wire instead of its own — silently, whenever the parent's wire is
  driven by some *other* instance's output port.
  """

  use ExUnit.Case

  alias Hw.Analysis.Rules.InstanceNameShadow

  defmodule Producer do
    use Hw.Component

    clock :clk, freq: 1.0
    input :rst, 1
    output :out8, 8

    wire :ctr, 8, init: 0

    comb do
      out8 = ctr
    end

    on :clk do
      if rst do
        ctr = 0
      else
        ctr = ctr + 1
      end
    end
  end

  defmodule Bystander do
    use Hw.Component

    clock :clk, freq: 1.0
    input :rst, 1
    output :flag, 1

    # Internal signal whose name collides with a wire in the parent below.
    wire :shared, 8, init: 0xAA
    wire :flag_r, 1, init: 0

    comb do
      flag = flag_r
    end

    on :clk do
      if rst do
        shared = 0xAA
        flag_r = 0
      else
        shared = 0xAA
        flag_r = 1
      end
    end
  end

  defmodule Shadowed do
    use Hw.Component

    clock :clk, freq: 1.0
    input :rst, 1
    output :z, 8
    output :f, 1

    # Driven by instance :a's output port, read by this component.
    wire :shared, 8

    comb do
      z = shared
    end

    instance :a, InstanceScopeTest.Producer, clk: :clk, rst: :rst, out8: :shared
    instance :b, InstanceScopeTest.Bystander, clk: :clk, rst: :rst, flag: :f
  end

  test "a parent signal is not shadowed by an unrelated instance's internal signal" do
    verilog = Shadowed |> Hw.Compile.Elaborate.elaborate() |> Hw.emit()

    assignment =
      verilog
      |> String.split("\n")
      |> Enum.find(&String.match?(&1, ~r/assign z\b/))

    assert assignment, "no assignment to z was emitted"

    refute assignment =~ "b_shared",
           "the parent's `shared` resolved to instance :b's internal signal"

    assert assignment =~ ~r/assign z = shared;/,
           "expected z to read the parent's own `shared`, got: #{assignment}"
  end

  test "both wires survive independently in the flattened design" do
    design = Hw.Compile.Elaborate.elaborate(Shadowed)
    names = MapSet.new(design.signals, & &1.name)

    assert MapSet.member?(names, :shared), "the parent's own wire vanished"
    assert MapSet.member?(names, :b_shared), "the child's wire vanished"
  end

  test "the shadow is reported to the user as a warning" do
    diagnostics =
      InstanceNameShadow.run(%{
        components: [
          %{
            module: Shadowed,
            signals: Shadowed.__hw_signals__(),
            instances: Shadowed.__hw_instances__()
          },
          %{
            module: Bystander,
            signals: Bystander.__hw_signals__(),
            instances: []
          },
          %{
            module: Producer,
            signals: Producer.__hw_signals__(),
            instances: []
          }
        ]
      })

    assert [diag] = Enum.filter(diagnostics, &(&1.context.signal == :shared))
    assert diag.severity == :warning
    assert diag.code == :instance_name_shadow
    assert diag.context.instance == :b
    assert diag.context.resolved_to == :b_shared
    assert diag.message =~ "shared"
  end

  test "a connected port is not reported as a shadow" do
    # :a maps out8 -> :shared, and both modules have a `clk`/`rst`. Those are
    # ordinary connections, not shadows, so they must not be flagged.
    diagnostics =
      InstanceNameShadow.run(%{
        components: [
          %{
            module: Shadowed,
            signals: Shadowed.__hw_signals__(),
            instances: Shadowed.__hw_instances__()
          },
          %{module: Producer, signals: Producer.__hw_signals__(), instances: []}
        ]
      })

    flagged = Enum.map(diagnostics, & &1.context.signal)

    refute :clk in flagged
    refute :rst in flagged
    refute :out8 in flagged
  end
end
