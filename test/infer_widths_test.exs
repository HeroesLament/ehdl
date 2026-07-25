defmodule InferWidthsTest do
  use ExUnit.Case

  defp width_of(design, name) do
    case Enum.find(design.signals, &(&1.name == name)) do
      nil -> flunk("no signal named #{inspect(name)} in elaborated design")
      sig -> sig.width
    end
  end

  test ":infer wire takes the width of its driving expression" do
    defmodule Infer.Basic do
      use Hw.Component
      input :a, 8
      input :b, 8
      wire  :s_add, :infer
      wire  :s_cat, :infer
      wire  :s_cmp, :infer

      comb do
        s_add = a + b
        s_cat = {a, b}
        s_cmp = a > b
      end
    end

    design = Hw.Compile.Elaborate.elaborate(Infer.Basic)
    assert width_of(design, :s_add) == 8    # max(8, 8)
    assert width_of(design, :s_cat) == 16   # concat 8 ++ 8
    assert width_of(design, :s_cmp) == 1    # comparison
  end

  test ":infer resolves in dataflow order through a chain of infers" do
    defmodule Infer.Chain do
      use Hw.Component
      input :a, 8
      input :b, 8
      wire  :cat,   :infer   # {a,b} -> 16
      wire  :chain, :infer   # cat + a -> depends on cat

      comb do
        cat   = {a, b}
        chain = cat + a
      end
    end

    design = Hw.Compile.Elaborate.elaborate(Infer.Chain)
    assert width_of(design, :cat) == 16
    assert width_of(design, :chain) == 16   # max(16, 8)
  end

  test "a design with no :infer signals is untouched (zero-cost path)" do
    defmodule Infer.None do
      use Hw.Component
      input  :a, 8
      output :y, 8
      comb do
        y = a
      end
    end

    design = Hw.Compile.Elaborate.elaborate(Infer.None)
    assert width_of(design, :y) == 8
  end

  test "a cyclic :infer dependency is an error" do
    defmodule Infer.Cycle do
      use Hw.Component
      input :a, 8
      wire  :x, :infer
      wire  :y, :infer

      comb do
        x = y + a
        y = x + a
      end
    end

    assert_raise Hw.Compile.Elaborate.ElabError, ~r/cyclic/, fn ->
      Hw.Compile.Elaborate.elaborate(Infer.Cycle)
    end
  end

  test "an :infer signal with no driver is an error" do
    defmodule Infer.Orphan do
      use Hw.Component
      input :a, 8
      wire  :orphan, :infer
      output :y, 8

      comb do
        y = a
      end
    end

    assert_raise Hw.Compile.Elaborate.ElabError, ~r/no expression to size/, fn ->
      Hw.Compile.Elaborate.elaborate(Infer.Orphan)
    end
  end
end
