defmodule Hw.GenerateTest do
  use ExUnit.Case, async: true

  defmodule Families do
    use Hw.Component
    clock :clk, freq: 50.0
    input :rst, 1
    input :sel, 2

    generate k <- 0..3 do
      wire :"st#{k}", 5, init: 0
      wire :"pc_h#{k}", 1, init: 0
    end

    on :clk do
      if rst == 1 do
        generate k <- 0..3 do
          st[[k]] = 0
        end
      else
        generate k <- 0..3 do
          if sel == k do
            st[[k]] = st[[k]] + k
            pc_h[[rem(k + 1, 4)]] = 1
          end
        end
      end
    end
  end

  defmodule Combinational do
    use Hw.Component
    input :a, 8
    output :y, 8

    generate i <- 0..7 do
      y[i] = a[7 - i]
    end
  end

  defp names(mod), do: mod.__hw_signals__() |> Enum.map(& &1.name)

  test "module-level generate declares one wire per index, names folded" do
    ns = names(Families)
    for k <- 0..3, do: assert(:"st#{k}" in ns and :"pc_h#{k}" in ns)
  end

  test "statement-level generate unrolls in place, families resolved" do
    [%{type: :sequential, body: [top]}] = Families.__hw_logic__()
    assert top.type == :if
    assert Enum.map(top.then_body, & &1.target) == [:st0, :st1, :st2, :st3]

    arms = top.else_body
    assert length(arms) == 4
    # seat 2's arm writes st2 and pc_h3 (rem(2 + 1, 4))
    arm = Enum.at(arms, 2)
    assert Enum.map(arm.then_body, & &1.target) == [:st2, :pc_h3]
    refute inspect(Families.__hw_logic__()) =~ "unknown"
  end

  test "a single bracket stays a bit select of the loop index" do
    [%{type: :combinational, body: body}] = Combinational.__hw_logic__()
    assert length(body) == 8
    refute inspect(body) =~ "unknown"
  end

  test "range must be a compile-time literal" do
    assert_raise ArgumentError, ~r/range literal/, fn ->
      Hw.DSL.Generate.range_values(quote(do: n))
    end
  end

  test "family index must fold to an integer" do
    assert_raise ArgumentError, ~r/family index/, fn ->
      Hw.DSL.Generate.unroll(:k, quote(do: 0..1), quote(do: st[[k + other]] = 1))
    end
  end

  test "mixing declarations and bare statements is refused" do
    assert_raise ArgumentError, ~r/mixes declarations/, fn ->
      Code.compile_string("""
      defmodule Hw.GenerateTest.Mixed do
        use Hw.Component
        input :a, 1
        generate k <- 0..1 do
          wire :"m\#{k}", 1
          m0 = a
        end
      end
      """)
    end
  end
end
