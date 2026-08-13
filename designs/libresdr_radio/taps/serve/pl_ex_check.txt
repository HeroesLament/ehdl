defmodule Nervezynq.PL do
  @moduledoc """
  Reconfigure the programmable logic at runtime, safely.

  This is the only sanctioned way to load a bitstream while Linux is running.
  It wraps `devcfg_load`, which drives the Zynq DevC/PCAP block directly — see
  `native/fabric/src/devcfg.rs` for why none of the kernel's own paths are
  usable on this build.

  ## The whole point of this module is the ordering

      Fabric.invalidate()      # bus access blocked
      devcfg_load ...          # PROG_B wipes the PL, then programs it
      Fabric.authorise()       # ONLY if devcfg_load exited 0

  `PROG_B` erases the running design before the first byte of the replacement
  arrives. So a load is not an atomic swap and a failure is not a no-op: any
  error after that point leaves the PL configured with nothing. Reading the AXI
  aperture in that state does not return garbage and does not fault — the Zynq
  interconnect has no timeout, so it hangs the CPU outright, with no oops and no
  recovery short of a power cycle.

  Nothing in software can make that access safe. The only defence is not issuing
  it, which is why `authorise/0` is called on exactly one condition: the loader
  observed `PCFG_DONE` in the DevC interrupt status and exited 0. That is
  hardware's own report that configuration completed.

  `/sys/class/fpga_manager/fpga0/state` is deliberately not consulted here. It
  reports the kernel driver's last operation and is untouched by a userspace
  load, so it happily reads `operating` over a blank PL. Trusting it is what
  cost a power cycle the first time this ran.

  ## After a failure

  `reload/1` returning `{:error, {:pl_unconfigured, ...}}` leaves the bus blocked
  and the PL blank. Every `Fabric` call will answer `{:error, :pl_unconfigured}`
  rather than hanging. The recovery is a reboot, which restores whatever u-boot
  loads from the boot partition — the reason `devcfg_load` never writes there.
  """

  require Logger
  alias Nervezynq.Fabric

  @doc """
  Load `bin_path` into the PL.

  The file must be a byte-swapped `.bin` (see `Hw.Xilinx.Bit2Bin`), not a
  `.bit`; the loader checks for the swapped sync word and refuses otherwise,
  because a `.bit` fed to the PCAP configures nothing and looks identical to a
  hardware fault from here.

  Returns `{:ok, %{ms: n}}` or `{:error, reason}`.
  """
  @spec reload(Path.t()) :: {:ok, map()} | {:error, term()}
  def reload(bin_path) do
    with :ok <- check_exists(bin_path),
         {:ok, loader} <- loader_path() do
      :ok = Fabric.invalidate()

      case System.cmd(loader, [bin_path], stderr_to_stdout: true) do
        {out, 0} ->
          :ok = Fabric.authorise()
          Logger.info("[pl] reconfigured from #{bin_path}: #{String.trim(out)}")
          {:ok, %{output: String.trim(out), ms: parse_ms(out)}}

        {out, rc} ->
          # Deliberately no Fabric.authorise/0 and no retry. The PL is blank and
          # the bus stays blocked until a reboot or a load that actually works.
          Logger.error(
            "[pl] reconfiguration FAILED (rc=#{rc}): #{String.trim(out)} — " <>
              "PL is blank, bus access blocked, reboot to recover"
          )

          {:error, {:pl_unconfigured, rc, String.trim(out)}}
      end
    end
  end

  # REMOVED: enable_ps_pl_interfaces/0 and its SLCR register constants.
  #
  # It was written on the theory that the PS-PL level shifters and
  # FPGA_RST_CTRL were left isolated after a devcfg load, and that this was why
  # the first fabric access hard-locked the board. That theory is disproven by
  # measurement -- both registers are ALREADY correct at boot, set by the FSBL
  # in BOOT.BIN:
  #
  #     SLCR 0xF8000900  LVL_SHFTR_EN   0x0000000F
  #     SLCR 0xF8000240  FPGA_RST_CTRL  0x00000000
  #
  # Writing them again changed nothing. The function was also broken on its own
  # terms: under CONFIG_STRICT_DEVMEM, :file.pwrite on /dev/mem returns
  # {:error, :efault} for non-RAM physical addresses, so the `:ok = ` match
  # raised -- and it raised from inside reload/1 AFTER Fabric.invalidate/0 and
  # BEFORE Fabric.authorise/0, leaving the fabric gated off with no way back.
  #
  # If a reason to bracket a load ever appears, do it through Nervezynq.SLCR
  # (which maps rather than pwrites) -- PlLoad.load/1 in the ehdl tree already
  # implements the full Xilinx bracket that way.

  @doc """
  Reload and then prove the fabric answers, in one step.

  Reads the magic word and two heartbeat samples. A correct magic says the right
  bitstream is loaded and the AXI slave is decoding; two differing heartbeats say
  the fabric clock is actually running. Those are separate claims with separate
  failure modes, and a design can satisfy the first while failing the second.

  Safe to call because it only reads after `reload/1` has authorised the bus.
  """
  @spec reload_and_verify(Path.t()) :: {:ok, map()} | {:error, term()}
  def reload_and_verify(bin_path) do
    with {:ok, info} <- reload(bin_path),
         # 0x00 is the fixed ID word, deliberately outside the register map:
         # it must be readable before any map is trusted.
         {:ok, magic} <- Fabric.read32(0x00) do
      hb1 = Nervezynq.Regs.heartbeat()
      Process.sleep(50)
      hb2 = Nervezynq.Regs.heartbeat()

      {:ok,
       Map.merge(info, %{
         magic: magic,
         magic_ok: magic == 0x4548_4431,
         heartbeat_running: hb2 != hb1
       })}
    end
  end

  defp check_exists(path) do
    if File.exists?(path), do: :ok, else: {:error, {:enoent, path}}
  end

  # priv/ once baked into the firmware; /root while iterating with scp.
  defp loader_path() do
    candidates = [
      Path.join(:code.priv_dir(:nervezynq), "devcfg_load"),
      "/root/devcfg_load"
    ]

    case Enum.find(candidates, &File.exists?/1) do
      nil -> {:error, {:loader_not_found, candidates}}
      path -> {:ok, path}
    end
  end

  defp parse_ms(out) do
    case Regex.run(~r/ok (\d+) ms/, out) do
      [_, n] -> String.to_integer(n)
      _ -> nil
    end
  end
end
