# LsdrBringup: the STATE_DUMP.md bring-up ritual as one served script.
#
# Replaces pasting the ritual into a shell-quoted ssh command (zsh history
# expansion eats the `!` in File.write! inside double quotes; that silently
# skipped a bring-up on 2026-09-24). Canonical here, copied to taps/serve.
#
#   :inets.start()
#   {:ok, {{_, 200, _}, _, b}} = :httpc.request(:get,
#     {~c"http://<peer>:8101/lsdr_bringup.exs", []}, [], body_format: :binary)
#   File.write!("/data/lsdr_bringup.exs", b)
#   Code.compile_file("/data/lsdr_bringup.exs")
#   LsdrBringup.run("http://<peer>:8101", ["tx_tone.exs"])
#
# <peer> is the Mac on this board's usb0 (board address + 1).
#
# Order, per STATE_DUMP.md / STREAM_RX_SESSION.md: fetch, compile the
# silicon-sweep helpers, start Devcfg + DmaBuf, PlLoad bracket for the
# bitstream, SDR.open, BIST selftest, then any extra scripts.

defmodule LsdrBringup do
  @base ~w(silicon_sweep.exs rb_check.exs pl_load.exs sdr.exs hp_stream.exs)
  @bitstream "hp_dma_s1.bin"

  # `bitstream` defaults to the radio's hp_dma_s1.bin; pass another radio
  # build (same GP0 register file, e.g. a TX-port variant) to bring it up the
  # same way. Non-radio tops (hp_loop) have their own bring-up.
  def run(host, extra \\ [], bitstream \\ @bitstream) do
    files = @base ++ extra ++ [bitstream]

    sizes =
      for f <- files do
        {:ok, {{_, 200, _}, _, b}} =
          :httpc.request(:get, {~c"#{host}/#{f}", []}, [{:timeout, 30_000}], body_format: :binary)

        File.write!("/data/" <> f, b)
        {f, byte_size(b)}
      end

    for f <- ~w(silicon_sweep.exs rb_check.exs pl_load.exs), do: Code.compile_file("/data/" <> f)
    ensure(SiliconSweep.Devcfg)
    ensure(SiliconSweep.DmaBuf)

    load = PlLoad.load("/data/" <> bitstream)
    Code.compile_file("/data/sdr.exs")
    {:ok, open} = Nervezynq.SDR.open()
    {:ok, st} = Nervezynq.SDR.selftest()
    Code.compile_file("/data/hp_stream.exs")
    for f <- extra, String.ends_with?(f, ".exs"), do: Code.compile_file("/data/" <> f)

    r = %{
      fetched: sizes,
      load_ok: load[:ok?],
      pcfg_done: PlLoad.pcfg_done?(),
      lo_hz: open.frequency,
      data_clk_mhz: open.data_clk_mhz,
      selftest: st.pass
    }

    IO.puts("BRINGUP " <> inspect(Map.delete(r, :fetched)))
    r
  end

  defp ensure(mod) do
    case Process.whereis(mod) do
      nil -> {:ok, _} = mod.start_link()
      pid -> {:ok, pid}
    end
  end
end
