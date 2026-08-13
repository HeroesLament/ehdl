defmodule Bit2BinTest do
  use ExUnit.Case, async: true

  alias Hw.Xilinx.Bit2Bin

  # Build a minimal but structurally faithful .bit: length-prefixed preamble,
  # the 0x0001 marker, the a/b/c/d string records, then an 'e' record whose
  # payload starts with 0xFF padding and the sync word, as real bitstreams do.
  defp bitfile(config) do
    rec = fn key, str -> <<key, byte_size(str)::16>> <> str end

    preamble = <<0x0F, 0xF0, 0x0F, 0xF0, 0x0F, 0xF0, 0x0F, 0xF0, 0x00>>

    <<byte_size(preamble)::16>> <>
      preamble <>
      <<0x00, 0x01>> <>
      rec.(?a, "design.ncd;UserID=0xFFFFFFFF\0") <>
      rec.(?b, "7z020clg400\0") <>
      rec.(?c, "2026/07/28\0") <>
      rec.(?d, "10:00:00\0") <>
      <<?e, byte_size(config)::32>> <> config
  end

  @padding <<0xFF, 0xFF, 0xFF, 0xFF>>
  @sync_bit <<0xAA, 0x99, 0x55, 0x66>>

  describe "to_bin!/1" do
    test "strips the header and byte-swaps the config data" do
      config = @padding <> @sync_bit <> <<0x30, 0x00, 0x80, 0x01>>
      out = Bit2Bin.to_bin!(bitfile(config))

      assert out ==
               <<0xFF, 0xFF, 0xFF, 0xFF>> <>
                 <<0x66, 0x55, 0x99, 0xAA>> <>
                 <<0x01, 0x80, 0x00, 0x30>>
    end

    test "output carries the sync word in fpga_manager byte order" do
      out = Bit2Bin.to_bin!(bitfile(@padding <> @sync_bit))
      assert :binary.match(out, <<0x66, 0x55, 0x99, 0xAA>>) != :nomatch
    end

    test "drops the header entirely — no part name survives into the .bin" do
      out = Bit2Bin.to_bin!(bitfile(@padding <> @sync_bit))
      assert :binary.match(out, "7z020clg400") == :nomatch
    end

    test "is byte-count preserving on the config section" do
      config = @padding <> @sync_bit <> <<1, 2, 3, 4, 5, 6, 7, 8>>
      assert byte_size(Bit2Bin.to_bin!(bitfile(config))) == byte_size(config)
    end

    test "rejects a bitstream with no sync word rather than emitting garbage" do
      assert_raise ArgumentError, ~r/no sync word/, fn ->
        Bit2Bin.to_bin!(bitfile(<<0, 0, 0, 0, 1, 1, 1, 1>>))
      end
    end

    test "rejects config data that is not word-aligned" do
      assert_raise ArgumentError, ~r/multiple of 4/, fn ->
        Bit2Bin.to_bin!(bitfile(@padding <> @sync_bit <> <<0xAB>>))
      end
    end

    test "rejects a file that is not a .bit at all" do
      assert_raise ArgumentError, fn -> Bit2Bin.to_bin!(<<"not a bitstream at all">>) end
    end
  end
end
