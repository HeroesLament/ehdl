defmodule CanCrc15Test do
  use ExUnit.Case

  alias Hw.CAN.CRC15

  defp sig(design, name), do: Enum.find(design.signals, &(&1.name == name))

  test "elaborates with the expected port widths" do
    design = Hw.Compile.Elaborate.elaborate(CRC15)

    assert sig(design, :crc_in).width == 15
    assert sig(design, :crc_out).width == 15
    assert sig(design, :bit_in).width == 1
    assert sig(design, :valid).width == 1

    # Purely combinational: no clocked process in the emitted Verilog.
    verilog = Hw.emit(design)
    refute String.contains?(verilog, "always @(posedge")
  end

  test "single-bit update matches the polynomial by hand" do
    # crc = 0, bit = 1 -> inv = 1, shifted = 0, result = poly
    assert CRC15.next(0, 1) == 0x4599
    # crc = 0, bit = 0 -> no feedback, stays zero
    assert CRC15.next(0, 0) == 0
    # A register with nothing in the top bit just shifts.
    assert CRC15.next(0x0001, 0) == 0x0002
  end

  test "state stays inside 15 bits" do
    for bits <- [[1], [1, 1], [1, 0, 1, 1, 0], List.duplicate(1, 40)] do
      assert CRC15.compute(bits) <= 0x7FFF
    end
  end

  test "appending the CRC drives the register to zero (the RX residual)" do
    # This is the property a receiver relies on: clock in the frame, then the
    # 15 CRC bits, and a good frame leaves the register at 0.
    frames = [
      [0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 1, 1],
      [0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0],
      [0],
      List.duplicate(1, 64) ++ List.duplicate(0, 19),
      for(i <- 1..97, do: rem(i * i + 3, 2))
    ]

    for frame <- frames do
      crc = CRC15.compute(frame)
      assert CRC15.compute(frame ++ CRC15.bits(crc, 15)) == 0
    end
  end

  test "a single flipped bit is always detected" do
    frame = [0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 1, 1, 0, 1, 0, 1, 1, 0, 0, 1]
    crc = CRC15.compute(frame)
    good = frame ++ CRC15.bits(crc, 15)

    for i <- 0..(length(good) - 1) do
      corrupted = List.update_at(good, i, fn b -> 1 - b end)
      assert CRC15.compute(corrupted) != 0, "flip at #{i} went undetected"
    end
  end

  test "bits/2 expands MSB first" do
    assert CRC15.bits(0b1011, 4) == [1, 0, 1, 1]
    assert CRC15.bits(0x4599, 15) == [1, 0, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1]
  end
end
