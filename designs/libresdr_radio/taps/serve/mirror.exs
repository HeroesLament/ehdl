defmodule Mirror do
  @moduledoc """
  Complete the mirror census: drive every candidate bit to ZERO and confirm.

  The all-ones census proved 2928 of 3136 positions can hold 1 after holding 0.
  The residual 208 -- the documented features the design actually uses -- have
  only ever been observed at 1, because they are 1 in the pristine bitstream and
  an all-ones write leaves them there. Writing zeros is the only way to show
  they are storage rather than tie-offs.
  """
  import Bitwise

  @host ~c"http://172.31.248.126:8101"

  def get(p, dst) do
    {:ok, {{_, 200, _}, _, b}} =
      :httpc.request(:get, {~c"#{@host}/#{p}", []}, [], body_format: :binary)

    File.write!(dst, b)
    byte_size(b)
  end

  def bit(frames, tile, {minor, b}) do
    w = Enum.at(Enum.at(frames, minor), tile.offset + div(b, 32))
    w >>> rem(b, 32) &&& 1
  end

  def run do
    :inets.start()
    for f <- ["silicon_sweep.exs", "rb_check.exs", "pl_load.exs", "cmt_expect.txt"],
        do: get(f, "/data/#{f}")

    for f <- ["silicon_sweep.exs", "rb_check.exs", "pl_load.exs"],
        do: Code.compile_file("/data/#{f}")

    SiliconSweep.Devcfg.start_link()
    SiliconSweep.DmaBuf.start_link()

    exp =
      File.read!("/data/cmt_expect.txt")
      |> String.split("\n", trim: true)
      |> Enum.map(fn l ->
        [v, m, b] = String.split(l)
        {String.to_integer(v), String.to_integer(m), String.to_integer(b)}
      end)

    score = fn fr ->
      Enum.reduce(exp, {0, 0}, fn {v, m, b}, {ok, bad} ->
        if bit(fr, SiliconSweep.base_tile(), {m, b}) == v, do: {ok + 1, bad}, else: {ok, bad + 1}
      end)
    end

    load = PlLoad.load("/data/mmcm_zinv.bin")
    tile = SiliconSweep.base_tile()
    cands = SiliconSweep.undocumented_bits(tile)

    {:ok, clean} = SiliconSweep.readback_tile(tile)

    # Zero the whole tile window in the two minors the candidates live in.
    zeroed =
      clean
      |> Enum.with_index()
      |> Enum.map(fn {f, mi} ->
        if mi in [28, 29] do
          f |> Enum.with_index() |> Enum.map(fn {w, wi} -> if wi <= 48, do: 0, else: w end)
        else
          f
        end
      end)

    wrote = SiliconSweep.write_frames(tile, zeroed)
    SiliconSweep.Safety.dwell()
    zread = SiliconSweep.readback_tile(tile)

    result =
      case zread do
        {:ok, zr} ->
          tally =
            Enum.reduce(cands, %{}, fn c, acc ->
              Map.update(acc, {bit(clean, tile, c), bit(zr, tile, c)}, 1, &(&1 + 1))
            end)

          %{
            wrote: wrote,
            candidates: length(cands),
            clean_to_zeroed: tally,
            still_one: Enum.count(cands, &(bit(zr, tile, &1) == 1)),
            assertions_clean: score.(clean),
            assertions_after_zero: score.(zr)
          }

        other ->
          %{wrote: wrote, readback_failed: inspect(other)}
      end

    IO.inspect(
      Map.merge(result, %{
        load_ok: load.ok?,
        pcfg_before: load.before.pcfg_done,
        pcfg_after: load.after.pcfg_done,
        queue_idle: SiliconSweep.Devcfg.queue_idle?()
      }),
      limit: :infinity
    )
  end
end

Mirror.run()
