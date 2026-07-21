defmodule EHDLTest do
  use ExUnit.Case

  test "Hw.to_verilog!/1 emits valid Verilog for a minimal component" do
    defmodule Smoke.Counter do
      use Hw.Component
      clock :clk, freq: 1.0
      input  :rst,   1
      input  :en,    1
      output :count, 8

      on :clk do
        if rst do
          count = 0
        else
          if en do
            count = count + 1
          end
        end
      end
    end

    design  = Hw.Compile.Elaborate.elaborate(Smoke.Counter)
    verilog = Hw.emit(design)
    assert String.contains?(verilog, "module")
    assert String.contains?(verilog, "clk")
    assert String.contains?(verilog, "count")
    assert String.contains?(verilog, "always @(posedge")
  end

  test "Hw.Compile.Validate.validate/1 returns ok for a well-formed design" do
    defmodule Smoke.Valid do
      use Hw.Component
      clock :clk, freq: 1.0
      input  :rst, 1
      input  :a,   8
      output :b,   8

      on :clk do
        if rst do; b = 0; else; b = a; end
      end
    end

    design = Hw.Compile.Elaborate.elaborate(Smoke.Valid)
    assert {:ok, _} = Hw.Compile.Validate.validate(design)
  end

  test "Hw.Compile.Validate.validate/1 returns error for width overflow comparison" do
    defmodule Smoke.Invalid do
      use Hw.Component
      clock :clk, freq: 1.0
      input  :rst,     1
      input  :counter, 4
      output :tick,    1

      on :clk do
        if rst do; tick = 0; else
          tick = (counter == 48_000_000)
        end
      end
    end

    design = Hw.Compile.Elaborate.elaborate(Smoke.Invalid)
    assert {:error, errors} = Hw.Compile.Validate.validate(design)
    assert Enum.any?(errors, &String.contains?(&1.message, "never be true"))
  end
end
