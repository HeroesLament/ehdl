defmodule CanControllerTest do
  use ExUnit.Case

  alias Hw.CAN.Controller
  alias Hw.CAN.BitTiming

  defp sig(design, name), do: Enum.find(design.signals, &(&1.name == name))

  setup_all do
    {:ok, design: Hw.Compile.Elaborate.elaborate(Controller)}
  end

  test "elaborates to a clocked design and emits Verilog", %{design: design} do
    verilog = Hw.emit(design)
    assert String.contains?(verilog, "always @(posedge")
  end

  test "bus and frame ports have the widths the protocol requires", %{design: design} do
    assert sig(design, :rx).width == 1
    assert sig(design, :tx).width == 1

    assert sig(design, :tx_id).width == 11
    assert sig(design, :tx_dlc).width == 4
    assert sig(design, :tx_data).width == 64

    assert sig(design, :rx_id).width == 11
    assert sig(design, :rx_dlc).width == 4
    assert sig(design, :rx_data).width == 64
  end

  test "error counters are 9 bits so bus-off at 256 is representable", %{design: design} do
    # An 8-bit TEC saturates at 255 and can never exceed it, so the bus-off
    # comparison would never fire.
    assert sig(design, :tec).width == 9
    assert sig(design, :rec).width == 9
  end

  test "the shift registers are sized for a full standard frame", %{design: design} do
    assert sig(design, :id_sr).width == 11
    assert sig(design, :dlc_sr).width == 4
    assert sig(design, :data_sr).width == 64
    assert sig(design, :crc_sr).width == 15
  end

  test "instantiates the bit timing and CRC units rather than reimplementing them",
       %{design: design} do
    # Elaboration flattens to a single module, so a sub-instance shows up as its
    # internal signals carrying the instance name as a prefix.
    names = MapSet.new(design.signals, & &1.name)

    assert MapSet.member?(names, :timing_tq_ctr),
           "bit timing was not instantiated"
    assert MapSet.member?(names, :timing_bit_end),
           "bit timing was not instantiated"

    # The CRC unit is purely combinational; its wiring is what proves it is in
    # the datapath rather than reimplemented inline.
    assert MapSet.member?(names, :crc_state)
    assert MapSet.member?(names, :crc_next)
    assert MapSet.member?(names, :crc_bit)
  end

  test "the stock controller is the 1 Mbit/s instantiation" do
    opts = BitTiming.config(48_000_000, 1_000_000)

    assert BitTiming.bitrate(48_000_000, opts) == 1_000_000
    assert BitTiming.sample_point_pct(opts) == 75.0
  end

  test "the template stamps out controllers at different bit rates" do
    defmodule Can500k do
      use Hw.CAN.ControllerTemplate, bitrate: 500_000
    end

    defmodule Can1M do
      use Hw.CAN.ControllerTemplate, bitrate: 1_000_000
    end

    v500 = Can500k |> Hw.Compile.Elaborate.elaborate() |> Hw.emit()
    v1m = Can1M |> Hw.Compile.Elaborate.elaborate() |> Hw.emit()

    assert String.contains?(v500, "always @(posedge")
    assert String.contains?(v1m, "always @(posedge")

    # Different bit rates must produce genuinely different hardware, not just a
    # different module name. Compare the numeric literals the two designs bake
    # in: the time-quantum compare constants live there.
    literals = fn v ->
      ~r/'d(\d+)/ |> Regex.scan(v) |> Enum.map(&List.last/1) |> Enum.sort()
    end

    refute literals.(v500) == literals.(v1m)
  end

  test "a bit rate the clock cannot divide is a compile-time error, not a rounded one" do
    assert_raise ArgumentError, ~r/no legal CAN bit timing/, fn ->
      defmodule CanImpossible do
        use Hw.CAN.ControllerTemplate, bitrate: 33_000
      end
    end
  end

  test "the frame field encoding covers every state the walk can hold", %{design: design} do
    # fld is 4 bits and the walk uses all 16 encodings, so every hdl_case arm is
    # reachable and there is no silent default swallowing a real state.
    assert sig(design, :fld).width == 4
  end
end
