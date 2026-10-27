defmodule Hw.CensusTest do
  use ExUnit.Case, async: true

  alias Hw.Census
  alias Hw.Census.Attribution

  # A hand-built yosys JSON netlist:
  #
  #   bit 2  "u_dec_sel"   FDRE output, drives 3 LUT inputs + 1 CE
  #   bit 3  "_eq_100"     LUT2 output (emitter temp), drives 2 LUT inputs
  #   bit 4  (unnamed)     LUT2 output, drives 1 LUT input
  #   bit 5  "u_dec_a"     top input, drives 1 LUT input
  #   bit 6  "clk"
  #
  # FFs: ff0 {clk, CE=bit2, R=0}, ff1 {clk, CE=1, R=0}, ff2 {clk, CE=1, R=0}
  defp netlist do
    lut = fn inputs, out ->
      conns = inputs |> Enum.with_index() |> Map.new(fn {b, i} -> {"I#{i}", [b]} end)
      dirs = conns |> Map.keys() |> Map.new(&{&1, "input"})

      %{
        "type" => "LUT#{length(inputs)}",
        "connections" => Map.put(conns, "O", [out]),
        "port_directions" => Map.put(dirs, "O", "output")
      }
    end

    fdre = fn d, q, ce ->
      %{
        "type" => "FDRE",
        "connections" => %{"C" => [6], "CE" => [ce], "R" => ["0"], "D" => [d], "Q" => [q]},
        "port_directions" => %{
          "C" => "input",
          "CE" => "input",
          "R" => "input",
          "D" => "input",
          "Q" => "output"
        }
      }
    end

    %{
      "modules" => %{
        "top" => %{
          "attributes" => %{"top" => "00000000000000000000000000000001"},
          "netnames" => %{
            "u_dec_sel" => %{"bits" => [2], "attributes" => %{"src" => "top.v:10.8-10.17"}},
            "_eq_100" => %{"bits" => [3], "attributes" => %{"src" => "top.v:11.8-11.15"}},
            "$abc$1$n4" => %{"bits" => [4], "attributes" => %{}},
            "u_dec_a" => %{"bits" => [5], "attributes" => %{"src" => "top.v:3.9-3.16"}},
            "clk" => %{"bits" => [6], "attributes" => %{"src" => "top.v:2.9-2.12"}},
            "_mux_200" => %{"bits" => [2], "attributes" => %{"src" => "top.v:12.8-12.16"}},
            "u_bus" => %{"bits" => [8, 9], "attributes" => %{"src" => "top.v:13.8-13.13"}}
          },
          "cells" => %{
            "ff_sel" => fdre.(5, 2, "1"),
            "lut_eq" => lut.([2, 5], 3),
            "lut_a" => lut.([2, 3], 4),
            "lut_b" => lut.([2, 3, 4], 7),
            "ff0" => fdre.(7, 8, 2),
            "ff1" => fdre.(8, 9, "1")
          }
        }
      }
    }
  end

  setup do
    {:ok, c} = Census.from_json(netlist(), [])
    %{c: c}
  end

  test "LUT-input and control fanout", %{c: c} do
    assert c.lut_fanout[2] == 3
    assert c.lut_fanout[3] == 2
    assert c.lut_fanout[4] == 1
    assert c.lut_fanout[5] == 1
    assert c.ctl_fanout[2] == 1
    assert Census.max_lut_fanout(c) == 3
    assert Census.nets_above(c, 1) == 2
  end

  test "histogram buckets", %{c: c} do
    assert Census.histogram(c, [1, 2]) == [{1, 2}, {2, 1}, {:inf, 1}]
  end

  test "names, drivers and top nets", %{c: c} do
    [first, second | _] = Census.top_nets(c, 4)
    assert %{bit: 2, lut: 3, ctl: 1, driver_type: "FDRE", name: "u_dec_sel"} = first
    assert %{bit: 3, lut: 2, driver_type: "LUT2", name: "_eq_100", src: "top.v:11.8-11.15"} = second
    assert Census.net_info(c, 4).name == nil
  end

  test "design names beat temporaries; wide wires are indexed", %{c: c} do
    # bit 2 is also "_mux_200" (shorter), but the design name wins
    assert c.names[2] == "u_dec_sel"
    assert c.names[8] == "u_bus[0]"
    assert c.names[9] == "u_bus[1]"
    assert Census.base_name("u_bus[1]") == "u_bus"
  end

  test "control sets and resources", %{c: c} do
    assert %{sets: 2, small_sets: 2, ffs_in_small_sets: 3} = Census.control_set_summary(c)
    r = Census.resources(c)
    assert r.lut == 3
    assert r.ff == 3
    assert Census.driver_types_over(c, 1) == %{"FDRE" => 1, "LUT2" => 1}
  end

  test "attribution of a temporary, an unnamed net and a named net", %{c: c} do
    a = Attribution.from_exprs(%{"_eq_100" => "u_dec_sel == 32'd1"})

    eq = Attribution.explain(c, a, Census.net_info(c, 3))
    assert eq.expr == "u_dec_sel == 32'd1"
    assert eq.signals == ["u_dec_sel"]
    assert eq.block == "u_dec"

    anon = Attribution.explain(c, a, Census.net_info(c, 4))
    assert anon.label == "<LUT2 bit 4>"
    assert anon.signals == ["u_dec_sel"]

    named = Attribution.explain(c, a, Census.net_info(c, 2))
    assert named.signals == ["u_dec_sel"]
    assert named.expr == nil
  end

  test "block_of" do
    assert Attribution.block_of(["phy_rx_u_ldpc_q_hb", "phy_rx_u_ldpc_p_hb"]) == "phy_rx_u_ldpc"
    assert Attribution.block_of(["a_b_c_x", "a_b_c_y", "q_r"]) == "a_b_c"
    assert Attribution.block_of(["phy_phy_en", "phy_t_start", "phy_trx_tx_run"]) == "phy_*"
    assert Attribution.block_of(["a_x", "b_y"]) == nil
    assert Attribution.block_of([]) == nil
  end

  test "verilog path and expression scan" do
    {:ok, c} = Census.from_json(netlist(), [])
    assert Attribution.verilog_path(c) == "top.v"

    path = Path.join(System.tmp_dir!(), "hw_census_attr_#{System.unique_integer([:positive])}.v")

    File.write!(path, """
    module top(input clk);
      wire _eq_100;
      assign _eq_100 = u_dec_sel == 32'd1;
      assign named = _eq_100;
    endmodule
    """)

    {:ok, a} = Attribution.load_verilog(path)
    File.rm!(path)
    assert a.exprs == %{"_eq_100" => "u_dec_sel == 32'd1"}
  end

  test "budget check" do
    {:ok, c} = Census.from_json(netlist(), [])
    t = %{Hw.Target.get(:xc7z020) | lut_input_fanout: [max: 2, warn: 1]}
    findings = Hw.Target.check(c, t)

    assert [%{level: :error, metric: :lut_input_fanout, value: 3, limit: 2}, %{level: :warning, value: 1}] =
             findings

    assert Hw.Target.errors?(findings)
    assert Hw.Target.check(c, Hw.Target.get(:xc7z020)) == []
  end
end
