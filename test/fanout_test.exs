defmodule Hw.FanoutTest.Wide do
  use Hw.Component
  clock :clk, freq: 1.0, reset_style: :none
  input :go, 1
  input :a, 64
  input :b, 64
  output :y, 64
  output :z, 1
  wire :sel, 1, init: 0

  fanout :sel, 4

  comb do
    if sel do
      y = a
    else
      y = b
    end

    z = sel
  end

  on :clk do
    sel = go
  end
end

defmodule Hw.FanoutTest.Plain do
  use Hw.Component
  clock :clk, freq: 1.0, reset_style: :none
  input :go, 1
  input :a, 64
  input :b, 64
  output :y, 64
  output :z, 1
  wire :sel, 1, init: 0

  comb do
    if sel do
      y = a
    else
      y = b
    end

    z = sel
  end

  on :clk do
    sel = go
  end
end

defmodule Hw.FanoutTest.Lanes do
  use Hw.Component
  clock :clk, freq: 1.0, reset_style: :none
  input :go, 1
  input :d, 8
  output :q0, 8
  output :q1, 8
  output :q2, 8
  output :q3, 8
  wire :en, 1, init: 0
  wire :r0, 8, init: 0
  wire :r1, 8, init: 0
  wire :r2, 8, init: 0
  wire :r3, 8, init: 0

  fanout :en, 2

  comb do
    q0 = r0
    q1 = r1
    q2 = r2
    q3 = r3
  end

  on :clk do
    en = go

    if en do
      r0 = d
      r1 = r0
      r2 = r1
      r3 = r2
    end
  end
end

defmodule Hw.FanoutTest.Parent do
  use Hw.Component
  clock :clk, freq: 1.0, reset_style: :none
  input :go, 1
  input :a, 64
  input :b, 64
  output :y, 64
  output :z, 1

  instance :u, Hw.FanoutTest.Wide,
    clk: :clk, go: :go, a: :a, b: :b, y: :y, z: :z
end

defmodule Hw.FanoutTest.NotReg do
  use Hw.Component
  input :x, 1
  output :y, 1
  wire :w, 1

  fanout :w, 2

  comb do
    w = x
    y = w
  end
end

defmodule Hw.FanoutTest.WideEq do
  use Hw.Component
  clock :clk, freq: 1.0, reset_style: :none
  input :go, 1
  input :a, 64
  input :b, 64
  output :y, 64
  wire :sel, 1, init: 0

  fanout :sel, 4

  comb do
    if sel == 1 do
      y = a
    else
      y = b
    end
  end

  on :clk do
    sel = go
  end
end

defmodule Hw.FanoutTest.PlainEq do
  use Hw.Component
  clock :clk, freq: 1.0, reset_style: :none
  input :go, 1
  input :a, 64
  input :b, 64
  output :y, 64
  wire :sel, 1, init: 0

  comb do
    if sel == 1 do
      y = a
    else
      y = b
    end
  end

  on :clk do
    sel = go
  end
end

defmodule Hw.FanoutTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Hw.IR.Ops.{Concat, Mux, Reg}
  alias Hw.Sim
  alias __MODULE__.{Lanes, NotReg, Parent, Plain, PlainEq, Wide, WideEq}

  defp ir(mod), do: Hw.Compile.Elaborate.elaborate(mod)

  defp regs(design), do: for(%Reg{} = r <- design.ops, do: r)

  test "adds keep copies of the register" do
    d = ir(Wide)
    names = d |> regs() |> Enum.map(& &1.output.name) |> Enum.sort()
    assert names == [:sel, :sel__f1, :sel__f2, :sel__f3]
    assert d |> regs() |> Enum.filter(& &1.keep) |> length() == 4
    assert d.fanouts == []
  end

  test "splits the wide select over the copies" do
    d = ir(Wide)
    # the 64-bit mux behind y is now a Concat of 4 x 16-bit muxes, each on a different copy
    assert [%Concat{output: %{width: 64}, inputs: parts}] = for(%Concat{} = c <- d.ops, do: c)
    assert length(parts) == 4
    assert Enum.all?(parts, &(&1.width == 16))

    conds =
      for %Mux{output: o, cases: [{c, _}]} <- d.ops, String.contains?(to_string(o.name), "__p"), do: c.name

    assert Enum.sort(conds) == [:sel, :sel__f1, :sel__f2, :sel__f3]
  end

  test "simulates the same as the plain design" do
    {:ok, a} = Sim.start(Wide)
    {:ok, b} = Sim.start(Plain)
    :rand.seed(:exsss, {1, 2, 3})

    for _ <- 1..200 do
      go = :rand.uniform(2) - 1
      va = :rand.uniform(1 <<< 62)
      vb = :rand.uniform(1 <<< 62)

      for sim <- [a, b] do
        Sim.set(sim, :go, go)
        Sim.set(sim, :a, va)
        Sim.set(sim, :b, vb)
        Sim.tick(sim, :clk, 1)
      end

      assert {Sim.get(a, :y), Sim.get(a, :z)} == {Sim.get(b, :y), Sim.get(b, :z)}
    end
  end

  test "spreads enable consumers over copies" do
    d = ir(Lanes)
    assert d |> regs() |> Enum.filter(& &1.keep) |> length() == 2

    users =
      for %Mux{cases: cases} <- d.ops, {%{name: c}, _} <- cases, c in [:en, :en__f1], do: c

    assert :en in users
    assert :en__f1 in users
  end

  test "works inside an instance (prefixed names)" do
    d = ir(Parent)
    names = d |> regs() |> Enum.map(& &1.output.name)
    assert :u_sel__f1 in names
    assert :u_sel__f3 in names
  end

  test "rejects a signal that is not a register" do
    assert_raise Hw.Compile.Fanout.Error, ~r/not a register/, fn -> ir(NotReg) end
  end

  test "Verilog: each copy in its own (* keep *) always block" do
    v = Wide |> ir() |> Hw.Emit.Verilog.emit()
    assert length(String.split(v, "(* keep *) always @(posedge clk)")) - 1 == 4
    assert v =~ "reg sel__q = 1'b0;"
    assert v =~ "reg sel__f1__q = 1'b0;"
    assert v =~ "(* keep *) always @(posedge clk) sel__f1__q <= go;"
    assert v =~ "assign sel__f1 = sel__f1__q;"
    assert v =~ "wire sel__f1;"
    refute v =~ "FDRE"
    refute v =~ "ifdef SYNTHESIS"
    refute v =~ "initial sel__f1 "
  end


  test "folds `sel == 1` into the register and splits the mux behind it" do
    d = ir(WideEq)
    assert [%Concat{output: %{width: 64}, inputs: parts}] = for(%Concat{} = c <- d.ops, do: c)
    assert length(parts) == 4
    refute Enum.any?(d.ops, &match?(%Hw.IR.Ops.Eq{}, &1))
    refute Enum.any?(d.signals, &String.starts_with?(to_string(&1.name), "_eq_"))

    {:ok, a} = Sim.start(WideEq)
    {:ok, b} = Sim.start(PlainEq)
    :rand.seed(:exsss, {4, 5, 6})

    for _ <- 1..100 do
      go = :rand.uniform(2) - 1
      va = :rand.uniform(1 <<< 62)
      vb = :rand.uniform(1 <<< 62)

      for sim <- [a, b] do
        Sim.set(sim, :go, go)
        Sim.set(sim, :a, va)
        Sim.set(sim, :b, vb)
        Sim.tick(sim, :clk, 1)
      end

      assert Sim.get(a, :y) == Sim.get(b, :y)
    end
  end

end
