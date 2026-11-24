defmodule ECP5WrappersTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Emitted-Verilog tests for the generated `Hw.ECP5.*` wrappers (ports from
  oxibit-ecp5's primitive declarations, parameter defaults from the yosys
  Lattice library). Each wrapper elaborates on its own and its
  instantiation must name the primitive, every port and every parameter.
  Text assertions, for the reason given in `test/xilinx_primitives_test.exs`.
  """

  @wrappers ~w(
    Hw.ECP5.ALU54B
    Hw.ECP5.BBPD
    Hw.ECP5.BBPU
    Hw.ECP5.DDRDLLA
    Hw.ECP5.DP16KD
    Hw.ECP5.DPR16X4C
    Hw.ECP5.DQSBUFM
    Hw.ECP5.ECLKBRIDGECS
    Hw.ECP5.IBPD
    Hw.ECP5.IBPU
    Hw.ECP5.IDDR71B
    Hw.ECP5.IDDRX2DQA
    Hw.ECP5.IDDRX2F
    Hw.ECP5.IFS1P3BX
    Hw.ECP5.IFS1P3DX
    Hw.ECP5.IFS1P3IX
    Hw.ECP5.IFS1P3JX
    Hw.ECP5.IFS1S1B
    Hw.ECP5.IFS1S1D
    Hw.ECP5.IFS1S1I
    Hw.ECP5.IFS1S1J
    Hw.ECP5.MULT18X18D
    Hw.ECP5.OBCO
    Hw.ECP5.OBZPD
    Hw.ECP5.OBZPU
    Hw.ECP5.ODDR71B
    Hw.ECP5.ODDRX2DQA
    Hw.ECP5.ODDRX2DQSB
    Hw.ECP5.ODDRX2F
    Hw.ECP5.OFS1P3BX
    Hw.ECP5.OFS1P3DX
    Hw.ECP5.OFS1P3IX
    Hw.ECP5.OFS1P3JX
    Hw.ECP5.OSHX2A
    Hw.ECP5.PDPW16KD
    Hw.ECP5.SEDGA
    Hw.ECP5.SGSR
    Hw.ECP5.SPR16X4C
    Hw.ECP5.TRELLIS_ECLKBUF
    Hw.ECP5.TRELLIS_IO
    Hw.ECP5.TSHX2DQA
    Hw.ECP5.TSHX2DQSA
  )a

  defp verilog(mod), do: mod |> Hw.Compile.Elaborate.elaborate() |> Hw.emit()

  for mod <- @wrappers do
    @mod Module.concat([mod])
    test "#{inspect(@mod)} emits its primitive with every port and parameter" do
      v = verilog(@mod)
      [bb] = @mod.__hw_blackboxes__()
      {prim, opts} = {bb.module, [ports: bb.ports, params: bb.params]}
      assert v =~ ~r/\b#{prim}\b/
      for {port, _} <- Keyword.get(opts, :ports, []) do
        assert v =~ ~r/\.#{port}\(/, "port #{port} missing"
      end
      for {param, _} <- Keyword.get(opts, :params, []) do
        assert v =~ ~r/\.#{param}\(/, "parameter #{param} missing"
      end
    end
  end

  test "DQSBUFM defaults to the delays the fuses encode (PLUS / 0)" do
    v = verilog(Hw.ECP5.DQSBUFM)
    assert v =~ ~s|.DQS_LI_DEL_ADJ("PLUS")|
    assert v =~ ~r/\.DQS_LI_DEL_VAL\(0\)/
    refute v =~ "FACTORYONLY"
  end

  test "DP16KD INITVAL defaults are the 0x strings oxibit reads" do
    v = verilog(Hw.ECP5.DP16KD)
    assert v =~ ~s|.INITVAL_00("0x#{String.duplicate("0", 80)}")|
    assert v =~ ~r/\.DATA_WIDTH_A\(18\)/
  end
end
