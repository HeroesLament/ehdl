defmodule PipelineBalanceTest do
  use ExUnit.Case

  defp sig(design, name), do: Enum.find(design.signals, &(&1.name == name))
  defp has?(design, name), do: sig(design, name) != nil

  test "cross-stage references get delay chains of the right depth" do
    defmodule Bal.Skew do
      use Hw.Component
      clock :clk, freq: 1.0
      input :rst, 1
      input :a, 8
      input :b, 8
      input :c, 8
      input :in_v, 1
      output :out_v, 1

      pipeline :bal, clock: :clk, reset: :rst, valid_in: :in_v, valid_out: :out_v do
        stage do s1 = a + b end     # i=0
        stage do s2 = s1 + c end    # i=1: c external -> delay 1
        stage do s3 = s2 + a end    # i=2: a external -> delay 2
        stage do r  = s3 + s1 end   # i=3: s1 from stage 0 -> delay 3-0-1 = 2
      end
    end

    design = Hw.Compile.Elaborate.elaborate(Bal.Skew)

    # c used at stage 1 -> one delay register
    assert has?(design, :c__dly_1)
    refute has?(design, :c__dly_2)

    # a used at stage 2 -> a 2-deep chain
    assert has?(design, :a__dly_1)
    assert has?(design, :a__dly_2)
    refute has?(design, :a__dly_3)

    # s1 (stage 0 output) used at stage 3 -> a 2-deep chain
    assert has?(design, :s1__dly_1)
    assert has?(design, :s1__dly_2)
    refute has?(design, :s1__dly_3)

    # delay registers take the width of their source (inferred)
    assert sig(design, :c__dly_1).width == 8
    assert sig(design, :s1__dly_2).width == 8   # s1 = a + b -> 8

    # elaborates end to end
    assert String.contains?(Hw.emit(design), "always @(posedge")
  end

  test "a straight pipeline (each stage reads only the prior stage) inserts no delays" do
    defmodule Bal.Straight do
      use Hw.Component
      clock :clk, freq: 1.0
      input :a, 8
      input :b, 8
      input :in_v, 1
      output :out_v, 1

      pipeline :st, clock: :clk, valid_in: :in_v, valid_out: :out_v do
        stage do u = a + b end   # i=0: a,b at stage 0 -> no delay
        stage do v = u + u end   # i=1: u is prior stage -> no delay
        stage do w = v + v end   # i=2: v is prior stage -> no delay
      end
    end

    design = Hw.Compile.Elaborate.elaborate(Bal.Straight)
    refute has?(design, :a__dly_1)
    refute has?(design, :u__dly_1)
    refute has?(design, :v__dly_1)
  end

  test "referencing a later/same stage output is an error" do
    assert_raise RuntimeError, ~r/feedback|forward/, fn ->
      defmodule Bal.Forward do
        use Hw.Component
        clock :clk, freq: 1.0
        input :a, 8
        input :in_v, 1
        output :out_v, 1

        pipeline :fwd, clock: :clk, valid_in: :in_v, valid_out: :out_v do
          stage do p = a + q end   # i=0 references q from stage 1 (forward)
          stage do q = p + a end
        end
      end
    end
  end
end
