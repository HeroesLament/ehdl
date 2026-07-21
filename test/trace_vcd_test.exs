defmodule Hw.TraceVCDTest do
  use ExUnit.Case, async: true

  alias Hw.Trace
  alias Hw.Trace.VCD

  defp fixture do
    specs = [
      # top-scope combinational net (no domain) → wire
      {:led, %{width: 1, init: 0, domain: nil}},
      # sie-scope registered signals (domain set) → reg
      {:sie_rx_state, %{width: 3, init: 0, domain: :clk_48}},
      {:cdc_dev_state, %{width: 2, init: 0, domain: :clk_48}}
    ]

    Trace.new(specs)
    |> Trace.apply_snapshot(%{led: 0, sie_rx_state: 0, cdc_dev_state: 0}, 0)
    |> Trace.apply_snapshot(%{led: 1, sie_rx_state: 2, cdc_dev_state: 0}, 100)
    |> Trace.apply_snapshot(%{led: 1, sie_rx_state: 2, cdc_dev_state: 2}, 200)
  end

  test "emits real nested $scope blocks per scope, not one flat scope" do
    vcd = VCD.to_vcd(fixture())

    # three scopes: cdc, sie, top — each its own $scope module ... $upscope
    assert vcd =~ "$scope module top $end"
    assert vcd =~ "$scope module sie $end"
    assert vcd =~ "$scope module cdc $end"

    # one $upscope per scope (3 total)
    assert (vcd |> String.split("$upscope") |> length()) - 1 == 3

    # leaf names inside scopes are bare (not the flat prefixed form)
    assert vcd =~ ~r/\$var \w+ 3 \S+ rx_state \$end/
    assert vcd =~ ~r/\$var \w+ 2 \S+ dev_state \$end/
    assert vcd =~ ~r/\$var \w+ 1 \S+ led \$end/
  end

  test "reg vs wire type (fixes the old no-op conditional)" do
    vcd = VCD.to_vcd(fixture())

    # led has no domain → wire; registered signals → reg
    assert vcd =~ ~r/\$var wire 1 \S+ led \$end/
    assert vcd =~ ~r/\$var reg 3 \S+ rx_state \$end/
    assert vcd =~ ~r/\$var reg 2 \S+ dev_state \$end/
  end

  test "body emits timestamped value changes only when values change" do
    vcd = VCD.to_vcd(fixture())

    # timestamps for the two changing samples
    assert vcd =~ "#100"
    assert vcd =~ "#200"

    # multi-bit change encoded as b<bits> — rx_state=2 (011? width 3 => 010)
    assert vcd =~ ~r/b010 \S+/
    # 1-bit led rising to 1
    assert vcd =~ ~r/\n1\S+\n/
  end

  test "well-formed VCD preamble" do
    vcd = VCD.to_vcd(fixture())
    assert vcd =~ "$timescale 1ps $end"
    assert vcd =~ "$enddefinitions $end"
    assert vcd =~ "$dumpvars"
    assert String.contains?(vcd, "#0")
  end

  test "signal selection limits exported vars" do
    vcd = VCD.to_vcd(fixture(), signals: [:led])
    assert vcd =~ "led"
    refute vcd =~ "rx_state"
    refute vcd =~ "$scope module sie"
  end
end
