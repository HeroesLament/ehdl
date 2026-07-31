#!/usr/bin/env elixir
#
# fasm_coverage.exs -- how much of each tile type have we ever exercised?
#
#   mix run scripts/fasm_coverage.exs designs/*/build/*.fasm
#
# ## Why this is the map, not a metric
#
# SILICON_MAP tracks three states: OK (measured on this board), BAD (measured
# not working), DARK (undocumented). The dangerous one is the fourth, UNV:
# documented by prjxray AND emitted by nextpnr AND resolving cleanly, but never
# once exercised on silicon. That column has been wrong three times in this
# project -- BRAM parity, IDELAYE2 without its controller, and the CMT.
#
# fasm_audit.exs answers "is what we emit self-consistent". This answers the
# prior question: WHAT HAVE WE NEVER TOUCHED. Every documented feature that has
# never appeared in any FASM we have ever built is a feature whose behaviour on
# this die is pure assumption -- and the CMT is the standing proof that a
# feature can be documented, emitted and completely non-functional.
#
# Union across ALL builds, deliberately: a feature exercised once in a probe
# design that has since been reverted is still a feature we have some evidence
# about, and treating it as untouched would overstate the darkness.
#
# ## What a low percentage does and does not mean
#
# It does NOT mean the toolchain is broken there. Most of a tile type's feature
# space is modes we have no use for -- every IOSTANDARD we do not drive, every
# SERDES width we do not instantiate. A design that used 100% of RIOI3 would be
# a strange design.
#
# It means: IF we later need that feature, there is no evidence it works, and
# the base rate for "documented, emitted, and silently dead" in this project is
# not low. Read it as a risk register for future work, not a scorecard.

Code.require_file(Path.join(__DIR__, "fasm_audit.exs"))

db = (System.get_env("PRJXRAY_DB") || Path.expand("~/src/openxc7/prjxray-db")) <> "/zynq7"
grid = db <> "/xc7z020/tilegrid.json"

fasms = System.argv() |> Enum.filter(&String.ends_with?(&1, ".fasm")) |> Enum.filter(&File.exists?/1)

if fasms == [] do
  IO.puts("usage: fasm_coverage.exs <a.fasm> [b.fasm ...]")
  System.halt(1)
end

types = FasmAudit.tile_types(grid)

# doc_type -> MapSet of leaf names ever emitted, unioned over every build
seen =
  Enum.reduce(fasms, %{}, fn f, acc ->
    FasmAudit.emitted(f, types)
    |> Enum.reduce(acc, fn {{{_type, doc_type}, _tile}, feats}, a ->
      Map.update(a, doc_type, feats, &MapSet.union(&1, feats))
    end)
  end)

rows =
  for {doc_type, used} <- seen do
    {docd, ppip, has_db} = FasmAudit.documented(db, doc_type)
    total = MapSet.size(docd)
    hit = MapSet.size(MapSet.intersection(docd, used))
    {doc_type, hit, total, has_db, MapSet.difference(docd, used), ppip}
  end
  |> Enum.filter(fn {_, _, total, _, _, _} -> total > 0 end)
  |> Enum.sort_by(fn {_, hit, total, _, _, _} -> -(hit / total) end)

IO.puts("fasm_coverage: #{length(fasms)} builds\n")
IO.puts(String.pad_trailing("TILE TYPE", 26) <> "  EXERCISED / DOCUMENTED")

for {type, hit, total, _, _, _} <- rows do
  pct = round(hit * 100 / total)
  bar = String.duplicate("#", div(pct, 5)) <> String.duplicate(".", 20 - div(pct, 5))
  IO.puts("#{String.pad_trailing(type, 26)}  #{bar} #{String.pad_leading("#{hit}", 5)} / #{String.pad_leading("#{total}", 5)}  #{pct}%")
end

{th, tt} = Enum.reduce(rows, {0, 0}, fn {_, h, t, _, _, _}, {a, b} -> {a + h, b + t} end)
IO.puts("\ntotal: #{th} of #{tt} documented features ever emitted (#{round(th * 100 / tt)}%)")

if "--untouched" in System.argv() do
  IO.puts("\n--- never emitted, by tile type (the UNV/risk surface) ---")

  for {type, _, _, _, missing, _} <- rows, MapSet.size(missing) > 0 do
    IO.puts("\n#{type}  (#{MapSet.size(missing)})")

    missing
    |> Enum.sort()
    |> Enum.chunk_every(2)
    |> Enum.each(fn chunk ->
      IO.puts("    " <> Enum.map_join(chunk, "", &String.pad_trailing(&1, 52)))
    end)
  end
end
