defmodule Hw.TraceCoreTest do
  use ExUnit.Case, async: true

  alias Hw.Trace
  alias Hw.Trace.Scope
  alias Hw.Trace.Render

  describe "Scope.resolve/1" do
    test "strips an entity prefix into a scope segment" do
      assert Scope.resolve(:sie_rx_state) == {[:sie], :rx_state}
      assert Scope.resolve(:phy_dp_tx) == {[:phy], :dp_tx}
      assert Scope.resolve(:uart_tx_busy) == {[:uart_tx], :busy}
    end

    test "cdc-owned override wins over prefix matching (the dev_addr trap)" do
      # dev_addr has no cdc_ prefix and would otherwise land in :top —
      # the override must route it to :cdc, leaf name unchanged.
      assert Scope.resolve(:dev_addr) == {[:cdc], :dev_addr}
      # sie_ep_in_* are named after SIE wiring but CDC-owned; keep full leaf.
      assert Scope.resolve(:sie_ep_in_pid) == {[:cdc], :sie_ep_in_pid}
    end

    test "unprefixed signals land in the top scope" do
      assert Scope.resolve(:led) == {[:top], :led}
      assert Scope.resolve(:wifi_txd) == {[:top], :wifi_txd}
    end

    test "to_string / parse round-trip" do
      addr = {[:sie], :rx_state}
      assert Scope.to_string(addr) == "sie.rx_state"
      assert Scope.parse("sie.rx_state") == addr
      assert Scope.parse(:"sie.rx_state") == addr
      assert Scope.parse("led") == {[:top], :led}
    end
  end

  # A small fixture: a 1-bit clock-ish enable, a 1-bit valid, an 8-bit data.
  defp fixture_specs do
    [
      {:led, %{width: 1, init: 0}},
      {:sie_rx_valid, %{width: 1, init: 0}},
      {:sie_rx_data, %{width: 8, hint: :hex, init: 0}}
    ]
  end

  describe "new/2 and metadata" do
    test "builds hierarchical addresses, by_name index, and scope tree" do
      t = Trace.new(fixture_specs())

      assert Trace.address(t, :led) == {[:top], :led}
      assert Trace.address(t, :sie_rx_data) == {[:sie], :rx_data}
      assert Trace.address(t, "sie.rx_data") == {[:sie], :rx_data}
      assert Trace.address(t, :nonexistent) == nil

      assert Trace.meta(t, :sie_rx_data).hint == :hex
      assert Trace.meta(t, :led).hint == :bit

      tree = Trace.scope_tree(t)
      assert tree[:top] == [:led]
      assert Enum.sort(tree[:sie]) == [:rx_data, :rx_valid]
    end
  end

  describe "apply_delta/3 (sparse NIF path)" do
    test "folds changes, carries forward unmentioned signals, derives time" do
      t =
        Trace.new(fixture_specs())
        |> Trace.apply_delta([{100, :sie_rx_valid, 0, 1}, {100, :sie_rx_data, 0, 0xA5}])
        |> Trace.apply_delta([{200, :sie_rx_valid, 1, 0}])

      # cycle 0: valid=1, data=0xA5, led carried forward at init 0
      assert Trace.at(t, :sie_rx_valid, 0) == 1
      assert Trace.at(t, :sie_rx_data, 0) == 0xA5
      assert Trace.at(t, :led, 0) == 0
      # cycle 1: valid dropped, data carried forward (not in the delta)
      assert Trace.at(t, :sie_rx_valid, 1) == 0
      assert Trace.at(t, :sie_rx_data, 1) == 0xA5
      # time derived from max timestamp in each batch
      assert Trace.samples(t) |> Enum.map(& &1.time_ps) == [100, 200]
    end

    test "ignores untracked signals in the change log" do
      t =
        Trace.new(fixture_specs())
        |> Trace.apply_delta([{10, :some_untracked_sig, 0, 99}, {10, :led, 0, 1}])

      assert Trace.at(t, :led, 0) == 1
      assert Trace.count(t) == 1
    end
  end

  describe "apply_snapshot/3 (dense Live path)" do
    test "takes tracked keys, carries forward, uses explicit time" do
      t =
        Trace.new(fixture_specs())
        |> Trace.apply_snapshot(%{led: 1, sie_rx_valid: 1, sie_rx_data: 0xA5, extra: 7}, 100)
        |> Trace.apply_snapshot(%{led: 0}, 200)

      assert Trace.at(t, :led, 0) == 1
      assert Trace.at(t, :sie_rx_data, 0) == 0xA5
      # led changed, everything else carried forward
      assert Trace.at(t, :led, 1) == 0
      assert Trace.at(t, :sie_rx_data, 1) == 0xA5
      assert Trace.samples(t) |> Enum.map(& &1.time_ps) == [100, 200]
    end
  end

  describe "sparse/dense equivalence (the reconciliation invariant)" do
    test "a delta and the equivalent snapshot produce identical samples" do
      via_delta =
        Trace.new(fixture_specs())
        |> Trace.apply_delta([{50, :led, 0, 1}, {50, :sie_rx_data, 0, 0x3C}], 50)

      via_snapshot =
        Trace.new(fixture_specs())
        # dense snapshot of the SAME resulting state (comb signal sie_rx_valid
        # stays at its carried-forward init 0)
        |> Trace.apply_snapshot(%{led: 1, sie_rx_valid: 0, sie_rx_data: 0x3C}, 50)

      assert Trace.samples(via_delta) == Trace.samples(via_snapshot)
    end
  end

  describe "Render.ascii/2" do
    test "renders 1-bit edge glyphs and multi-bit hex labels, grouped by scope" do
      t =
        Trace.new(fixture_specs())
        |> Trace.apply_snapshot(%{led: 0, sie_rx_valid: 0, sie_rx_data: 0}, 0)
        |> Trace.apply_snapshot(%{led: 1, sie_rx_valid: 1, sie_rx_data: 0xA5}, 100)
        |> Trace.apply_snapshot(%{led: 1, sie_rx_valid: 0, sie_rx_data: 0xA5}, 200)

      out = Render.ascii(t, width: 40)

      # scope headers present
      assert out =~ "sie"
      assert out =~ "top"
      # hex hint applied to multi-bit data (uppercase, matching Integer.to_string/2)
      assert out =~ "0xA5"
    end

    test "format_value honors hints" do
      assert Render.format_value(0xA5, %{hint: :hex}) == "0xA5"
      assert Render.format_value(5, %{hint: :unsigned}) == "5"
      assert Render.format_value(3, %{hint: {:enum, %{3 => "sending"}}}) == "sending"

      # signed: 4-bit 0b1111 => -1
      assert Render.format_value(0b1111, %{hint: :signed, width: 4}) == "-1"
    end

    test "sample_to_columns up/down-samples to exact width" do
      assert length(Render.sample_to_columns([1, 0, 1], 9)) == 9
      assert length(Render.sample_to_columns([1, 0, 1, 0, 1, 0], 3)) == 3
      assert Render.sample_to_columns([], 5) == [0, 0, 0, 0, 0]
    end
  end
end
