defmodule InstanceParamForwardTest do
  @moduledoc """
  Forwarding an enclosing module's parameter into a sub-instance.

  A bare uppercase name in an instance option parses as an Elixir alias, so
  `LIMIT: BUS_LIMIT` arrives at the elaborator as `:"Elixir.BUS_LIMIT"`. The
  elaborator demangles it and resolves it against the enclosing module's
  parameters — the same "uppercase means parameter" convention the `pipeline`
  macro uses for auto-balance.

  Forwarded values are observed two ways: through the emitted Verilog constant,
  and through the width of a child signal sized by the parameter.
  """

  use ExUnit.Case

  defp sig(design, name), do: Enum.find(design.signals, &(&1.name == name))

  defmodule Child do
    use Hw.Component

    param :LIMIT, default: 99
    param :LIMIT_W, default: 4

    clock :clk, freq: 1.0
    input :rst, 1
    input :d, 16
    output :hit, 1

    # Sized from the child's own parameter, in both notations the DSL supports.
    wire :acc, LIMIT_W
    wire :idx, clog2(LIMIT_W) + 1

    wire :hit_r, 1, init: 0

    comb do
      hit = hit_r
      acc = 0
      idx = 0
    end

    on :clk do
      if rst do
        hit_r = 0
      else
        hit_r = d == LIMIT
      end
    end
  end

  defmodule Parent do
    use Hw.Component

    param :BUS_LIMIT, default: 1234
    param :BUS_W, default: 21

    clock :clk, freq: 1.0
    input :rst, 1
    input :d, 16
    output :hit, 1

    instance :wide, InstanceParamForwardTest.Child,
      LIMIT: BUS_LIMIT,
      LIMIT_W: BUS_W,
      clk: :clk,
      rst: :rst,
      d: :d,
      hit: :hit
  end

  defmodule LiteralParent do
    use Hw.Component

    clock :clk, freq: 1.0
    input :rst, 1
    input :d, 16
    output :hit, 1

    instance :narrow, InstanceParamForwardTest.Child,
      LIMIT: 777,
      LIMIT_W: 13,
      clk: :clk,
      rst: :rst,
      d: :d,
      hit: :hit
  end

  defmodule Middle do
    use Hw.Component

    param :MID_LIMIT, default: 7

    clock :clk, freq: 1.0
    input :rst, 1
    input :d, 16
    output :hit, 1

    instance :leaf, InstanceParamForwardTest.Child,
      LIMIT: MID_LIMIT,
      clk: :clk,
      rst: :rst,
      d: :d,
      hit: :hit
  end

  defmodule Grandparent do
    use Hw.Component

    param :TOP_LIMIT, default: 4321

    clock :clk, freq: 1.0
    input :rst, 1
    input :d, 16
    output :hit, 1

    instance :mid, InstanceParamForwardTest.Middle,
      MID_LIMIT: TOP_LIMIT,
      clk: :clk,
      rst: :rst,
      d: :d,
      hit: :hit
  end

  defp verilog(mod), do: mod |> Hw.Compile.Elaborate.elaborate() |> Hw.emit()

  test "a bare uppercase name forwards the enclosing module's parameter" do
    v = verilog(Parent)

    assert v =~ ~r/'d1234\b/, "the parent's BUS_LIMIT did not reach the child"
    refute v =~ ~r/'d99\b/, "the child fell back to its own default"
  end

  test "integer literals still work exactly as before" do
    v = verilog(LiteralParent)

    assert v =~ ~r/'d777\b/
    refute v =~ ~r/'d99\b/
  end

  test "forwarding resolves through more than one level of hierarchy" do
    v = verilog(Grandparent)

    # TOP_LIMIT -> MID_LIMIT -> LIMIT, two hops down.
    assert v =~ ~r/'d4321\b/
    refute v =~ ~r/'d99\b/
    refute v =~ ~r/'d7\b/, "the middle module fell back to its own default"
  end

  test "a child signal sized by a forwarded parameter gets the right width" do
    design = Hw.Compile.Elaborate.elaborate(Parent)

    assert sig(design, :wide_acc).width == 21
    # clog2(21) + 1 = 5 + 1
    assert sig(design, :wide_idx).width == 6
  end

  test "a child signal sized by a literal parameter override gets the right width" do
    design = Hw.Compile.Elaborate.elaborate(LiteralParent)

    assert sig(design, :narrow_acc).width == 13
    # clog2(13) + 1 = 4 + 1
    assert sig(design, :narrow_idx).width == 5
  end

  test "an unforwarded child signal falls back to the child's own default width" do
    defmodule DefaultWidthParent do
      use Hw.Component

      clock :clk, freq: 1.0
      input :rst, 1
      input :d, 16
      output :hit, 1

      instance :dflt, InstanceParamForwardTest.Child,
        clk: :clk,
        rst: :rst,
        d: :d,
        hit: :hit
    end

    design = Hw.Compile.Elaborate.elaborate(DefaultWidthParent)
    assert sig(design, :dflt_acc).width == 4
  end

  test "an unforwarded instance still gets the child's default" do
    defmodule PlainParent do
      use Hw.Component

      clock :clk, freq: 1.0
      input :rst, 1
      input :d, 16
      output :hit, 1

      instance :plain, InstanceParamForwardTest.Child,
        clk: :clk,
        rst: :rst,
        d: :d,
        hit: :hit
    end

    assert verilog(PlainParent) =~ ~r/'d99\b/
  end

  test "forwarding a parameter the enclosing module does not declare is a clear error" do
    assert_raise Hw.Compile.Elaborate.ElabError, ~r/declares no parameter NOPE/, fn ->
      defmodule BadParent do
        use Hw.Component

        clock :clk, freq: 1.0
        input :rst, 1
        input :d, 16
        output :hit, 1

        instance :oops, InstanceParamForwardTest.Child,
          LIMIT: NOPE,
          clk: :clk,
          rst: :rst,
          d: :d,
          hit: :hit
      end

      Hw.Compile.Elaborate.elaborate(BadParent)
    end
  end
end
