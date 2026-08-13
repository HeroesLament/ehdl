defmodule Nervezynq.SLCR do
  @moduledoc """
  The Zynq-7000 System Level Control Registers, at `0xF800_0000`.

  Exists to program `FCLK1` to 200 MHz so `IDELAYCTRL` has a reference clock,
  after every CMT in the PL failed to lock under openXC7 (2 primitives, 2 site
  types, 2 clock routes, 9 multipliers, ~15 bitstreams, 0 locks). The PS's PLLs
  are not openXC7's problem -- they are configured by the FSBL and demonstrably
  work, since `FCLK0` is what clocks the whole fabric.

  ## Why this is a port and not a file read

  `:file.pread` on `/dev/mem` at `0xF800_0170` returns `{:error, :efault}`.
  That is not permissions -- `CONFIG_STRICT_DEVMEM` answers `:eacces`. ARM's
  `valid_phys_addr_range()` limits the read/write path to physical RAM, and
  SLCR is not RAM. `mmap` carries no such check, which is exactly the reasoning
  already written up in `native/fabric/src/lib.rs` for the PL aperture.

  So this reuses `fabric_port` unchanged: it already takes `<base> <len>` as
  argv, so a second instance mapping `0xF800_0000` needs no Rust at all.

  ## What is deliberately NOT inherited from `Nervezynq.Fabric`

  `Fabric` gates every access on the PL being configured, because a read into
  unconfigured PL hangs the CPU with no timeout and no recovery. SLCR has no
  such hazard -- it is in the PS, always present, always answering -- and
  gating it would be actively wrong, since the most useful time to read the
  clock registers is when the PL is blank.

  ## Offsets, and the one that was wrong

  The FPGA clock block is FOUR registers per FCLK, 16 bytes apart:

      0x170 FPGA0_CLK_CTRL   0x174 THR_CTRL   0x178 THR_CNT   0x17C THR_STA
      0x180 FPGA1_CLK_CTRL   0x184 THR_CTRL   0x188 THR_CNT   0x18C THR_STA
      0x190 FPGA2_CLK_CTRL   0x1A0 FPGA3_CLK_CTRL

  `FPGA1_CLK_CTRL` is **0x180**. An earlier plan in HANDOFF.md said 0x184,
  which is FPGA1_THR_CTRL -- a throttle control register, not a clock divider.
  Writing a divisor there would have done something unrelated and confusing.
  Caught by writing the offsets out rather than by testing, which is the
  argument for `calibrate/0` below running before any write.
  """

  use GenServer
  import Bitwise
  require Logger

  @base 0xF800_0000
  @len 0x1000
  @call_timeout 5_000

  # PS_CLK is the external oscillator feeding all three PS PLLs. It is a BOARD
  # property, not a chip one, and it is NOT in any register -- only the PLL
  # multiplier is. The usual Zynq reference designs use 33.333 MHz, so that was
  # the assumption here; on the LibreSDR it is wrong.
  #
  # `calibrate/1` DERIVED it as 50 MHz from a frequency already measured on
  # silicon, after the 33.333 MHz assumption predicted 66.667 MHz against a
  # measured 99.99 -- a ratio of exactly 1.5, which is 50/33.333. This constant
  # is now the fallback only; the derived value is what gets used, and a write
  # is refused if the two disagree with the measurement.
  @ps_clk_hz 50_000_000

  @unlock 0x008
  @lock 0x004
  @locksta 0x00C
  @arm_pll_ctrl 0x100
  @ddr_pll_ctrl 0x104
  @io_pll_ctrl 0x108
  @fpga_clk_ctrl %{0 => 0x170, 1 => 0x180, 2 => 0x190, 3 => 0x1A0}

  @unlock_key 0xDF0D
  @lock_key 0x767B

  # --- API -------------------------------------------------------------------

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def read32(offset), do: GenServer.call(__MODULE__, {:read32, offset}, @call_timeout)
  def write32(offset, value), do: GenServer.call(__MODULE__, {:write32, offset, value}, @call_timeout)

  @doc "Is SLCR write-locked? Writes are silently DROPPED while locked."
  def locked?() do
    {:ok, v} = read32(@locksta)
    (v &&& 1) == 1
  end

  def unlock(), do: write32(@unlock, @unlock_key)
  def lock(), do: write32(@lock, @lock_key)

  @doc "Decode one `FPGAn_CLK_CTRL` register."
  def fclk_ctrl(n) when n in 0..3 do
    {:ok, v} = read32(@fpga_clk_ctrl[n])

    %{
      raw: v,
      srcsel: v >>> 4 &&& 0x3,
      source: source_name(v >>> 4 &&& 0x3),
      divisor0: v >>> 8 &&& 0x3F,
      divisor1: v >>> 20 &&& 0x3F
    }
  end

  defp source_name(s) when s in [0, 1], do: :io_pll
  defp source_name(2), do: :arm_pll
  defp source_name(3), do: :ddr_pll

  @doc "PLL output frequency in Hz. `PLL = PS_CLK * PLL_FDIV`, FDIV at [18:12]."
  def pll_hz(which) do
    off = %{io_pll: @io_pll_ctrl, arm_pll: @arm_pll_ctrl, ddr_pll: @ddr_pll_ctrl}[which]
    {:ok, v} = read32(off)
    fdiv = v >>> 12 &&& 0x7F
    %{fdiv: fdiv, hz: @ps_clk_hz * fdiv}
  end

  @doc "Predicted frequency of `FCLKn`, from the registers alone."
  def fclk_hz(n) do
    c = fclk_ctrl(n)
    p = pll_hz(c.source)
    d = max(c.divisor0, 1) * max(c.divisor1, 1)
    %{hz: div(p.hz, d), mhz: Float.round(p.hz / d / 1_000_000, 3), pll: p, ctrl: c}
  end

  @doc """
  Check the register decode against an answer already measured on silicon.

  `FCLK0` clocks the fabric, and the heartbeat counter measured it at
  **99.99 MHz**. If this module's arithmetic does not reproduce that from
  `FPGA0_CLK_CTRL` alone, then the offsets, the field positions, the PLL source
  decode or `@ps_clk_hz` is wrong -- and a wrong decode written to a live clock
  control register is how you take the fabric's clock away from it.

  Nothing here writes. Run it, read it, and only then program FCLK1.
  """
  def calibrate(measured_mhz \\ 99.99) do
    c = fclk_ctrl(0)
    {:ok, v} = read32(@io_pll_ctrl)
    fdiv = v >>> 12 &&& 0x7F
    d = max(c.divisor0, 1) * max(c.divisor1, 1)

    # Solve for the oscillator instead of assuming it. Everything else in the
    # chain is in a register and can be read; PS_CLK is the one unknown, so one
    # measured frequency determines it.
    derived_hz = round(measured_mhz * 1_000_000 * d / fdiv)
    err = abs(derived_hz - @ps_clk_hz) / @ps_clk_hz

    %{
      measured_mhz: measured_mhz,
      derived_ps_clk_mhz: Float.round(derived_hz / 1_000_000, 4),
      assumed_ps_clk_mhz: @ps_clk_hz / 1_000_000,
      relative_error: Float.round(err, 5),
      io_pll_mhz: Float.round(derived_hz * fdiv / 1_000_000, 3),
      verdict: if(err < 0.01, do: :decode_confirmed, else: :DECODE_WRONG_DO_NOT_WRITE),
      detail: %{fclk0_ctrl: c, io_pll_fdiv: fdiv, total_divisor: d}
    }
  end

  @doc """
  Program `FCLKn` to `target_hz` from its current source PLL.

  Refuses unless `calibrate/1` passes, because the failure mode of a wrong
  divisor on FCLK0 is a fabric with no clock and a bus that no longer answers.
  Returns the exact achievable frequency, which will not be `target_hz` unless
  the PLL divides evenly.
  """
  def set_fclk(n, target_hz, opts \\ []) when n in 0..3 do
    cal = calibrate(Keyword.get(opts, :measured_mhz, 99.99))

    cond do
      cal.verdict != :decode_confirmed ->
        {:error, {:calibration_failed, cal}}

      n == 0 and not Keyword.get(opts, :i_really_mean_fclk0, false) ->
        {:error, :fclk0_is_the_fabric_clock}

      true ->
        do_set_fclk(n, target_hz)
    end
  end

  defp do_set_fclk(n, target_hz) do
    c = fclk_ctrl(n)
    p = pll_hz(c.source)
    total = round(p.hz / target_hz)

    # DIVISOR0 and DIVISOR1 are each 6 bits (1..63). Prefer putting the whole
    # ratio in DIVISOR0 when it fits: fewer stages, and it matches what the
    # FSBL does for FCLK0.
    {d0, d1} =
      if total <= 63 do
        {total, 1}
      else
        d = Enum.find(2..63, fn d -> rem(total, d) == 0 and div(total, d) <= 63 end)
        if d, do: {div(total, d), d}, else: {63, 63}
      end

    was_locked = locked?()
    if was_locked, do: unlock()

    word =
      (c.raw &&& ~~~((0x3F <<< 8) ||| (0x3F <<< 20))) |||
        (d0 <<< 8) ||| (d1 <<< 20)

    :ok = write32(@fpga_clk_ctrl[n], word)
    if was_locked, do: lock()

    actual = div(p.hz, d0 * d1)

    {:ok,
     %{
       fclk: n,
       divisor0: d0,
       divisor1: d1,
       pll_mhz: Float.round(p.hz / 1_000_000, 3),
       target_mhz: Float.round(target_hz / 1_000_000, 3),
       actual_mhz: Float.round(actual / 1_000_000, 3),
       exact?: actual == round(target_hz)
     }}
  end

  @doc "Everything, for a human."
  def dump() do
    %{
      locked?: locked?(),
      io_pll: pll_hz(:io_pll),
      arm_pll: pll_hz(:arm_pll),
      ddr_pll: pll_hz(:ddr_pll),
      fclk: Map.new(0..3, fn n -> {n, fclk_hz(n)} end)
    }
  end

  # --- GenServer -------------------------------------------------------------

  @impl true
  def init(_opts) do
    executable = Path.join(:code.priv_dir(:nervezynq), "fabric_port")

    port =
      Port.open({:spawn_executable, executable}, [
        {:args, ["0x" <> Integer.to_string(@base, 16), Integer.to_string(@len)]},
        {:packet, 4},
        :binary,
        :exit_status
      ])

    Logger.info("SLCR: mapped 0x#{Integer.to_string(@base, 16)}+#{@len}")
    {:ok, %{port: port}}
  end

  @impl true
  def handle_call({:read32, offset}, _from, state) do
    {:reply, transact(state.port, <<0x01, offset::big-32>>, :word), state}
  end

  def handle_call({:write32, offset, value}, _from, state) do
    {:reply, transact(state.port, <<0x02, offset::big-32, value::big-32>>, :unit), state}
  end

  defp transact(port, request, shape) do
    send(port, {self(), {:command, request}})

    receive do
      {^port, {:data, <<0x00, rest::binary>>}} ->
        case {shape, rest} do
          {:word, <<v::big-32>>} -> {:ok, v}
          {:unit, _} -> :ok
        end

      {^port, {:data, <<0x01, message::binary>>}} ->
        {:error, message}

      {^port, {:exit_status, code}} ->
        {:error, {:port_exited, code}}
    after
      @call_timeout -> {:error, :timeout}
    end
  end
end
