defmodule PlLoad do
  @moduledoc """
  Program the PL with the FULL Xilinx sequence, and check the cheap things first.

  ## Why this exists

  `Nervezynq.PL.reload/1` runs the devcfg loader and nothing else. That worked
  for the entire life of this project because the PL was ALREADY configured at
  boot -- `libresdr.bit` sat on the SD card's boot partition and U-Boot loaded
  it. Every `reload/1` therefore replaced one working design with another, and
  the AXI slave was never observed coming up from unconfigured.

  Removing that bitstream fixed a U-Boot boot hang. It also means the PL is now
  unconfigured at boot, and the first runtime load is the first time the fabric
  has ever come up without U-Boot's help. Since then, the first
  `Fabric.read32/1` after a load has hard-locked the board three times.

  A hard lock here is total: an AXI read with no responder never returns on
  Zynq. No error, no timeout, no fault. The core wedges, Linux stops, the board
  drops off the network with no console and no crash dump. It costs a power
  cycle every time, so this module is built to spend as few of them as possible.

  ## What was ruled out first, by measurement

      SLCR 0xF8000900  LVL_SHFTR_EN   0x0000000F   already enabled at boot
      SLCR 0xF8000240  FPGA_RST_CTRL  0x00000000   already released at boot

  The FSBL in `BOOT.BIN` sets both. They were never the problem, and writing
  them again changed nothing.

  ## What this does differently

  Xilinx's sequence BRACKETS the load. This project only ever did step 3:

      1. LVL_SHFTR_EN   <- 0          isolate the PS from the PL
      2. FPGA_RST_CTRL  <- 0xF        assert the AXI interface resets
      3. program through devcfg
      4. LVL_SHFTR_EN   <- 0xA, 0xF   re-enable, in that order
      5. FPGA_RST_CTRL  <- 0          release the AXI resets

  Step 2 matters most and is the easiest to get wrong: `FPGA_RST_CTRL` needs a
  **pulse**, not a level. It already reads 0, so writing 0 is a no-op. It has to
  go 0xF and then back to 0 around the load, or the slave is never reset while
  isolated.

  ## Read before you touch

  `preflight/0` reads only SLCR and devcfg. Both are PS-side and CANNOT hang.
  The fabric is the one thing that can, so it is the last probe, never the
  first. Three power cycles were spent learning that.
  """

  import Bitwise

  alias Nervezynq.{Fabric, SLCR}

  @lvl_shftr_en 0x900
  @fpga_rst_ctrl 0x240

  # devcfg INT_STS, bit 2 = PCFG_DONE
  @devcfg_int_sts 0x0C
  @pcfg_done 1 <<< 2

  @doc """
  Everything worth knowing before risking a fabric access. Cannot hang.

  `fclk0` is the one to look at hardest: the PL's AXI slave is clocked by FCLK0,
  and a slave with no clock cannot complete a transaction. The symptom of a
  stopped FCLK0 is identical to an absent slave -- a read that never returns --
  so it has to be excluded from the register file rather than by experiment.
  Measured truth for this board is **99.99 MHz**; `SLCR.calibrate/1` exists
  precisely to prove that decode against silicon.
  """
  def preflight do
    ensure_slcr()

    %{
      lvl_shftr: hex(rd(@lvl_shftr_en)),
      fpga_rst: hex(rd(@fpga_rst_ctrl)),
      fclk0: safe(fn -> SLCR.fclk_hz(0) |> Map.take([:mhz, :hz]) end),
      fclk0_ctrl: safe(fn -> SLCR.fclk_ctrl(0) end),
      pcfg_done: pcfg_done?()
    }
  end

  @doc """
  Is the PL configured? devcfg only -- PS-side, safe.

  Uses `SiliconSweep.Devcfg` if it happens to be running, so this works whether
  or not the sweep harness has been started.
  """
  def pcfg_done? do
    case safe(fn -> SiliconSweep.Devcfg.read32(@devcfg_int_sts) end) do
      {:ok, v} -> (v &&& @pcfg_done) != 0
      other -> {:unknown, other}
    end
  end

  @doc """
  Load `path` with the full bracketed sequence.

  Does NOT touch the fabric afterwards. Call `verify/0` separately, once you
  have looked at what this returned -- keeping the load and the first fabric
  access as two decisions rather than one is the whole point.
  """
  def load(path) do
    ensure_slcr()
    {:ok, loader} = loader_path()

    before = preflight()

    # Gate the fabric before the PL changes underneath it. If anything below
    # raises, the fabric stays gated, which is the safe direction.
    _ = safe(fn -> Fabric.invalidate() end)

    SLCR.unlock()
    # 1. isolate
    SLCR.write32(@lvl_shftr_en, 0x0000_0000)
    # 2. assert the AXI resets -- a PULSE; this is the step that was missing
    SLCR.write32(@fpga_rst_ctrl, 0x0000_000F)
    SLCR.lock()

    # 3. program
    result = System.cmd(loader, [path], stderr_to_stdout: true)

    SLCR.unlock()
    # 4. re-enable the level shifters, 0xA before 0xF
    SLCR.write32(@lvl_shftr_en, 0x0000_000A)
    SLCR.write32(@lvl_shftr_en, 0x0000_000F)
    # 5. release the AXI resets
    SLCR.write32(@fpga_rst_ctrl, 0x0000_0000)
    SLCR.lock()

    # Let the fabric's reset propagate before anyone is allowed near the bus.
    Process.sleep(100)

    %{
      loader: result,
      ok?: match?({_, 0}, result),
      before: before,
      after: preflight()
    }
  end

  @doc """
  The first fabric access, deliberately separated from `load/1`.

  If this hangs, the board is gone and the answer is "the slave still does not
  respond after a correct programming sequence" -- which is worth knowing, but
  costs a power cycle, so read `load/1`'s return value first and only call this
  when `pcfg_done` is true and `fclk0` looks sane.
  """
  def verify do
    _ = safe(fn -> Fabric.authorise() end)

    case safe(fn -> Fabric.read32(0x00) end) do
      {:ok, 0x4548_4431} = ok -> %{magic: ok, magic_ok: true}
      other -> %{magic: other, magic_ok: false}
    end
  end

  defp ensure_slcr do
    case Process.whereis(SLCR) do
      nil -> SLCR.start_link()
      pid -> {:ok, pid}
    end
  end

  defp rd(off) do
    case SLCR.read32(off) do
      {:ok, v} -> v
      _ -> :error
    end
  end

  defp loader_path do
    [Path.join(:code.priv_dir(:nervezynq), "devcfg_load"), "/root/devcfg_load"]
    |> Enum.find(&File.exists?/1)
    |> case do
      nil -> {:error, :loader_not_found}
      p -> {:ok, p}
    end
  end

  defp hex(v) when is_integer(v), do: "0x" <> String.pad_leading(Integer.to_string(v, 16), 8, "0")
  defp hex(v), do: v

  defp safe(f) do
    try do
      f.()
    catch
      k, e -> {:caught, k, e}
    end
  end
end
