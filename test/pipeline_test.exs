defmodule PipelineTest do
  use ExUnit.Case

  defp sig(design, name), do: Enum.find(design.signals, &(&1.name == name))

  test "pipeline auto-declares stage outputs (inferred width) and threads valid" do
    defmodule Pipe.Dsp do
      use Hw.Component
      clock :clk, freq: 1.0
      input :rst,    1
      input :a,      8
      input :b,      8
      input :c,      16
      input :d,      4
      input :thresh, 16
      input :in_v,   1
      output :out_v, 1

      pipeline :dsp, clock: :clk, reset: :rst, valid_in: :in_v, valid_out: :out_v do
        stage do s1   = a + b end
        stage do s2   = s1 * c end
        stage do s3   = s2 + d end
        stage do flag = s3 > thresh end
      end
    end

    design = Hw.Compile.Elaborate.elaborate(Pipe.Dsp)

    # Stage outputs auto-declared, widths inferred and propagated in dataflow order.
    assert sig(design, :s1).width == 8    # max(8, 8)
    assert sig(design, :s2).width == 16   # max(8, 16)
    assert sig(design, :s3).width == 16   # max(16, 4)
    assert sig(design, :flag).width == 1  # comparison

    # Valid chain: n-1 = 3 intermediate 1-bit regs for 4 stages; no 4th.
    assert sig(design, :dsp__valid_1).width == 1
    assert sig(design, :dsp__valid_2).width == 1
    assert sig(design, :dsp__valid_3).width == 1
    assert sig(design, :dsp__valid_4) == nil

    # Elaborates all the way to valid Verilog.
    verilog = Hw.emit(design)
    assert String.contains?(verilog, "always @(posedge")
  end

  test "pipeline without reset still threads valid (FF-init only)" do
    defmodule Pipe.NoReset do
      use Hw.Component
      clock :clk, freq: 1.0
      input :a,    8
      input :b,    8
      input :in_v, 1
      output :out_v, 1

      pipeline :p, clock: :clk, valid_in: :in_v, valid_out: :out_v do
        stage do x = a + b end
        stage do y = x + a end
      end
    end

    design = Hw.Compile.Elaborate.elaborate(Pipe.NoReset)
    assert sig(design, :x).width == 8
    assert sig(design, :y).width == 8
    assert sig(design, :p__valid_1).width == 1   # 2 stages -> 1 intermediate
    assert sig(design, :p__valid_2) == nil
  end

  test "a pipeline with no stages is a clear error" do
    assert_raise RuntimeError, ~r/has no .stage/, fn ->
      defmodule Pipe.Empty do
        use Hw.Component
        clock :clk, freq: 1.0
        input :a, 8

        pipeline :empty, clock: :clk do
          a
        end
      end
    end
  end
end
