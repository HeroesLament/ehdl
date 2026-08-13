#!/usr/bin/env elixir
# designs/libresdr_bringup/build.exs
#
# Elixir -> Verilog -> bitstream for the LibreSDR (Zynq-7020) using openXC7.
# No Vivado anywhere in this path.
#
#   mix run designs/libresdr_bringup/build.exs
#   mix run designs/libresdr_bringup/build.exs --keep-intermediate
#
# Requires on PATH:
#   yosys            (with synth_xilinx)
#   nextpnr-xilinx
#   fasm2frames      (prjxray / openXC7 utils)
#   xc7frames2bit
#
# Requires in the environment:
#   PRJXRAY_DB   path to a checkout of openXC7/prjxray-db  (NOT f4pga/prjxray-db,
#                whose master has been frozen since 2021)
#   XC7_CHIPDB   path to the directory holding xc7z020.bin, the nextpnr chipdb
#                built by bbaexport.py + bbasm
#
# The final artifact is top.bin, NOT top.bit — see Bit2Bin below for why.

defmodule LibreSDRBringup.Build do
  @build_dir "designs/libresdr_bringup/build"
  @top_module LibreSDRBringup.Top
  @top_name "libresdr_bringup"

  # xc7z020clg400-1 is the LibreSDR's part. Speed grade matters to nextpnr's
  # timing model, not to bitstream framing.
  @part "xc7z020clg400-1"
  @device "xc7z020"

  # FCLK_CLK0 is programmed by ps7_init, not by the bitstream. 50 MHz is a
  # conservative target: openXC7's timing-driven placement is the weakest part
  # of the flow, so leave margin rather than chase Fmax.
  @clock_mhz 50

  def run(args) do
    keep? = "--keep-intermediate" in args
    File.mkdir_p!(@build_dir)

    v     = path("#{@top_name}.v")
    json  = path("#{@top_name}.json")
    fasm  = path("#{@top_name}.fasm")
    frames = path("#{@top_name}.frames")
    bit   = path("#{@top_name}.bit")
    bin   = path("#{@top_name}.bin")

    db = fetch_env!("PRJXRAY_DB")
    chipdb = fetch_env!("XC7_CHIPDB")

    IO.puts("==> Elaborating #{inspect(@top_module)}...")
    Hw.to_file!([@top_module], v)
    IO.puts("    #{v}")

    IO.puts("==> Synthesizing (yosys, synth_xilinx)...")
    # -flatten so nextpnr sees one netlist; the PS7 and BUFG stay as blackboxes
    # because nothing defines them, which is exactly what we want.
    cmd!("""
    yosys -p "read_verilog -sv #{v}; \
              synth_xilinx -flatten -family xc7 -top top; \
              write_json #{json}"
    """)

    IO.puts("==> Place & route (nextpnr-xilinx)...")
    # No --xdc: this design has no package pins. Everything it touches is
    # inside the PS7 hard macro, which nextpnr pre-places at its single fixed
    # site. A pin constraint file would have nothing to say.
    cmd!("""
    nextpnr-xilinx --chipdb #{Path.join(chipdb, "#{@device}.bin")} \
      --json #{json} \
      --fasm #{fasm} \
      --freq #{@clock_mhz} \
      --verbose
    """)

    IO.puts("==> FASM -> frames...")
    cmd!("fasm2frames --part #{@part} --db-root #{Path.join(db, "zynq7")} #{fasm} > #{frames}")

    IO.puts("==> frames -> .bit...")
    cmd!("""
    xc7frames2bit --part_file #{Path.join([db, "zynq7", @part, "part.yaml"])} \
      --part_name #{@part} \
      --frm_file #{frames} \
      --output_file #{bit}
    """)

    IO.puts("==> .bit -> .bin (header strip + byte swap)...")
    Hw.Xilinx.Bit2Bin.convert!(bit, bin)

    unless keep? do
      Enum.each([json, fasm, frames], &File.rm/1)
    end

    IO.puts("""

    Built #{bin} (#{File.stat!(bin).size} bytes)

    To load on the target:

        File.cp!("#{Path.basename(bin)}", "/lib/firmware/#{Path.basename(bin)}")
        File.write!("/sys/class/fpga_manager/fpga0/firmware", "#{Path.basename(bin)}")
        File.read!("/sys/class/fpga_manager/fpga0/state")   # must read "operating"

    Do NOT read 0x40000000 until state reads "operating". The Zynq AXI
    interconnect has no timeout: a read into unconfigured PL hangs the CPU
    with no oops and no recovery short of a power cycle.
    """)
  end

  defp path(f), do: Path.join(@build_dir, f)

  defp fetch_env!(name) do
    System.get_env(name) ||
      raise """
      #{name} is not set.

      PRJXRAY_DB should point at a checkout of https://github.com/openxc7/prjxray-db
      XC7_CHIPDB should point at a directory containing #{@device}.bin

      Note: use openXC7's prjxray-db fork. f4pga/prjxray-db has been frozen
      since 2021-12 and lacks the Zynq work this depends on.
      """
  end

  defp cmd!(command) do
    case System.shell(command, into: IO.stream(:stdio, :line), stderr_to_stdout: true) do
      {_, 0} -> :ok
      {_, code} -> raise "command failed (exit #{code}): #{String.trim(command)}"
    end
  end
end

LibreSDRBringup.Build.run(System.argv())
