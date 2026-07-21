defmodule DefhwTest do
  use ExUnit.Case

  # ---------------------------------------------------------------------------
  # Expression-level defhw
  # ---------------------------------------------------------------------------

  defmodule ExprLevel do
    use Hw.Component
    clock :clk, freq: 1.0
    input  :rst, 1
    input  :a,   8
    input  :b,   8
    output :out, 1

    defhw either_zero?(x) do
      x == 0
    end

    defhw both_nonzero?(x, y) do
      bnot(x == 0) and bnot(y == 0)
    end

    on :clk do
      if rst do
        out = 0
      else
        out = (either_zero?(a) or both_nonzero?(a, b))
      end
    end
  end

  test "expression-level: elaborates to valid IR" do
    design = Hw.Compile.Elaborate.elaborate(ExprLevel)
    assert length(design.ops) > 0
    assert {:ok, _} = Hw.Compile.Validate.validate(design)
  end

  test "expression-level: emits Verilog" do
    design = Hw.Compile.Elaborate.elaborate(ExprLevel)
    verilog = Hw.emit(design)
    assert String.contains?(verilog, "module")
    assert String.contains?(verilog, "out")
  end

  test "expression-level: either_zero? fires when a=0" do
    {:ok, sim} = Hw.Sim.start(ExprLevel)
    Hw.Sim.set(sim, :rst, 0)
    Hw.Sim.set(sim, :a,   0)
    Hw.Sim.set(sim, :b,   5)
    Hw.Sim.tick(sim, :clk, 1)
    assert Hw.Sim.get(sim, :out) == 1
  end

  test "expression-level: both_nonzero? fires when a!=0 and b!=0" do
    {:ok, sim} = Hw.Sim.start(ExprLevel)
    Hw.Sim.set(sim, :rst, 0)
    Hw.Sim.set(sim, :a,   3)
    Hw.Sim.set(sim, :b,   7)
    Hw.Sim.tick(sim, :clk, 1)
    assert Hw.Sim.get(sim, :out) == 1
  end

  test "expression-level: out=0 when a!=0 and b=0" do
    {:ok, sim} = Hw.Sim.start(ExprLevel)
    Hw.Sim.set(sim, :rst, 0)
    Hw.Sim.set(sim, :a,   3)
    Hw.Sim.set(sim, :b,   0)
    Hw.Sim.tick(sim, :clk, 1)
    assert Hw.Sim.get(sim, :out) == 0
  end

  # ---------------------------------------------------------------------------
  # Statement-level defhw
  # ---------------------------------------------------------------------------

  defmodule StmtLevel do
    use Hw.Component
    clock :clk, freq: 1.0
    input  :rst, 1
    input  :sel, 2
    output :x,   8
    output :y,   8

    defhw load_both(xval, yval) do
      x = xval
      y = yval
    end

    defhw clear_both() do
      x = 0
      y = 0
    end

    on :clk do
      if rst do
        clear_both()
      else
        if sel == 1 do
          load_both(42, 99)
        end
        if sel == 2 do
          load_both(7, 13)
        end
      end
    end
  end

  test "statement-level: elaborates to valid IR" do
    design = Hw.Compile.Elaborate.elaborate(StmtLevel)
    assert length(design.ops) > 0
    assert {:ok, _} = Hw.Compile.Validate.validate(design)
  end

  test "statement-level: load_both(42, 99) when sel=1" do
    {:ok, sim} = Hw.Sim.start(StmtLevel)
    Hw.Sim.set(sim, :rst, 1)
    Hw.Sim.tick(sim, :clk, 1)
    Hw.Sim.set(sim, :rst, 0)
    Hw.Sim.set(sim, :sel, 1)
    Hw.Sim.tick(sim, :clk, 1)
    assert Hw.Sim.get(sim, :x) == 42
    assert Hw.Sim.get(sim, :y) == 99
  end

  test "statement-level: load_both(7, 13) when sel=2" do
    {:ok, sim} = Hw.Sim.start(StmtLevel)
    Hw.Sim.set(sim, :rst, 1)
    Hw.Sim.tick(sim, :clk, 1)
    Hw.Sim.set(sim, :rst, 0)
    Hw.Sim.set(sim, :sel, 2)
    Hw.Sim.tick(sim, :clk, 1)
    assert Hw.Sim.get(sim, :x) == 7
    assert Hw.Sim.get(sim, :y) == 13
  end

  test "statement-level: clear_both() on rst" do
    {:ok, sim} = Hw.Sim.start(StmtLevel)
    Hw.Sim.set(sim, :rst, 0)
    Hw.Sim.set(sim, :sel, 1)
    Hw.Sim.tick(sim, :clk, 1)
    Hw.Sim.set(sim, :rst, 1)
    Hw.Sim.tick(sim, :clk, 1)
    assert Hw.Sim.get(sim, :x) == 0
    assert Hw.Sim.get(sim, :y) == 0
  end

  # ---------------------------------------------------------------------------
  # defhw containing hdl_case
  # ---------------------------------------------------------------------------

  defmodule WithCase do
    use Hw.Component
    clock :clk, freq: 1.0
    input  :rst, 1
    input  :cmd, 2
    output :out, 8

    defhw dispatch(c) do
      hdl_case c do
        0 -> out = 0xAA
        1 -> out = 0xBB
        2 -> out = 0xCC
        _ -> out = 0xFF
      end
    end

    on :clk do
      if rst do
        out = 0
      else
        dispatch(cmd)
      end
    end
  end

  test "with hdl_case: elaborates without error" do
    design = Hw.Compile.Elaborate.elaborate(WithCase)
    assert length(design.ops) > 0
    assert {:ok, _} = Hw.Compile.Validate.validate(design)
  end

  test "with hdl_case: cmd=0 → 0xAA" do
    {:ok, sim} = Hw.Sim.start(WithCase)
    Hw.Sim.set(sim, :rst, 0)
    Hw.Sim.set(sim, :cmd, 0)
    Hw.Sim.tick(sim, :clk, 1)
    assert Hw.Sim.get(sim, :out) == 0xAA
  end

  test "with hdl_case: cmd=2 → 0xCC" do
    {:ok, sim} = Hw.Sim.start(WithCase)
    Hw.Sim.set(sim, :rst, 0)
    Hw.Sim.set(sim, :cmd, 2)
    Hw.Sim.tick(sim, :clk, 1)
    assert Hw.Sim.get(sim, :out) == 0xCC
  end

  test "with hdl_case: default arm → 0xFF" do
    {:ok, sim} = Hw.Sim.start(WithCase)
    Hw.Sim.set(sim, :rst, 0)
    Hw.Sim.set(sim, :cmd, 3)
    Hw.Sim.tick(sim, :clk, 1)
    assert Hw.Sim.get(sim, :out) == 0xFF
  end

  # ---------------------------------------------------------------------------
  # Error cases
  # ---------------------------------------------------------------------------

  test "unknown defhw raises ElabError" do
    assert_raise Hw.Compile.Elaborate.ElabError, ~r/Unknown defhw: nonexistent/, fn ->
      defmodule BadCall do
        use Hw.Component
        clock :clk, freq: 1.0
        input  :rst, 1
        output :out, 1
        on :clk do
          if rst do; out = 0; else; nonexistent(out); end
        end
      end
      Hw.Compile.Elaborate.elaborate(BadCall)
    end
  end

  test "wrong arity raises ElabError" do
    assert_raise Hw.Compile.Elaborate.ElabError, ~r/called with 2 argument/, fn ->
      defmodule WrongArity do
        use Hw.Component
        clock :clk, freq: 1.0
        input  :rst, 1
        input  :a,   8
        input  :b,   8
        output :out, 1

        defhw one_arg(x) do
          x == 0
        end

        on :clk do
          if rst do; out = 0; else; out = one_arg(a, b); end
        end
      end
      Hw.Compile.Elaborate.elaborate(WrongArity)
    end
  end
end
