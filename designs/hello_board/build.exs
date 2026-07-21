#!/usr/bin/env elixir
# designs/hello_board/build.exs
#
# Usage:
#   mix run designs/hello_board/build.exs
#   mix run designs/hello_board/build.exs --flash
#
# Requires:
#   yosys, nextpnr-ecp5, ecppack, fujprog on PATH

defmodule HelloBoard.Build do
  @build_dir "designs/hello_board/build"
  @top_module HelloBoard.Top

  # All modules that need to be emitted into the Verilog file, in dependency order.
  # The synthesizer needs them all in one file (or separate files — yosys handles both).
  @modules [
    HelloBoard.Top
  ]

  @lpf_file "lib/hw/boards/ulx3s/ulx3s_v20_nextpnr.lpf"
  @top_name "hello_board_top"

  def run(args) do
    flash? = "--flash" in args
    File.mkdir_p!(@build_dir)

    verilog_file = Path.join(@build_dir, "#{@top_name}.v")
    json_file    = Path.join(@build_dir, "#{@top_name}.json")
    config_file  = Path.join(@build_dir, "#{@top_name}.config")
    bit_file     = Path.join(@build_dir, "#{@top_name}.bit")

    IO.puts("==> Elaborating and emitting Verilog...")
    Hw.to_file!(@modules, verilog_file)
    IO.puts("    #{verilog_file}")

    IO.puts("==> Synthesizing with Yosys...")
    top = @top_module |> Module.split() |> List.last() |> Macro.underscore()
    cmd!("yosys -p \"read_verilog -sv #{verilog_file}; synth_ecp5 -top #{top} -json #{json_file}\"")

    # Emit design-specific clock frequency constraints.
    # Policy: skip any clock already constrained by the board LPF via
    # FREQUENCY PORT — those are external pins whose frequency is the
    # board's concern. Only emit FREQUENCY NET for internal nets (PLL
    # outputs etc.) that the board LPF knows nothing about.
    clocks_lpf_file = Path.join(@build_dir, "#{@top_name}_clocks.lpf")
    board_lpf_ports =
      File.read!(@lpf_file)
      |> String.split("\n")
      |> Enum.flat_map(fn line ->
        case Regex.run(~r/^FREQUENCY PORT \"([^\"]+)\"/, line) do
          [_, name] -> [String.to_atom(name)]
          nil -> []
        end
      end)
      |> MapSet.new()
    clock_constraints =
      @top_module.__hw_clocks__()
      |> Enum.filter(& &1.freq_mhz)
      |> Enum.reject(fn clk -> MapSet.member?(board_lpf_ports, clk.name) end)
      |> Enum.map(fn clk -> "FREQUENCY NET \"#{clk.name}\" #{clk.freq_mhz} MHZ;" end)
      |> Enum.join("\n")
    File.write!(clocks_lpf_file, clock_constraints <> "\n")

    # Emit design-specific LPF patches from pullmode annotations on inout ports.
    # These override the board LPF — nextpnr applies LPF files in order, last wins.
    patch_lpf_file = Path.join(@build_dir, "#{@top_name}_patch.lpf")
    pullmode_overrides =
      @top_module.__hw_signals__()
      |> Enum.filter(fn sig ->
        Map.get(sig, :direction) == :inout and
        Map.get(sig, :pullmode, :none) != :none
      end)
      |> Enum.map(fn sig ->
        pullmode_str = sig.pullmode |> Atom.to_string() |> String.upcase()
        ~s(IOBUF PORT "#{sig.name}" PULLMODE=#{pullmode_str} IO_TYPE=LVCMOS33 DRIVE=4;)
      end)
      |> Enum.join("\n")
    File.write!(patch_lpf_file, pullmode_overrides <> "\n")

    IO.puts("==> Place and route with nextpnr-ecp5...")
    cmd!("nextpnr-ecp5 --85k --package CABGA381 --json #{json_file} --lpf #{@lpf_file} --lpf #{clocks_lpf_file} --lpf #{patch_lpf_file} --textcfg #{config_file}")

    IO.puts("==> Packing bitstream with ecppack...")
    cmd!("ecppack #{config_file} #{bit_file}")

    IO.puts("==> Done: #{bit_file}")

    if flash? do
      IO.puts("==> Flashing to SPI flash with fujprog (persistent)...")
      cmd!("fujprog -j FLASH #{bit_file}")
    else
      IO.puts("==> Loading to SRAM with fujprog (volatile)...")
      cmd!("fujprog #{bit_file}")
    end
  end

  defp cmd!(command) do
    case System.shell(command) do
      {_, 0} -> :ok
      {output, code} ->
        IO.puts(output)
        raise "Command failed (exit #{code}): #{command}"
    end
  end
end

HelloBoard.Build.run(System.argv())
