#!/usr/bin/env elixir
# designs/libresdr_radio/build.exs
#
# Elixir -> Verilog -> bitstream for the LibreSDR radio top. No Vivado.
#
#   mix run designs/libresdr_radio/build.exs --seed 25      # known-good seed
#   mix run designs/libresdr_radio/build.exs --sweep 0..400 # find one
#   mix run designs/libresdr_radio/build.exs --sweep 0..400 --keep-going
#
# Why a sweep is a first-class option rather than a note in a handoff: routing
# this design is seed-dependent and the dependence is brutal. Of 377 seeds tried
# on the previous revision, exactly one (25) produced a routed design. That is
# not a tuning knob, it is a coin flip you have to script, and doing it by hand
# in a shell is how the last build ended up unreproducible.
#
# Requires on PATH:  yosys, nextpnr-xilinx, fasm2frames, xc7frames2bit
# Requires in env:   PRJXRAY_DB (openXC7 fork, NOT f4pga), XC7_CHIPDB

defmodule LibreSDRRadio.Build do
  @build_dir "designs/libresdr_radio/build"
  @top_module LibreSDRRadio.Top
  @top_name "libresdr_radio"
  @xdc "designs/libresdr_radio/libresdr.xdc"

  @part "xc7z020clg400-1"
  @device "xc7z020"
  @clock_mhz 50

  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [seed: :integer, sweep: :string, keep_going: :boolean, skip_synth: :boolean]
      )

    File.mkdir_p!(@build_dir)

    db = fetch_env!("PRJXRAY_DB")
    chipdb = fetch_env!("XC7_CHIPDB")

    v = path("#{@top_name}.v")
    json = path("#{@top_name}.json")

    unless opts[:skip_synth] do
      IO.puts("==> Elaborating #{inspect(@top_module)}...")
      Hw.to_file!([@top_module], v)

      IO.puts("==> Synthesizing (yosys)...")
      # -abc9 is NOT optional, and its absence is invisible until place & route.
      # Without it yosys leaves bare INV cells in the netlist instead of folding
      # the inversions into LUT init masks: 184 of them for this design against
      # 3 with it. nextpnr then fails to route, in SLICE set/reset muxing, on
      # every seed -- 755 were tried before the cause was found. The tell is that
      # re-synthesising a netlist known to have routed reproduces the inverters,
      # which localises the fault to the synthesis command rather than the design.
      #
      # -nocarry: nextpnr-xilinx's CARRY4 support does not survive this design.
      # Re-checked -- enabling CARRY4 saves ~90 LUTs but adds ~160 inverters.
      # `dffunmap` spliced in before FF mapping is what makes this design
      # routable AT ALL, and it is not an optimisation -- it is a workaround for
      # a nextpnr-xilinx defect.
      #
      # nextpnr cannot route nets into SLICE clock-enable pins at any scale.
      # Measured on a 252-FF test occupying 0.24% of the device
      # (see ehdl/_cetest/): distinct SR nets route 3/3 at 1, 2 and 4 nets, while
      # CE nets route 2/3, 1/3 and 0/3 at 1, 2 and 4. Every failure is
      # "Failed to route arc ... to SITEWIRE/SLICE_.../CEUSEDMUX_OUT". The only
      # bitstream this project ever routed had zero CE pins, which is why it
      # worked and why 755 subsequent seeds did not.
      #
      # `dffunmap` pushes the enable back out of the FF and into D-side logic
      # after yosys has finished inferring it. Doing the same thing in RTL does
      # NOT work -- `q <= ce ? d : q` is re-inferred straight back into an FDRE
      # with a real CE. On the reproducer this takes routing from 0/3 to 3/3 and
      # costs one LUT (339 -> 338), because the mux collapses into the existing
      # D-side LUT.
      #
      # Remove this when nextpnr-xilinx learns to route CE pins.
      cmd!("""
      yosys -p "read_verilog -sv #{v}; \
                synth_xilinx -flatten -nocarry -abc9 -family xc7 -top top -run begin:map_ffs; \
                dffunmap; \
                synth_xilinx -flatten -nocarry -abc9 -family xc7 -top top -run map_ffs:; \
                write_json #{json}"
      """)
    end

    seeds =
      cond do
        opts[:seed] -> [opts[:seed]]
        opts[:sweep] -> parse_range(opts[:sweep])
        true -> [25]
      end

    IO.puts("==> Place & route over #{length(seeds)} seed(s)...")

    case attempt(seeds, json, chipdb, db, opts[:keep_going]) do
      {:ok, seed, fasm} ->
        finish(seed, fasm, db)

      :none ->
        IO.puts("\nNo seed routed. Widen the sweep, or reduce the design.")
        System.halt(1)
    end
  end

  defp attempt([], _json, _chipdb, _db, _kg), do: :none

  defp attempt([seed | rest], json, chipdb, db, kg) do
    fasm = path("#{@top_name}_s#{seed}.fasm")
    log = path("pnr_s#{seed}.log")

    IO.write("    seed #{seed} ... ")

    cmd =
      """
      nextpnr-xilinx --chipdb #{Path.join(chipdb, "#{@device}.bin")} \
        --xdc #{@xdc} \
        --json #{json} \
        --fasm #{fasm} \
        --freq #{@clock_mhz} \
        --seed #{seed} \
        --verbose > #{log} 2>&1
      """

    case System.shell(cmd) do
      {_, 0} ->
        IO.puts("routed")
        {:ok, seed, fasm}

      {_, code} ->
        IO.puts("failed (#{code}) -- #{log}")
        File.rm(fasm)
        attempt(rest, json, chipdb, db, kg)
    end
  end

  defp finish(seed, fasm, db) do
    frames = path("#{@top_name}.frames")
    bit = path("#{@top_name}.bit")
    bin = path("#{@top_name}.bin")

    IO.puts("==> FASM -> frames...")
    cmd!("fasm2frames --part #{@part} --db-root #{Path.join(db, "zynq7")} #{fasm} > #{frames}")

    IO.puts("==> frames -> .bit...")
    cmd!("""
    xc7frames2bit --part_file #{Path.join([db, "zynq7", @part, "part.yaml"])} \
      --part_name #{@part} \
      --frm_file #{frames} \
      --output_file #{bit}
    """)

    IO.puts("==> .bit -> .bin...")
    Hw.Xilinx.Bit2Bin.convert!(bit, bin)

    File.write!(path("winning_seed.txt"), "#{seed}\n")

    IO.puts("""

    Built #{bin} (#{File.stat!(bin).size} bytes) with seed #{seed}.
    Seed recorded in #{path("winning_seed.txt")} -- pass --seed #{seed} to rebuild.

    To load on the target:

        File.cp!("#{Path.basename(bin)}", "/lib/firmware/#{Path.basename(bin)}")
        File.write!("/sys/class/fpga_manager/fpga0/firmware", "#{Path.basename(bin)}")
        File.read!("/sys/class/fpga_manager/fpga0/state")   # must read "operating"

    Do NOT read 0x40000000 until state reads "operating": the Zynq AXI
    interconnect has no timeout, and a read into unconfigured PL hangs the CPU
    with no oops and no recovery short of a power cycle.
    """)
  end

  defp parse_range(s) do
    case String.split(s, "..") do
      [a, b] -> String.to_integer(a)..String.to_integer(b) |> Enum.to_list()
      [a] -> [String.to_integer(a)]
    end
  end

  defp path(f), do: Path.join(@build_dir, f)

  defp fetch_env!(name) do
    System.get_env(name) ||
      raise "#{name} is not set. PRJXRAY_DB -> openxc7/prjxray-db checkout; XC7_CHIPDB -> dir with #{@device}.bin"
  end

  defp cmd!(command) do
    case System.shell(command, into: IO.stream(:stdio, :line), stderr_to_stdout: true) do
      {_, 0} -> :ok
      {_, code} -> raise "command failed (exit #{code}): #{String.trim(command)}"
    end
  end
end

LibreSDRRadio.Build.run(System.argv())
