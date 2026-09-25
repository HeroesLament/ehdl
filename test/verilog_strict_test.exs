defmodule VerilogStrictTest do
  use ExUnit.Case, async: true

  # ---------------------------------------------------------------------------
  # Emitted Verilog must be LEGAL Verilog, not merely Yosys-tolerated.
  #
  # Until 2026-09-24 the emitter declared procedurally assigned nets as
  # `wire` / bare `output`: every >2-arm mux rendered as `always @(*)`
  # (FSM next-state `_case_N` nets) and every registered output port.
  # Yosys accepted it, so synthesis never noticed; iverilog rejects it
  # outright. Strict compilation here catches that whole class.
  #
  # The reader testbench then runs the emitted RTL in iverilog: an
  # independent simulator. The EHDL-simulator suite for the same component
  # (axi_hp_reader_test.exs) is what the 2026-09-24 ordering bug broke; this
  # one kept passing, which is what located the fault in the simulator
  # rather than the design. Keep both.
  #
  # Needs iverilog: PATH, $IVERILOG, or ~/oss-cad-suite/bin. Skipped if absent.
  # ---------------------------------------------------------------------------

  @iverilog System.get_env("IVERILOG") ||
              System.find_executable("iverilog") ||
              (File.exists?(Path.expand("~/oss-cad-suite/bin/iverilog")) &&
                 Path.expand("~/oss-cad-suite/bin/iverilog")) || nil

  if is_nil(@iverilog), do: @moduletag(skip: "iverilog not found")
  @moduletag :iverilog

  # Components that must emit strict-legal Verilog. Add new std components.
  @components [Hw.AXIHPReader, Hw.AXIHPWriter, Hw.FIFO, Hw.StreamBRAMFIFO]

  setup do
    dir = Path.join(System.tmp_dir!(), "ehdl_strict_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp emit!(mod, dir) do
    path = Path.join(dir, "#{mod |> Module.split() |> List.last() |> Macro.underscore()}.v")
    File.write!(path, Hw.emit(Hw.Compile.Elaborate.elaborate(mod)))
    path
  end

  defp iverilog(args), do: System.cmd(@iverilog, ["-g2012" | args], stderr_to_stdout: true)

  for mod <- @components do
    test "#{inspect(mod)} emits Verilog that iverilog accepts", %{dir: dir} do
      src = emit!(unquote(mod), dir)
      {out, rc} = iverilog(["-o", Path.join(dir, "a.out"), src])
      assert rc == 0, "iverilog rejected #{inspect(unquote(mod))}:\n#{out}"
    end
  end

  test "procedurally assigned nets are declared reg, registered outputs `output reg`", %{dir: dir} do
    v = File.read!(emit!(Hw.AXIHPReader, dir))

    decl = fn n -> Regex.run(~r/^\s*(output reg|output|reg|wire)\b[^;\n]*\b#{n};/m, v, capture: :all_but_first) end

    # Every net assigned inside `always @(*)` must be declared reg...
    procedural =
      Regex.scan(~r/always @\(\*\) begin\n(.*?)\n\s*end\n/s, v, capture: :all_but_first)
      |> Enum.flat_map(fn [body] ->
        Regex.scan(~r/^\s*(?:(?:else )?if \(.*?\) |else )?(\w+) = /m, body, capture: :all_but_first)
      end)
      |> List.flatten()
      |> Enum.uniq()

    assert procedural != [], "expected >2-arm muxes rendered as always @(*)"
    for n <- procedural, do: assert(decl.(n) in [["reg"], ["output reg"]], "#{n}: always @(*) target not declared reg")

    # ...and every continuous-assign target must not be.
    for [n] <- Regex.scan(~r/^\s*assign (\w+) =/m, v, capture: :all_but_first),
        do: assert(decl.(n) in [["wire"], ["output"]], "#{n}: assign target declared #{inspect(decl.(n))}")
    assert v =~ ~r/^\s*output reg \[15:0\] bursts;/m
    assert v =~ ~r/^\s*output reg m_axi_arvalid;/m
    # A continuous-assign output must stay a plain output.
    assert v =~ ~r/^\s*output m_wen;/m
  end

  test "Hw.AXIHPReader passes its Verilog testbench under iverilog", %{dir: dir} do
    dut = emit!(Hw.AXIHPReader, dir)
    tb = Path.expand("support/verilog/tb_axi_hp_reader.v", __DIR__)
    bin = Path.join(dir, "tb")

    {out, rc} = iverilog(["-o", bin, tb, dut])
    assert rc == 0, out

    vvp = Path.join(Path.dirname(@iverilog), "vvp")
    {log, _} = System.cmd(vvp, ["-n", bin], stderr_to_stdout: true, cd: dir)

    fails = for l <- String.split(log, "\n"), String.starts_with?(l, "FAIL"), do: l
    assert fails == [], Enum.join(fails, "\n")
    assert log =~ "DONE fails=0"
  end

  describe "Verilog keywords" do
    alias Hw.Emit.Verilog.Names
    alias Hw.IR.Design
    alias Hw.IR.Types.Signal

    defp sig(name, dir), do: %Signal{name: name, width: 1, signed: false, direction: dir}

    test "reserved?/1 covers Verilog-2005 and SystemVerilog keywords" do
      for k <- ~w(buf wire reg table logic bit int interface) , do: assert(Names.reserved?(k), k)
      for k <- ~w(buffer wr_ptr state m_data), do: refute(Names.reserved?(k), k)
    end

    test "a reserved port name raises instead of silently renaming the interface" do
      d = %Design{name: :kw_port, signals: [sig(:wire, :input), sig(:ok, :output)]}
      assert_raise ArgumentError, ~r/input wire/, fn -> Names.legalize(d) end
    end

    test "a SystemVerilog-only keyword is a legal Verilog-2005 port name" do
      d = %Design{name: :sv_port, signals: [sig(:ref, :input), sig(:logic, :internal)]}
      assert Names.legalize(d).signals |> Enum.map(& &1.name) == [:ref, :logic_r]
    end

    test "reserved internal names are renamed without colliding" do
      d = %Design{name: :kw_int, signals: [sig(:logic, :internal), sig(:logic_r, :internal)]}
      names = Names.legalize(d).signals |> Enum.map(& &1.name)
      assert names == [:logic_r_, :logic_r]
    end

    test "Hw.StreamBRAMFIFO's memory `buf` is emitted under a legal name", %{dir: dir} do
      v = File.read!(emit!(Hw.StreamBRAMFIFO, dir))
      refute v =~ ~r/\bbuf\b/
      assert v =~ ~r/reg \[63:0\] buf_r \[0:1023\];/
      assert v =~ "buf_r[wr_idx] <= wr_data"
      assert v =~ "<= buf_r[rd_idx]"
    end
  end

end
