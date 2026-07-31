#!/usr/bin/env elixir
# fasm_audit_cli.exs -- command line for FasmAudit.
#
#   mix run scripts/fasm_audit_cli.exs design.fasm [--type TILE_TYPE] [--all]
#
# Separate from fasm_audit.exs for the same reason frames_poke_cli.exs is
# separate: `Code.require_file` on the module must never execute a CLI. The
# combined version printed a full audit report in the middle of
# fasm_coverage.exs's output, which requires the module purely for its parsers.

Code.require_file(Path.join(__DIR__, "fasm_audit.exs"))

# --- CLI ---------------------------------------------------------------------

{opts, argv, _} =
  OptionParser.parse(System.argv(), strict: [type: :string, all: :boolean])

case argv do
  [fasm | _] ->
    db = (System.get_env("PRJXRAY_DB") || Path.expand("~/src/openxc7/prjxray-db")) <> "/zynq7"
    grid = db <> "/xc7z020/tilegrid.json"

    types = FasmAudit.tile_types(grid)
    if map_size(types) == 0, do: raise("tilegrid parsed to 0 tiles -- #{grid}")

    em = FasmAudit.emitted(fasm, types)
    if map_size(em) == 0, do: raise("no tiles matched between #{fasm} and tilegrid -- audit examined nothing")

    # One representative tile per type is enough for a name-level audit, and
    # keeps the output readable on a design with 300 CLB tiles. The tile with
    # the MOST emitted features is chosen, since a barely-used tile would
    # report every sibling as absent.
    per_type =
      em
      |> Enum.group_by(fn {{pair, _}, _} -> pair end)
      |> Enum.map(fn {{type, doc_type}, entries} ->
        {{_, tile}, feats} = Enum.max_by(entries, fn {_, f} -> MapSet.size(f) end)
        {type, doc_type, tile, feats}
      end)
      |> Enum.filter(fn {type, _, _, _} -> is_nil(opts[:type]) or type == opts[:type] end)
      |> Enum.sort()

    docs =
      Map.new(per_type, fn {_, doc_type, _, _} -> {doc_type, FasmAudit.documented(db, doc_type)} end)

    results =
      for {type, doc_type, tile, feats} <- per_type do
        label = if type == doc_type, do: type, else: "#{type} (via #{doc_type})"
        FasmAudit.audit(label, tile, feats, docs[doc_type])
      end

    IO.puts("fasm_audit: #{Path.basename(fasm)} -- #{length(results)} tile types\n")

    n_nodb = Enum.count(results, &(not &1.has_db and &1.undocumented != []))
    n_undoc = Enum.sum(Enum.map(results, fn r -> if r.has_db, do: length(r.undocumented), else: 0 end))
    n_split = Enum.sum(Enum.map(results, &length(&1.splits)))

    # A tile type with no segbits file that emits ONLY pseudo-pips has no
    # configuration to lose -- interconnect, BRKH and the PS boundary tiles are
    # all like this. Reporting them as uncharacterised is noise.
    for r <- results, not r.has_db, r.undocumented != [] do
      IO.puts("[0] TILE TYPE UNCHARACTERISED  #{r.type}  (#{r.tile})")
      IO.puts("      prjxray has NO segbits db for this tile type.")
      IO.puts("      All #{length(r.undocumented)} features the design emits here go nowhere.")
      for u <- r.undocumented, do: IO.puts("        #{u}")
      IO.puts("")
    end

    for r <- results, r.has_db, r.undocumented != [] do
      IO.puts("[1] UNDOCUMENTED EMISSION  #{r.type}  (#{r.tile})")
      for u <- r.undocumented, do: IO.puts("      #{u}")
      IO.puts("")
    end

    for r <- results, r.splits != [] do
      IO.puts("[2] SPLIT ENCODING GROUP   #{r.type}  (#{r.tile})")

      for {scope, enc, members} <- r.splits do
        label = if scope == "", do: enc, else: "#{scope}.#{enc}"
        IO.puts("      #{label}_*")

        for {pin, on} <- members do
          note =
            cond do
              on -> ""
              FasmAudit.tie_explained?(enc, pin) -> "   (tied low -> expected)"
              true -> ""
            end

          IO.puts("        #{if on, do: "emitted ", else: "ABSENT  "} #{enc}_#{pin}#{note}")
        end
      end

      IO.puts("")
    end

    if opts[:all] do
      for r <- results, r.absent != [] do
        IO.puts("[3] absent (informational) #{r.type}: #{length(r.absent)} features")
      end

      IO.puts("")
    end

    # An audit that examined nothing must never say "clean". The first version
    # of this script did exactly that when its tilegrid regex failed.
    if results == [], do: raise("0 tile types selected -- nothing was audited")

    examined = Enum.sum(Enum.map(per_type, fn {_, _, _, f} -> MapSet.size(f) end))

    IO.puts("summary: #{length(results)} tile types, #{examined} emitted features examined")
    IO.puts("         #{n_nodb} uncharacterised tile types, #{n_undoc} undocumented emissions, #{n_split} split encoding groups")

    if n_nodb + n_undoc + n_split == 0,
      do: IO.puts("clean on this class of defect (which is not the same as correct)")

  _ ->
    IO.puts("usage: fasm_audit.exs <design.fasm> [--type TILE_TYPE] [--all]")
end
