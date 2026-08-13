defmodule Confine do
  @moduledoc """
  Does a write to this tile disturb anything outside it?

  `:census` and the mirror both compare only the positions they wrote. That
  cannot see collateral damage, and collateral damage is exactly what would
  invalidate attributing an observed behaviour change to the poked bit.

  Two escapes are possible and this checks both at once by reading a WIDER
  window than the tile:

    * within a frame -- words 49..100 lie outside the CMT's 0..48 window and
      belong to neighbouring tiles that share the baseaddr (HCLK_CMT_L at
      offset 45, INT_L at 48). Section 21 established these windows OVERLAP.
    * across frames  -- minors 30..35 are past the tile's 30 frames entirely.
  """
  import Bitwise

  @host ~c"http://172.31.248.126:8101"
  @wide 36
  @win_lo 0
  @win_hi 48
  @minors [28, 29]

  def get(p, dst) do
    {:ok, {{_, 200, _}, _, b}} =
      :httpc.request(:get, {~c"#{@host}/#{p}", []}, [], body_format: :binary)

    File.write!(dst, b)
  end

  def read_wide(tile) do
    asked = SiliconSweep.Readback.request_frames(@wide)

    case RbCheck.raw(tile.baseaddr, asked) do
      {:ok, w} ->
        case SiliconSweep.Readback.to_frames(w) do
          {:ok, fr, a} -> {:ok, Enum.take(fr, @wide), a}
          e -> e
        end

      e ->
        e
    end
  end

  # Every differing (minor, word), classified by whether we meant to touch it.
  def diff(a, b) do
    Enum.flat_map(Enum.zip(a, b) |> Enum.with_index(), fn {{fa, fb}, minor} ->
      Enum.zip(fa, fb)
      |> Enum.with_index()
      |> Enum.reject(fn {{x, y}, _} -> x == y end)
      |> Enum.map(fn {_, wi} -> {minor, wi} end)
    end)
  end

  def intended?({minor, word}),
    do: minor in @minors and word >= @win_lo and word <= @win_hi

  def run do
    :inets.start()
    for f <- ["silicon_sweep.exs", "rb_check.exs", "pl_load.exs"], do: get(f, "/data/#{f}")
    for f <- ["silicon_sweep.exs", "rb_check.exs", "pl_load.exs"], do: Code.compile_file("/data/#{f}")

    SiliconSweep.Devcfg.start_link()
    SiliconSweep.DmaBuf.start_link()
    load = PlLoad.load("/data/mmcm_zinv.bin")

    tile = SiliconSweep.base_tile()
    {:ok, before, a1} = read_wide(tile)

    # Ones into the tile window only, across the full 36-frame image so the
    # write covers the same span we are inspecting.
    poked =
      before
      |> Enum.with_index()
      |> Enum.map(fn {f, mi} ->
        if mi in @minors do
          f
          |> Enum.with_index()
          |> Enum.map(fn {w, wi} ->
            if wi >= @win_lo and wi <= @win_hi, do: 0xFFFF_FFFF, else: w
          end)
        else
          f
        end
      end)

    wide_tile = %{tile | frames: @wide}
    wrote = SiliconSweep.write_frames(wide_tile, poked)
    SiliconSweep.Safety.dwell()

    {:ok, after_, a2} = read_wide(tile)
    changed = diff(before, after_)
    {intended, collateral} = Enum.split_with(changed, &intended?/1)

    IO.inspect(
      %{
        load_ok: load.ok?,
        wrote: wrote,
        align_before: Map.take(a1, [:lead, :offset]),
        align_after: Map.take(a2, [:lead, :offset]),
        frames_compared: length(before),
        changed_total: length(changed),
        intended_changes: length(intended),
        collateral_changes: length(collateral),
        collateral_sample: Enum.take(collateral, 20),
        collateral_by_minor: Enum.frequencies_by(collateral, &elem(&1, 0)),
        queue_idle: SiliconSweep.Devcfg.queue_idle?()
      },
      limit: :infinity
    )
  end
end

Confine.run()
