#!/usr/bin/env elixir
#
# fasm_audit.exs -- diff a design's EMITTED features against everything
# prjxray DOCUMENTS for the tile types that design uses.
#
#   elixir scripts/fasm_audit.exs designs/.../build/foo.fasm
#   elixir scripts/fasm_audit.exs foo.fasm --type CMT_TOP_L_LOWER_B
#   elixir scripts/fasm_audit.exs foo.fasm --all        # include low-signal
#
# ## Why
#
# This is the generalisation of the hand-diff that found the CMT defect, where
# the MMCM never locked because nextpnr wrote ZINV_RST with inverted polarity
# and so left the bit clear, holding the block in reset. Roughly fifteen
# bitstreams were spent searching the SILICON for that, on the assumption that
# a silent hard block means undocumented bits. It was a documented bit the
# emitter got backwards, and one pass over two text files would have found it.
#
# Three of this project's defects now have that shape (ISERDES OFB/OCLK
# tie-offs, ILOGICE3_IFF's input mux, CMT ZINV_RST). So this check should run
# BEFORE any hardware search, every time, on every design.
#
# ## What it looks for, strongest signal first
#
#   1. UNDOCUMENTED EMISSION -- the design emits a feature name prjxray has no
#      segbit for. Those bits go nowhere. This is a hard defect, never a
#      false positive.
#
#   2. SPLIT ENCODING GROUP -- within one primitive, some members of an
#      encoding family (ZINV_*, INV_*, ZINIT_*, ZSRVAL_*) are emitted and
#      others are not. THIS is the shape that caught the CMT: ZINV_PSEN and
#      ZINV_PSINCDEC present, ZINV_RST and ZINV_PWRDWN absent -- same
#      encoding, same primitive, four lines apart in the emitter.
#
#      A whole family being absent is weak evidence: plenty of features are
#      legitimately zero. A family that SPLITS is strong evidence, because
#      whatever justified emitting one member should have applied to its
#      siblings.
#
#   3. ABSENT FAMILY -- documented, entirely unemitted. Mostly legitimate
#      (EDGE, FRAC, SS_EN, STARTUP_WAIT are all correctly zero in a normal
#      design), so this is informational and printed only under --all.
#
# ## What it CANNOT tell you
#
# That an emitted bit is CORRECT. It compares names, not semantics. A bit
# written with the wrong VALUE, or the right bit on the wrong site, looks
# perfect here. The CMT bug was findable only because the wrong polarity
# happened to make the feature vanish from the output; had nextpnr written
# ZINV_RST=1 where the answer was 0, this tool would have said nothing.
#
# So: necessary, not sufficient. Silence here does not mean the design is
# right, it means this particular class of defect is absent.

defmodule FasmAudit do
  @encodings ~w(ZINV INV ZINIT ZSRVAL ZRST)

  # Pins nextpnr ties to constant 0, for primitives this project uses.
  #
  # This is not cosmetic. pack.cc:674 reads:
  #
  #     // Invertible pins connected to zero are optimised to a connection to
  #     // Vcc (which is easier to route) and an inversion
  #     ci->params[IS_<pin>_INVERTED] = 1;
  #
  # So an invertible pin tied low is implemented as VCC-plus-inversion, which
  # sets IS_x_INVERTED, which correctly SUPPRESSES ZINV_x. The bit being absent
  # is the pin working, not the pin broken.
  #
  # Without this table every design reports a split on BRAM (RSTRAM*, RSTREG*),
  # BUFGCTRL (CE1, S1) and MMCM (PSEN, PSINCDEC) -- five groups of pure noise
  # that would train the reader to ignore the one category that found a real
  # defect. Source: nextpnr-xilinx xilinx/pins.cc get_tied_pins().
  @tied_low %{
    "RAMB18E1" => ~w(CLKARDCLK CLKBWRCLK ENARDEN ENBWREN RSTRAMARSTRAM RSTRAMB
                     RSTREGARSTREG RSTREGB),
    "RAMB36E1" => ~w(CLKARDCLK CLKBWRCLK ENARDEN ENBWREN RSTRAMARSTRAM RSTRAMB
                     RSTREGARSTREG RSTREGB),
    "BUFGCTRL" => ~w(S0 S1 IGNORE0 IGNORE1 CE0 CE1),
    "MMCME2_ADV" => ~w(PSEN PSINCDEC PWRDWN),
    "PLLE2_ADV" => ~w(PWRDWN)
  }

  @doc """
  Is this ABSENT ZINV member explained by the constant-tie idiom?

  Deliberately keyed on pin name across all primitives rather than on the exact
  site path, because a .fasm scope is `RAMB18_Y0` while pins.cc is keyed by
  cell type `RAMB18E1`, and mapping between them reliably is more machinery
  than the precision is worth here.
  """
  def tie_explained?(enc, pin),
    do: enc == "ZINV" and Enum.any?(@tied_low, fn {_, pins} -> pin in pins end)

  # Second mechanism, distinct from the tie idiom. fasm.cc skips the output
  # register's clock and reset ZINVs entirely when that register does not
  # exist:
  #
  #     if ((pn == "RSTREGARSTREG" || pn == "REGCLKARDRCLK") && !DOA_REG) continue;
  #
  # attributed to a dcp2fasm bit-equivalence campaign against Vivado goldens.
  # So absence is expected exactly when DOA_REG / DOB_REG is itself unemitted,
  # which IS visible in the .fasm -- no netlist needed.
  def reg_explained?(enc, pin, scope, emitted) do
    enc == "ZINV" and
      case pin do
        p when p in ["RSTREGARSTREG", "REGCLKARDRCLK"] -> not has?(emitted, scope, "DOA_REG")
        p when p in ["RSTREGB", "REGCLKB"] -> not has?(emitted, scope, "DOB_REG")
        _ -> false
      end
  end

  defp has?(emitted, scope, feat) do
    name = if scope == "", do: feat, else: scope <> "." <> feat
    MapSet.member?(emitted, name)
  end

  # --- inputs --------------------------------------------------------------

  def tile_types(grid_path) do
    # A real JSON parse, deliberately. The first version of this used a regex
    # to pull "type" out of each tile object and silently produced ZERO tiles,
    # because tilegrid nests `bits` two levels deep and the pattern only
    # tolerated one. It failed CLOSED -- "0 tile types, clean" -- which for an
    # audit tool is the worst possible failure mode: it reports good news when
    # it has in fact examined nothing.
    #
    # A cleverer regex is available (zip tile keys against "type" occurrences
    # in document order) and is also wrong, because site names inside `sites`
    # match the same _X<n>Y<n> shape as tile names and would shift the zip.
    grid_path
    |> File.read!()
    |> Jason.decode!()
    |> Map.new(fn {tile, info} ->
      # A tile's bits may be ALIASED to another tile type: SING tiles carry
      # `"alias": {"type": "RIOB33", "sites": {"IOB33_Y0": "IOB33_Y1"}}`,
      # meaning their bits live in this tile's frames but are NAMED by the
      # aliased type. fasm2frames honours this, so the features do land.
      #
      # Ignoring it made this tool report RIOB33_SING and RIOI3_SING as
      # "uncharacterised, every emitted bit goes nowhere". They were not: the
      # region carries 15 set bits in a real build. A name-level audit that
      # does not follow aliases invents structural gaps that are not there.
      doc_type =
        case info["bits"] do
          %{} = bits when map_size(bits) > 0 ->
            case bits |> Map.values() |> hd() |> Map.get("alias") do
              %{"type" => t} -> t
              _ -> info["type"]
            end

          _ ->
            info["type"]
        end

      {tile, {info["type"], doc_type}}
    end)
  end

  @doc "Documented feature leaf names for a tile type, from segbits + ppips."
  def documented(db, type) do
    lower = String.downcase(type)

    # A tile type can have MORE THAN ONE bit space and therefore more than one
    # segbits file. BRAM_L has `segbits_bram_l.db` (CLB_IO_CLK space) and
    # `segbits_bram_l.block_ram.db` (the memory contents). Reading only the
    # first reported all 144 INIT/INITP features as undocumented emissions --
    # 144 confident false positives from one missing glob.
    seg =
      Path.wildcard(Path.join(db, "segbits_#{lower}.db")) ++
        Path.wildcard(Path.join(db, "segbits_#{lower}.*.db"))
      |> Enum.reject(&String.contains?(&1, "origin_info"))
      |> Enum.flat_map(&names(&1, type))

    # Pseudo-pips are real routing features with no bits. A design may emit
    # them legitimately, so they must count as documented or every ppip shows
    # up as an undocumented emission.
    ppip =
      Path.wildcard(Path.join(db, "ppips_#{lower}.db"))
      |> Enum.flat_map(&names(&1, type))

    # Distinguish "this tile type has no segbits file at all" from "this
    # feature is missing from it". The first means prjxray characterises NOTHING
    # for the type and every emitted bit is dropped on the floor; reporting that
    # as N undocumented features buries a structural gap in a feature list.
    has_db = Path.wildcard(Path.join(db, "segbits_#{lower}*.db")) != []

    {MapSet.new(seg), MapSet.new(ppip), has_db}
  end

  # prjxray writes segbits fully qualified by TILE TYPE
  # (`CMT_TOP_L_LOWER_B.MMCME2_ADV.IN_USE`) while a .fasm line is qualified by
  # tile INSTANCE (`CMT_TOP_L_LOWER_B_X178Y61.MMCME2_ADV.IN_USE`). Both have to
  # be reduced to the same leaf or nothing matches -- the first run of this
  # tool reported all 68 emitted features as undocumented for exactly that
  # reason. That failure was at least loud; the earlier regex failure was not.
  defp names(path, type) do
    if File.exists?(path) do
      path
      |> File.stream!()
      |> Enum.flat_map(fn line ->
        case String.split(String.trim(line), " ", parts: 2) do
          [name | _] when name != "" ->
            [name |> String.replace_prefix(type <> ".", "") |> strip_index()]

          _ ->
            []
        end
      end)
    else
      []
    end
  end

  # `FOO[3]`, `FOO[5:0]` and `FOO` are all one feature for this purpose.
  def strip_index(n), do: Regex.replace(~r/\[[0-9:]*\]/, n, "")

  @doc "Emitted leaf names per tile, from a .fasm."
  def emitted(fasm_path, tile_types) do
    fasm_path
    |> File.stream!()
    |> Enum.reduce(%{}, fn line, acc ->
      line = line |> String.trim() |> String.split(" =") |> hd()

      case Regex.run(~r/^([A-Z0-9_]+_X\d+Y\d+)\.(.+)$/, line) do
        [_, tile, leaf] ->
          case Map.fetch(tile_types, tile) do
            {:ok, {type, doc_type}} ->
              key = {{type, doc_type}, tile}
              Map.update(acc, key, MapSet.new([strip_index(leaf)]), &MapSet.put(&1, strip_index(leaf)))

            :error ->
              acc
          end

        _ ->
          acc
      end
    end)
  end

  # --- analysis ------------------------------------------------------------

  @doc """
  Split an encoding-family name into {scope, encoding, pin}.

  `MMCME2_ADV.ZINV_RST`   -> {"MMCME2_ADV", "ZINV", "RST"}
  `IFF.ZINV_C`            -> {"IFF", "ZINV", "C"}
  `ZINV_D`                -> {"", "ZINV", "D"}

  Returns nil for anything that is not an encoding family, which is most
  features -- those are handled by the weaker whole-family check.
  """
  def encoding_group(leaf) do
    {scope, last} =
      case String.split(leaf, ".") do
        [one] -> {"", one}
        many -> {Enum.drop(many, -1) |> Enum.join("."), List.last(many)}
      end

    case String.split(last, "_", parts: 2) do
      [enc, pin] when pin != "" ->
        if enc in @encodings, do: {scope, enc, pin}, else: nil

      _ ->
        nil
    end
  end

  def audit(type, tile, emitted, {seg, ppip, has_db}) do
    documented = MapSet.union(seg, ppip)

    undocumented =
      emitted
      |> MapSet.difference(documented)
      |> Enum.sort()

    # Encoding groups present in the DOCUMENTATION for this tile type, with
    # which members the design emitted.
    groups =
      seg
      |> Enum.flat_map(fn leaf ->
        case encoding_group(leaf) do
          nil -> []
          {scope, enc, pin} -> [{{scope, enc}, {pin, MapSet.member?(emitted, leaf)}}]
        end
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    splits =
      groups
      |> Enum.map(fn {{scope, enc} = key, members} ->
        _ = key
        # An absent member explained by the constant-tie idiom is not evidence
        # of anything, so it must not count toward "this group is split".
        unexplained =
          Enum.reject(members, fn {pin, on} ->
            not on and
              (tie_explained?(enc, pin) or reg_explained?(enc, pin, scope, emitted))
          end)

        {{scope, enc}, members, unexplained}
      end)
      |> Enum.filter(fn {_, _, unexplained} ->
        on = Enum.count(unexplained, &elem(&1, 1))
        on > 0 and on < length(unexplained)
      end)
      |> Enum.map(fn {{scope, enc}, members, _} -> {scope, enc, Enum.sort(members)} end)
      |> Enum.sort()

    absent_families =
      seg
      |> Enum.map(&family/1)
      |> Enum.uniq()
      |> Enum.reject(fn f -> Enum.any?(emitted, &(family(&1) == f)) end)
      |> Enum.sort()

    %{
      type: type,
      tile: tile,
      has_db: has_db,
      undocumented: undocumented,
      splits: splits,
      absent: absent_families
    }
  end

  defp family(leaf), do: leaf
end

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
