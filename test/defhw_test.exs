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
  # Nested defhw — a defhw whose body calls other defhws
  #
  # This is the shape that shipped broken hardware. `commit_write/0` in
  # Hw.AXI4Lite.Slave dispatched a register write through an hdl_case whose
  # arms called `merge_scratch/0` and `merge_ctrl/0`. Substituting the outer
  # template returned its body verbatim, so those inner calls survived as
  # :defhw_call nodes that nothing downstream matches. The registers were
  # declared, initialised and read, but never assigned: the design elaborated,
  # validated, synthesised, placed, routed, and silently dropped every write on
  # a real Zynq.
  #
  # The Verilog assertions below are the ones that actually catch it. A
  # simulation check alone is weaker than it looks -- assert the emitted module
  # contains a nonblocking assignment to the register, because "declared but
  # never driven" is precisely the failure.
  # ---------------------------------------------------------------------------

  defmodule NestedInCase do
    use Hw.Component
    clock :clk, freq: 1.0
    input  :rst,  1
    input  :sel,  2
    input  :din,  8
    output :sc,   8
    output :ct,   8

    defhw merge_sc() do
      sc = din
    end

    defhw merge_ct() do
      ct = din
    end

    defhw dispatch() do
      hdl_case <<sel::2>> do
        <<1::2>> -> merge_sc()
        <<2::2>> -> merge_ct()
      end
    end

    on :clk do
      if rst do
        sc = 0
        ct = 0
      else
        dispatch()
      end
    end
  end

  test "nested in hdl_case: both registers are actually driven in the Verilog" do
    verilog =
      NestedInCase
      |> Hw.Compile.Elaborate.elaborate()
      |> Hw.emit()

    assert verilog =~ ~r/\bsc\s*<=/, "sc is declared but never assigned"
    assert verilog =~ ~r/\bct\s*<=/, "ct is declared but never assigned"
  end

  test "nested in hdl_case: sel=1 writes sc only" do
    {:ok, sim} = Hw.Sim.start(NestedInCase)
    Hw.Sim.set(sim, :rst, 1)
    Hw.Sim.tick(sim, :clk, 1)
    Hw.Sim.set(sim, :rst, 0)
    Hw.Sim.set(sim, :din, 0xA5)
    Hw.Sim.set(sim, :sel, 1)
    Hw.Sim.tick(sim, :clk, 1)
    assert Hw.Sim.get(sim, :sc) == 0xA5
    assert Hw.Sim.get(sim, :ct) == 0
  end

  test "nested in hdl_case: sel=2 writes ct only" do
    {:ok, sim} = Hw.Sim.start(NestedInCase)
    Hw.Sim.set(sim, :rst, 1)
    Hw.Sim.tick(sim, :clk, 1)
    Hw.Sim.set(sim, :rst, 0)
    Hw.Sim.set(sim, :din, 0x5A)
    Hw.Sim.set(sim, :sel, 2)
    Hw.Sim.tick(sim, :clk, 1)
    assert Hw.Sim.get(sim, :ct) == 0x5A
    assert Hw.Sim.get(sim, :sc) == 0
  end

  test "nested in hdl_case: unmatched selector leaves both alone" do
    {:ok, sim} = Hw.Sim.start(NestedInCase)
    Hw.Sim.set(sim, :rst, 1)
    Hw.Sim.tick(sim, :clk, 1)
    Hw.Sim.set(sim, :rst, 0)
    Hw.Sim.set(sim, :din, 0xFF)
    Hw.Sim.set(sim, :sel, 3)
    Hw.Sim.tick(sim, :clk, 1)
    assert Hw.Sim.get(sim, :sc) == 0
    assert Hw.Sim.get(sim, :ct) == 0
  end

  defmodule NestedWithArgs do
    use Hw.Component
    clock :clk, freq: 1.0
    input  :rst, 1
    input  :a,   8
    output :out, 8

    # Arguments must thread through the nesting: `scale/1` is called with a
    # parameter of the ENCLOSING template, which is only bound during the
    # outer substitution.
    defhw twice(v) do
      v + v
    end

    defhw quad(v) do
      out = twice(twice(v))
    end

    on :clk do
      if rst do
        out = 0
      else
        quad(a)
      end
    end
  end

  test "nested with args: parameters thread through both levels" do
    {:ok, sim} = Hw.Sim.start(NestedWithArgs)
    Hw.Sim.set(sim, :rst, 1)
    Hw.Sim.tick(sim, :clk, 1)
    Hw.Sim.set(sim, :rst, 0)
    Hw.Sim.set(sim, :a, 3)
    Hw.Sim.tick(sim, :clk, 1)
    assert Hw.Sim.get(sim, :out) == 12
  end

  defmodule NestedThreeDeep do
    use Hw.Component
    clock :clk, freq: 1.0
    input  :rst, 1
    input  :a,   8
    output :out, 8

    defhw inner(v),  do: v + 1
    defhw middle(v), do: inner(v) + 1
    defhw outer(v),  do: middle(v) + 1

    on :clk do
      if rst do
        out = 0
      else
        out = outer(a)
      end
    end
  end

  test "nested three deep: inlining runs to a fixpoint, not one level" do
    {:ok, sim} = Hw.Sim.start(NestedThreeDeep)
    Hw.Sim.set(sim, :rst, 1)
    Hw.Sim.tick(sim, :clk, 1)
    Hw.Sim.set(sim, :rst, 0)
    Hw.Sim.set(sim, :a, 10)
    Hw.Sim.tick(sim, :clk, 1)
    assert Hw.Sim.get(sim, :out) == 13
  end

  # ---------------------------------------------------------------------------
  # Error cases
  # ---------------------------------------------------------------------------

  test "self-recursive defhw raises rather than hanging" do
    assert_raise Hw.Compile.Elaborate.ElabError, ~r/Recursive defhw/, fn ->
      defmodule SelfRecursive do
        use Hw.Component
        clock :clk, freq: 1.0
        input  :rst, 1
        input  :a,   8
        output :out, 8

        defhw loop(v) do
          out = loop(v)
        end

        on :clk do
          if rst do; out = 0; else; loop(a); end
        end
      end
      Hw.Compile.Elaborate.elaborate(SelfRecursive)
    end
  end

  test "mutually recursive defhws raise rather than hanging" do
    assert_raise Hw.Compile.Elaborate.ElabError, ~r/Recursive defhw/, fn ->
      defmodule MutuallyRecursive do
        use Hw.Component
        clock :clk, freq: 1.0
        input  :rst, 1
        input  :a,   8
        output :out, 8

        defhw ping(v) do
          pong(v)
        end

        defhw pong(v) do
          ping(v)
        end

        on :clk do
          if rst do; out = 0; else; ping(a); end
        end
      end
      Hw.Compile.Elaborate.elaborate(MutuallyRecursive)
    end
  end

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
