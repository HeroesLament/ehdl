#!/usr/bin/env elixir
#
# frames_poke.exs -- set or clear ARBITRARY bits in a routed .frames file.
#
#   elixir scripts/frames_poke.exs in.frames out.frames TILE set 29_101 clear 28_116 ...
#   elixir scripts/frames_poke.exs in.frames out.frames TILE setrange 29 1081..1567
#   elixir scripts/frames_poke.exs --show TILE
#
# ## Why this exists
#
# `fasm2frames` only speaks NAMED features. To search for bits prjxray has not
# characterised there is no name to write, so the only way in is to edit the
# frames directly and hand them to `xc7frames2bit`.
#
# That is the whole enabling step for documenting silicon from this side. The
# openXC7 stack can only express what prjxray already knows; this can express
# anything the bitstream can hold.
#
# ## The method it enables, and how it differs from prjxray's
#
# prjxray documents bits by DIFFERENTIAL BITSTREAM ANALYSIS: build two designs
# in Vivado, diff the bitstreams. That is why its blind spot is bits Vivado
# writes identically in every design -- they never vary, so they never appear.
#
# We cannot do that. We can do something it structurally cannot: DIFFERENTIAL
# HARDWARE BEHAVIOUR. Poke a bit, load, measure, record. It answers "does this
# bit do something" rather than "what would Vivado write", and for documenting
# silicon that is frequently the better question -- and the only one available
# without a vendor toolchain.
#
# ## Bit addressing
#
# prjxray writes a segbit as `<minor>_<bit>`, e.g. `29_101`. Resolution:
#
#     frame address = baseaddr + minor
#     word          = offset + div(bit, 32)
#     bit in word   = rem(bit, 32)
#
# `baseaddr`, `offset` and `words` come from tilegrid.json. `offset` indexes
# directly into the 101 words of a frame and ALREADY accounts for the clock
# word at index 50 -- CMT_TOP_L_UPPER_T has offset 74, which is only meaningful
# in that space. So no HCLK adjustment is applied here. If a poke ever lands
# somewhere unexpected, this assumption is the first thing to re-check.
#
# ## VALIDATE IT BEFORE TRUSTING IT
#
# Do not point this at unknown bits until it has reproduced a KNOWN one. The
# procedure, which needs no new hardware:
#
#   1. Build a working VAR_LOAD bitstream and note that CNTVALUEOUT reads back
#      whatever tap software loads.
#   2. Take its .frames. prjxray documents IDELAY_VALUE[0] for the relevant
#      RIOI3 tile (e.g. `RIOI3.IDELAY_Y0.IDELAY_VALUE[0] = !34_120 34_122`).
#      Poke those two bits to the opposite polarity.
#   3. xc7frames2bit -> Bit2Bin -> load -> read CNTVALUEOUT.
#
# If the tap the silicon reports changes in the direction the poke implies, the
# addressing arithmetic is right. If it does not, everything found with this
# tool afterwards would have been noise. Six instruments in this project have
# produced confident wrong answers; every one was caught by a known-answer
# control and none by reading the code.

defmodule FramesPoke do
  import Bitwise

  @words_per_frame 101

  # --- tilegrid ------------------------------------------------------------

  @doc "Resolve a tile to %{baseaddr:, offset:, words:, frames:} from tilegrid.json."
  def tile_info(tile, grid_path) do
    json = File.read!(grid_path)

    # Deliberately a regex rather than a JSON parse: tilegrid.json is tens of
    # MB and only one object is ever wanted. The shape is stable.
    re =
      ~r/"#{Regex.escape(tile)}":\s*\{.*?"bits":\s*\{\s*"[A-Z_]+":\s*\{(?<body>.*?)\}/s

    case Regex.named_captures(re, json) do
      nil ->
        raise "tile #{tile} not found in #{grid_path}"

      %{"body" => body} ->
        %{
          baseaddr: body |> field(~r/"baseaddr":\s*"0x([0-9a-fA-F]+)"/) |> String.to_integer(16),
          frames: body |> field(~r/"frames":\s*(\d+)/) |> String.to_integer(),
          offset: body |> field(~r/"offset":\s*(\d+)/) |> String.to_integer(),
          words: body |> field(~r/"words":\s*(\d+)/) |> String.to_integer()
        }
    end
  end

  defp field(body, re) do
    case Regex.run(re, body) do
      [_, v] -> v
      _ -> raise "field #{inspect(re)} missing"
    end
  end

  @doc "Every `<minor>_<bit>` this tile can address. THIS is the search space."
  def bit_space(info) do
    for minor <- 0..(info.frames - 1),
        bit <- 0..(info.words * 32 - 1),
        do: {minor, bit}
  end

  # --- frames --------------------------------------------------------------

  def load(path) do
    path
    |> File.stream!()
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(String.trim(line), " ", parts: 2) do
        [addr, words] ->
          a = addr |> String.replace_prefix("0x", "") |> String.to_integer(16)

          w =
            words
            |> String.split(",")
            |> Enum.map(&(&1 |> String.trim() |> String.replace_prefix("0x", "") |> String.to_integer(16)))

          Map.put(acc, a, w)

        _ ->
          acc
      end
    end)
  end

  def save(frames, path) do
    body =
      frames
      |> Enum.sort_by(fn {a, _} -> a end)
      |> Enum.map_join("\n", fn {a, ws} ->
        "0x#{pad(a, 8)} " <> Enum.map_join(ws, ",", &"0x#{pad(&1, 8)}")
      end)

    File.write!(path, body <> "\n")
  end

  defp pad(v, n), do: v |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(n, "0")

  @doc """
  Set or clear one `<minor>_<bit>` of `tile`.

  A frame absent from the file is created zeroed -- a bit in an all-zero frame
  is exactly the case worth poking, and refusing it would exclude most of the
  undocumented space.
  """
  def poke(frames, info, minor, bit, value) when value in [0, 1] do
    addr = info.baseaddr + minor
    word = info.offset + div(bit, 32)
    b = rem(bit, 32)

    if word >= @words_per_frame,
      do: raise("bit #{minor}_#{bit} -> word #{word} exceeds #{@words_per_frame}")

    ws = Map.get(frames, addr, List.duplicate(0, @words_per_frame))
    old = Enum.at(ws, word)
    new = if value == 1, do: old ||| 1 <<< b, else: old &&& bnot(1 <<< b)
    Map.put(frames, addr, List.replace_at(ws, word, new))
  end

  def poke_all(frames, info, list) do
    Enum.reduce(list, frames, fn {minor, bit, v}, acc -> poke(acc, info, minor, bit, v) end)
  end

  @doc """
  Parse a bit spec into `{minor, bit, value}` triples.

      "29_101"        -> [{29, 101, v}]
      "29_1081..1567" -> [{29, 1081, v}, ... {29, 1567, v}]

  The range form is what makes group testing possible: halving a 2,614-bit
  space needs one command, not 1,307.
  """
  def parse_spec(spec, value) do
    case Regex.run(~r/^(\d+)_(\d+)(?:\.\.(\d+))?$/, spec) do
      [_, minor, bit] ->
        [{String.to_integer(minor), String.to_integer(bit), value}]

      [_, minor, lo, hi] ->
        m = String.to_integer(minor)
        for b <- String.to_integer(lo)..String.to_integer(hi), do: {m, b, value}

      _ ->
        raise "bad bit spec #{inspect(spec)} (want <minor>_<bit> or <minor>_<lo>..<hi>)"
    end
  end
end

# --- CLI -------------------------------------------------------------------
#
# Guarded so `Code.require_file/1` can pull the module in (the selftest does)
# without the CLI firing on the host script's argv.

if System.argv() != [] do

grid =
  System.get_env("PRJXRAY_DB", Path.expand("~/src/openxc7/prjxray-db")) <>
    "/zynq7/xc7z020/tilegrid.json"

case System.argv() do
  ["--show", tile] ->
    i = FramesPoke.tile_info(tile, grid)

    IO.puts("""
    #{tile}
      baseaddr 0x#{Integer.to_string(i.baseaddr, 16)}
      frames   #{i.frames}   (minors 0..#{i.frames - 1})
      offset   #{i.offset}
      words    #{i.words}
      bit space #{i.frames * i.words * 32} bits total
      one minor #{i.words * 32} bits
    """)

  [inp, out, tile | ops] ->
    info = FramesPoke.tile_info(tile, grid)

    list =
      ops
      |> Enum.chunk_every(2)
      |> Enum.flat_map(fn
        ["set", spec] -> FramesPoke.parse_spec(spec, 1)
        ["clear", spec] -> FramesPoke.parse_spec(spec, 0)
        other -> raise "bad op #{inspect(other)}"
      end)

    inp
    |> FramesPoke.load()
    |> FramesPoke.poke_all(info, list)
    |> FramesPoke.save(out)

    IO.puts("poked #{length(list)} bits in #{tile} -> #{out}")

  _ ->
    IO.puts("usage: frames_poke.exs <in.frames> <out.frames> <TILE> [set|clear <minor>_<bit>]...")
    IO.puts("       frames_poke.exs --show <TILE>")
end

end
