#!/usr/bin/env elixir
# designs/pipeline_bringup/build.exs
#
# Usage:
#   mix run designs/pipeline_bringup/build.exs               # build + load to SRAM (volatile)
#   mix run designs/pipeline_bringup/build.exs --flash       # build + write SPI flash (persistent)
#   mix run designs/pipeline_bringup/build.exs --build-only  # build the .bit only, don't touch the board
#
# Requires: yosys, nextpnr-ecp5, ecppack, fujprog on PATH.
# Reuses the stock ULX3S board LPF — the top-level port names (clk_25mhz,
# ftdi_rxd, led) match its COMP names, so no design-specific pin file.

defmodule PipelineBringup.Build do
  @build_dir "designs/pipeline_bringup/build"
  @top_module PipelineBringup.Top
  @modules [PipelineBringup.Top]
  @lpf_file "lib/hw/boards/ulx3s/ulx3s_v20_nextpnr.lpf"
  @top_name "pipeline_bringup"

  def run(args) do
    flash?      = "--flash" in args
    build_only? = "--build-only" in args
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

    # Internal PLL-output clocks aren't known to the board LPF; emit FREQUENCY NET
    # for any design clock not already pinned by a FREQUENCY PORT in the board LPF.
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

    IO.puts("==> Place and route with nextpnr-ecp5...")
    cmd!("nextpnr-ecp5 --85k --package CABGA381 --json #{json_file} --lpf #{@lpf_file} --lpf #{clocks_lpf_file} --textcfg #{config_file}")

    IO.puts("==> Packing bitstream with ecppack...")
    cmd!("ecppack #{config_file} #{bit_file}")

    IO.puts("==> Done: #{bit_file}")

    cond do
      build_only? ->
        IO.puts("==> --build-only: bitstream ready, board not touched.")

      flash? ->
        IO.puts("==> Flashing to SPI flash with fujprog (persistent)...")
        cmd!("fujprog -j FLASH #{bit_file}")

      true ->
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

PipelineBringup.Build.run(System.argv())
