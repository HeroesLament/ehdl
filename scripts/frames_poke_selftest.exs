#!/usr/bin/env elixir
#
# frames_poke_selftest.exs -- known-answer control for frames_poke.exs
#
#   source scripts/openxc7-env.sh && mix run scripts/frames_poke_selftest.exs
#
# ## What is under test
#
# ONLY the bit-address arithmetic:
#
#     frame = baseaddr + minor ;  word = offset + div(bit,32) ;  bit = rem(bit,32)
#
# Nothing about the silicon. Passing does not mean a poked undocumented bit
# will do anything; it means that when the tool writes what prjxray calls
# `29_841`, the bitstream carries it where fasm2frames would have put it. That
# has to be true before any search result means anything.
#
# ## The oracle
#
# fasm2frames already knows the right answer for every DOCUMENTED feature, so
# it is a complete oracle for the arithmetic -- no board, no Vivado:
#
#     A = fasm2frames(fasm)                      # feature present
#     B = fasm2frames(fasm minus that line)      # feature absent
#     C = poke(B, the feature's segbits)
#     assert content(C) == content(A)
#
# ## Why these particular cases
#
# One passing case proves little, because most bits land in the easy part of a
# frame. Each case below fails for a reason no other case can:
#
#   cmt_1bit     minor 29, one bit, offset 0     -- base case
#   cmt_multi    minors 28 AND 29, 110 bits      -- multi-minor; also catches a
#                                                   poke that writes only the
#                                                   first bit of a list
#   hclk_clkword offset 45, bit 185 -> WORD 50    -- the clock word. This is the
#                                                   assumption called out in
#                                                   frames_poke.exs's header:
#                                                   that `offset` indexes the
#                                                   101-word space with the
#                                                   clock word already in it, so
#                                                   no HCLK adjustment applies.
#                                                   Every other case can pass
#                                                   while this one fails.
#   rioi3_neg    `34_72 !35_69`                  -- a NEGATED segbit: sets and
#                                                   clears in the same case, so
#                                                   polarity handling is tested
#
# Passing all four says the tool is right about frame addressing, minor spans,
# the clock word and polarity. It says nothing about whether an undocumented
# bit does anything -- that is what the hardware is for.

Code.require_file(Path.join(__DIR__, "frames_poke.exs"))

part = "xc7z020clg400-1"
db = System.get_env("PRJXRAY_DB") || Path.expand("~/src/openxc7/prjxray-db")
grid = db <> "/zynq7/xc7z020/tilegrid.json"
mmcm = Path.expand("designs/libresdr_radio/build/mmcm_b.fasm")
radio = Path.expand("designs/libresdr_radio/build/libresdr_radio_s4.fasm")

# {name, fasm, tile, feature, segbits db, tile type}
cases = [
  {"cmt_1bit", mmcm, "CMT_TOP_L_LOWER_B_X178Y61", "MMCME2_ADV.DIVCLK_DIVCLK_NO_COUNT[0]",
   "segbits_cmt_top_l_lower_b.db", "CMT_TOP_L_LOWER_B"},
  {"cmt_multi", mmcm, "CMT_TOP_L_LOWER_B_X178Y61", "MMCME2_ADV.IN_USE",
   "segbits_cmt_top_l_lower_b.db", "CMT_TOP_L_LOWER_B"},
  {"hclk_clkword", mmcm, "HCLK_CMT_L_X178Y78", "HCLK_CMT_CK_BUFHCLK0_USED",
   "segbits_hclk_cmt_l.db", "HCLK_CMT_L"},
  {"rioi3_neg", radio, "RIOI3_X73Y65", "IDELAY_Y0.DELAY_SRC_IDATAIN",
   "segbits_rioi3.db", "RIOI3"}
]

defmodule T do
  def segbits(dbfile, key) do
    dbfile
    |> File.stream!()
    |> Enum.find_value(fn line ->
      case String.split(String.trim(line), " ", parts: 2) do
        [^key, rest] -> rest
        _ -> nil
      end
    end)
    |> case do
      nil ->
        raise "segbit #{key} not in #{dbfile}"

      rest ->
        rest
        |> String.split(~r/\s+/, trim: true)
        |> Enum.map(fn tok ->
          {v, t} =
            if String.starts_with?(tok, "!"),
              do: {0, binary_slice(tok, 1..-1//1)},
              else: {1, tok}

          [mi, bi] = String.split(t, "_")
          {String.to_integer(mi), String.to_integer(bi), v}
        end)
    end
  end

  def diff(pa, pb) do
    a = FramesPoke.load(pa)
    b = FramesPoke.load(pb)
    zero = List.duplicate(0, 101)

    MapSet.union(MapSet.new(Map.keys(a)), MapSet.new(Map.keys(b)))
    |> Enum.sort()
    |> Enum.flat_map(fn k ->
      Enum.zip(Map.get(a, k, zero), Map.get(b, k, zero))
      |> Enum.with_index()
      |> Enum.reject(fn {{x, y}, _} -> x == y end)
      |> Enum.map(fn {{x, y}, i} -> {k, i, x, y} end)
    end)
  end
end

tmp = Path.join(System.tmp_dir!(), "fpst")
File.rm_rf!(tmp)
File.mkdir_p!(tmp)

f2f = fn src, out ->
  {o, rc} = System.cmd("fasm2frames", ["--part", part, "--db-root", db <> "/zynq7", src])
  if rc != 0, do: raise("fasm2frames failed on #{src}")
  File.write!(out, o)
end

# One reference build per distinct source fasm, reused across its cases.
refs =
  cases
  |> Enum.map(fn c -> elem(c, 1) end)
  |> Enum.uniq()
  |> Map.new(fn src ->
    out = Path.join(tmp, Path.basename(src) <> ".a.frames")
    f2f.(src, out)
    {src, {out, File.read!(src) |> String.split("\n")}}
  end)

results =
  for {name, fasm, tile, feat, dbf, ttype} <- cases do
    {a_frames, src_lines} = refs[fasm]
    bits = T.segbits(Path.join([db, "zynq7", dbf]), "#{ttype}.#{feat}")
    info = FramesPoke.tile_info(tile, grid)
    prefix = "#{tile}.#{feat}"

    kept = Enum.reject(src_lines, &String.starts_with?(&1, prefix))
    dropped = length(src_lines) - length(kept)

    b = Path.join(tmp, "#{name}_b.fasm")
    bf = Path.join(tmp, "#{name}_b.frames")
    cf = Path.join(tmp, "#{name}_c.frames")

    verdict =
      if dropped == 0 do
        {:skip, "feature line absent from fasm"}
      else
        File.write!(b, Enum.join(kept, "\n"))
        f2f.(b, bf)

        if T.diff(a_frames, bf) == [] do
          {:skip, "dropping the line changed no frame -- no oracle"}
        else
          FramesPoke.load(bf)
          |> FramesPoke.poke_all(info, bits)
          |> FramesPoke.save(cf)

          case T.diff(a_frames, cf) do
            [] -> {:pass, "#{length(bits)} bits"}
            d -> {:fail, d}
          end
        end
      end

    {wlo, whi} =
      bits |> Enum.map(fn {_, bit, _} -> info.offset + div(bit, 32) end) |> Enum.min_max()

    IO.puts([
      String.pad_trailing(name, 14),
      String.pad_trailing(tile, 28),
      String.pad_trailing("words #{wlo}..#{whi}", 16),
      case verdict do
        {:pass, why} -> "PASS (#{why})"
        {:skip, why} -> "SKIP (#{why})"
        {:fail, d} -> "FAIL (#{length(d)} words differ)"
      end
    ])

    with {:fail, d} <- verdict do
      for {k, i, x, y} <- Enum.take(d, 8) do
        IO.puts(
          "    0x#{Integer.to_string(k, 16)} word #{i}: oracle=0x#{Integer.to_string(x, 16)} poked=0x#{Integer.to_string(y, 16)}"
        )
      end
    end

    elem(verdict, 0)
  end

IO.puts("")

cond do
  :fail in results ->
    IO.puts("SELFTEST FAILED")
    System.halt(1)

  :skip in results ->
    IO.puts("SELFTEST INCOMPLETE -- a case produced no oracle")
    System.halt(2)

  true ->
    IO.puts("SELFTEST PASSED -- #{length(results)}/#{length(results)} cases")
end
