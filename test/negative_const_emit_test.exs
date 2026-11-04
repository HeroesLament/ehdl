defmodule Hw.NegativeConstEmitTest do
  use ExUnit.Case

  defmodule NegConst do
    use Hw.Component

    clock(:clk, freq: 32.0)
    input(:sel, 1)
    output(:y, 18)

    comb do
      y =
        if sel == 1 do
          17003
        else
          0 - 17003
        end
    end
  end

  test "a folded negative constant is emitted as its two's complement, not 'd-N" do
    v = Hw.emit(Hw.Compile.Elaborate.elaborate(NegConst))
    refute v =~ "'d-"
    # -17003 at 32 bits; assigned to the 18-bit y it keeps the right low bits.
    assert v =~ "32'd#{Bitwise.band(-17003, 0xFFFF_FFFF)}"
  end
end
