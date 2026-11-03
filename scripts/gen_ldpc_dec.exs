# Generates lib/hw/std/ldpc_dec.ex (Hw.LdpcDec). The schedule ROMs, the 27-lane
# barrel rotators, the per-lane check-node arithmetic and the syndrome tree are
# regular and wide, so the EHDL source is written by this script; the output is
# committed and is what the tests and the build read.
#
#   mix run scripts/gen_ldpc_dec.exs
#
# Spec: OcuSync.Phy.LdpcFixed (nervezynq/ocusync) and the model in
# test/ldpc_dec_test.exs. Change all three together. The prototype is the one
# in OcuSync.Phy.Ldpc; it matches simgunz/802.11n-ldpc protoH/648_12
# (sha1 858e5c44) entry for entry.
#
# v2 schedule. Phase A of layer l + 1 runs while phase B of layer l drains, so
# an iteration is ~100 cycles instead of ~2 x 88 + 24 + a 90-cycle syndrome
# pass. The arithmetic is unchanged and stays bit-exact:
#  * A order within a layer only decides which of two EQUAL minima is called
#    "first", and then min1 == min2, so every R is the same. A therefore reads
#    the columns that the previous layer has finished writing first.
#  * B order is free (each edge's update is independent); B writes the columns
#    the next layer shares first.
#  * T is kept per edge in `tmem` (indexed by the global edge), so A(l + 1) and
#    B(l) never share a T slot; the check-node results of layer l are copied to
#    B-side registers when A(l) finishes.
#  * Hard decisions (sign of L) are mirrored in 24 x 27-bit registers updated
#    on every L write, and the 324 parity checks are static wiring over them,
#    so the syndrome after an iteration costs one cycle.
# The schedule is computed here greedily and then re-checked by an independent
# pass (RAW on lmem / tmem / rmem, B-side register reuse, one issue per port
# per cycle) before anything is written.

proto = """
 0 -1 -1 -1  0  0 -1 -1  0 -1 -1  0  1  0 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1
22  0 -1 -1 17 -1  0  0 12 -1 -1 -1 -1  0  0 -1 -1 -1 -1 -1 -1 -1 -1 -1
 6 -1  0 -1 10 -1 -1 -1 24 -1  0 -1 -1 -1  0  0 -1 -1 -1 -1 -1 -1 -1 -1
 2 -1 -1  0 20 -1 -1 -1 25  0 -1 -1 -1 -1 -1  0  0 -1 -1 -1 -1 -1 -1 -1
23 -1 -1 -1  3 -1 -1 -1  0 -1  9 11 -1 -1 -1 -1  0  0 -1 -1 -1 -1 -1 -1
24 -1 23  1 17 -1  3 -1 10 -1 -1 -1 -1 -1 -1 -1 -1  0  0 -1 -1 -1 -1 -1
25 -1 -1 -1  8 -1 -1 -1  7 18 -1 -1  0 -1 -1 -1 -1 -1  0  0 -1 -1 -1 -1
13 24 -1 -1  0 -1  8 -1  6 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1  0  0 -1 -1 -1
 7 20 -1 16 22 10 -1 -1 23 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1  0  0 -1 -1
11 -1 -1 -1 19 -1 -1 -1 13 -1  3 17 -1 -1 -1 -1 -1 -1 -1 -1 -1  0  0 -1
25 -1  8 -1 23 18 -1 14  9 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1  0  0
 3 -1 -1 -1 16 -1 -1  2 25  5 -1 -1  1 -1 -1 -1 -1 -1 -1 -1 -1 -1 -1  0
"""

z = 27
base = proto |> String.split("\n", trim: true) |> Enum.map(fn l -> l |> String.split() |> Enum.map(&String.to_integer/1) end)
nlayers = length(base)
ncols = base |> hd() |> length()

# Edges in ascending block column per layer; g is the global edge id (rmem /
# tmem address), slot the index within the layer (the check-node `ix`).
edges =
  for {row, i} <- Enum.with_index(base), {h, j} <- Enum.with_index(row), h >= 0 do
    %{i: i, j: j, h: h}
  end
  |> Enum.with_index()
  |> Enum.map(fn {e, g} -> Map.put(e, :g, g) end)

edges =
  edges
  |> Enum.group_by(& &1.i)
  |> Enum.flat_map(fn {_, l} -> l |> Enum.with_index() |> Enum.map(fn {e, s} -> Map.put(e, :slot, s) end) end)
  |> Enum.sort_by(& &1.g)

ne = length(edges)
layer_edges = Enum.group_by(edges, & &1.i)
dc_max = layer_edges |> Enum.map(fn {_, l} -> length(l) end) |> Enum.max()
if dc_max > 8, do: raise("check degree #{dc_max} > 8: widen ix")
if ne > 128, do: raise("#{ne} edges > 128: widen g")

# ---- greedy schedule (cycle numbers within one iteration) -------------------
# A-issue at ai: lmem[j] and rmem[g] addresses presented (data next cycle).
# A-process at ai + 1: T computed, written to tmem[g] at the end of that cycle.
# B-issue at bi: tmem[g] address presented; B-process at bi + 1 writes lmem[j],
# rmem[g] and the hard-decision register at the end of that cycle.
{sched, _} =
  Enum.reduce(0..(nlayers - 1), {[], %{ready: %{}, last_a: -1, last_b: -1, bpmax: -1}}, fn l, {acc, st} ->
    es = layer_edges[l]
    nxt = if l + 1 < nlayers, do: MapSet.new(layer_edges[l + 1], & &1.j), else: MapSet.new()
    a_order = Enum.sort_by(es, &{Map.get(st.ready, &1.j, 0), &1.j})
    n = length(a_order)

    {ais, last_a} =
      a_order
      |> Enum.with_index()
      |> Enum.map_reduce(st.last_a, fn {e, k}, la ->
        c = max(la + 1, Map.get(st.ready, e.j, 0))
        # p_l = ai(last) + 1 must not precede the last B-process of layer l - 1
        # (the B-side registers are reloaded at the end of p_l).
        c = if k == n - 1, do: max(c, st.bpmax - 1), else: c
        {{e.g, c}, c}
      end)

    ai = Map.new(ais)
    p = last_a + 1
    b_order = Enum.sort_by(es, &{if(MapSet.member?(nxt, &1.j), do: 0, else: 1), ai[&1.g], &1.j})

    {bis, {last_b, ready}} =
      Enum.map_reduce(b_order, {st.last_b, st.ready}, fn e, {lb, rd} ->
        c = Enum.max([lb + 1, ai[e.g] + 2, p])
        {{e.g, c}, {c, Map.put(rd, e.j, c + 2)}}
      end)

    bi = Map.new(bis)

    rows =
      for e <- es,
          do: Map.merge(e, %{ai: ai[e.g], bi: bi[e.g], a_first: if(e.g == elem(hd(ais), 0), do: 1, else: 0), a_last: if(e.g == elem(List.last(ais), 0), do: 1, else: 0)})

    bpmax = (bis |> Enum.map(&elem(&1, 1)) |> Enum.max()) + 1
    {acc ++ rows, %{ready: ready, last_a: last_a, last_b: last_b, bpmax: bpmax}}
  end)

t_iter = (sched |> Enum.map(& &1.bi) |> Enum.max()) + 2

# ---- independent check of the schedule -------------------------------------
by_layer = Enum.group_by(sched, & &1.i)
dup = fn key -> sched |> Enum.frequencies_by(&Map.fetch!(&1, key)) |> Enum.filter(fn {_, n} -> n > 1 end) end
if dup.(:ai) != [], do: raise("two A issues in one cycle: #{inspect(dup.(:ai))}")
if dup.(:bi) != [], do: raise("two B issues in one cycle: #{inspect(dup.(:bi))}")

for l <- 0..(nlayers - 1) do
  es = by_layer[l]
  p = (es |> Enum.map(& &1.ai) |> Enum.max()) + 1
  if Enum.count(es, &(&1.a_last == 1)) != 1 or Enum.find(es, &(&1.a_last == 1)).ai + 1 != p, do: raise("layer #{l}: a_last")
  if Enum.count(es, &(&1.a_first == 1)) != 1 or Enum.find(es, &(&1.a_first == 1)).ai != Enum.min(Enum.map(es, & &1.ai)), do: raise("layer #{l}: a_first")

  for e <- es do
    # tmem RAW: written end of ai + 1, read address sampled end of bi.
    if e.bi < e.ai + 2, do: raise("edge #{e.g}: tmem RAW")
    # B-side registers loaded end of p, used during B-process bi + 1.
    if e.bi + 1 < p + 1, do: raise("edge #{e.g}: B before check node done")
    # rmem: read sampled end of ai, written end of bi + 1.
    if e.bi + 1 <= e.ai, do: raise("edge #{e.g}: rmem order")
  end

  if l + 1 < nlayers do
    pn = (by_layer[l + 1] |> Enum.map(& &1.ai) |> Enum.max()) + 1
    bpmax = (es |> Enum.map(& &1.bi) |> Enum.max()) + 1
    if bpmax > pn, do: raise("layer #{l}: B-side registers reloaded before B finished")
  end
end

for e <- sched do
  # lmem RAW against the most recent earlier layer with this column, and
  # no later layer's write may land before this read is sampled.
  prev = sched |> Enum.filter(&(&1.j == e.j and &1.i < e.i)) |> Enum.max_by(& &1.i, fn -> nil end)
  if prev && prev.bi + 1 >= e.ai, do: raise("edge #{e.g}: lmem RAW vs layer #{prev.i}")

  for w <- sched, w.j == e.j, w.i > e.i do
    if w.bi + 1 <= e.ai, do: raise("edge #{e.g}: lmem WAR vs layer #{w.i}")
  end
end

if t_iter > 127, do: raise("iteration #{t_iter} cycles: widen cc")

# ---- emit -------------------------------------------------------------------
lane = fn w, r -> "#{w}[#{8 * r + 7}..#{8 * r}]" end
lbit = fn w, r -> "#{w}[#{8 * r + 7}..#{8 * r + 7}]" end

# out lane r = in lane (r + h) mod z
rot_fwd = fn inp, h -> "{" <> Enum.map_join((z - 1)..0//-1, ", ", &lane.(inp, rem(&1 + h, z))) <> "}" end
# out lane (r + h) mod z = in lane r, i.e. out lane s = in lane (s - h) mod z
rot_inv = fn inp, h -> "{" <> Enum.map_join((z - 1)..0//-1, ", ", &lane.(inp, rem(&1 - h + z, z))) <> "}" end

case_arms = fn sel, out, f -> Enum.flat_map(0..31, fn h -> ["      #{h} ->", "        #{out} = #{f.(if h < z, do: h, else: 0)}"] end) |> then(&(["    case #{sel} do"] ++ &1 ++ ["    end"])) end

log_rot = fn rot, inp, sel, out ->
  steps = [
    {"#{out}_s1", inp, "#{sel}[1..0]", [0, 1, 2, 3]},
    {"#{out}_s2", "#{out}_s1", "#{sel}[3..2]", [0, 4, 8, 12]}
  ]
  body =
    Enum.flat_map(steps, fn {o, i, sl, amts} ->
      ["    #{o} = #{i}", "    case #{sl} do"] ++
        Enum.flat_map(Enum.with_index(amts), fn {a, k} -> ["      #{k} ->", "        #{o} = #{rot.(i, a)}"] end) ++ ["    end"]
    end)
  body ++ ["    #{out} = if #{sel}[4..4] == 1 do #{rot.("#{out}_s2", 16)} else #{out}_s2 end"]
end

log_rot2 = fn kind, inp, sa, sb, out ->
  src = fn r, a -> if kind == :fwd, do: rem(r + a, z), else: rem(r - a + 2 * z, z) end
  stage = fn i, o, b0, b1, amts ->
    lanes =
      for r <- (z - 1)..0//-1 do
        sl = if r < 14, do: sa, else: sb
        l = fn a -> lane.(i, src.(r, a)) end
        case amts do
          [a0, a1, a2, a3] ->
            "(if #{sl}[#{b1}..#{b1}] == 1 do (if #{sl}[#{b0}..#{b0}] == 1 do #{l.(a3)} else #{l.(a2)} end) else (if #{sl}[#{b0}..#{b0}] == 1 do #{l.(a1)} else #{l.(a0)} end) end)"
          [a0, a1] ->
            "(if #{sl}[#{b0}..#{b0}] == 1 do #{l.(a1)} else #{l.(a0)} end)"
        end
      end
    "    #{o} = {" <> Enum.join(lanes, ", ") <> "}"
  end
  [stage.(inp, "#{out}_s1", 0, 1, [0, 1, 2, 3]), stage.("#{out}_s1", "#{out}_s2", 2, 3, [0, 4, 8, 12]), stage.("#{out}_s2", out, 4, 4, [0, 16])]
end

edge_rom = fn sel, fields ->
  ["    case #{sel} do"] ++
    Enum.flat_map(edges, fn e -> ["      #{e.g} ->"] ++ Enum.map(fields, fn {name, key} -> "        #{name} = #{Map.fetch!(e, key)}" end) end) ++
    ["    end"]
end

cyc_rom =
  ["    case cc do"] ++
    Enum.flat_map(0..(t_iter - 1), fn c ->
      a = Enum.find(sched, &(&1.ai == c))
      b = Enum.find(sched, &(&1.bi == c))
      body =
        if(a, do: ["        a_v = 1", "        a_g = #{a.g}", "        a_last = #{a.a_last}"], else: []) ++
          if(b, do: ["        b_v = 1", "        b_g = #{b.g}"], else: [])
      if body == [], do: [], else: ["      #{c} ->" | body]
    end) ++ ["    end"]

# 9-bit two's complement d -> sat to -127..127 as 8 bits.
sat9 = fn d -> "if #{d}[8..7] == 0 or (#{d}[8..7] == 3 and #{d}[6..0] != 0) do #{d}[7..0] else (if #{d}[8..8] == 1 do 129 else 127 end) end" end

lane_decls =
  Enum.flat_map(0..(z - 1), fn r ->
    [
      "  wire :d#{r}, 9",
      "  wire :t#{r}, 8",
      "  wire :a#{r}, 8",
      "  wire :lt1_#{r}, 1",
      "  wire :lt2_#{r}, 1",
      "  wire :m1_#{r}, 8, init: 255",
      "  wire :m2_#{r}, 8, init: 255",
      "  wire :ix_#{r}, 3, init: 0",
      "  wire :sp_#{r}, 1, init: 0",
      "  wire :m1n#{r}, 8",
      "  wire :m2n#{r}, 8",
      "  wire :ixn#{r}, 3",
      "  wire :spn#{r}, 1",
      "  wire :mb1_#{r}, 8, init: 0",
      "  wire :mb2_#{r}, 8, init: 0",
      "  wire :ixb#{r}, 3, init: 0",
      "  wire :spb#{r}, 1, init: 0",
      "  wire :mg#{r}, 8",
      "  wire :m3_#{r}, 10",
      "  wire :mp#{r}, 8",
      "  wire :ng#{r}, 1",
      "  wire :rn#{r}, 8",
      "  wire :su#{r}, 9",
      "  wire :ln#{r}, 8"
    ]
  end)

lane_comb =
  Enum.flat_map(0..(z - 1), fn r ->
    lr = lane.("lrot", r)
    rv = lane.("rv", r)
    tb = lane.("trd", r)

    [
      "    d#{r} = {#{lbit.("lrot", r)}, #{lr}} - {#{lbit.("rv", r)}, #{rv}}",
      "    t#{r} = #{sat9.("d#{r}")}",
      "    a#{r} = if t#{r}[7..7] == 1 do zero8 - t#{r} else t#{r} end",
      "    lt1_#{r} = if a#{r} < m1_#{r} do 1 else 0 end",
      "    lt2_#{r} = if a#{r} < m2_#{r} do 1 else 0 end",
      "    m1n#{r} = if lt1_#{r} == 1 do a#{r} else m1_#{r} end",
      "    m2n#{r} = if lt1_#{r} == 1 do m1_#{r} else (if lt2_#{r} == 1 do a#{r} else m2_#{r} end) end",
      "    ixn#{r} = if lt1_#{r} == 1 do p_slot else ix_#{r} end",
      "    spn#{r} = bxor(sp_#{r}, t#{r}[7..7])",
      "    mg#{r} = if q_slot == ixb#{r} do mb2_#{r} else mb1_#{r} end",
      "    m3_#{r} = {zero8[1..0], mg#{r}} + {zero8[0..0], mg#{r}, zero8[0..0]} + 2",
      "    mp#{r} = m3_#{r}[9..2]",
      "    ng#{r} = bxor(#{lbit.("trd", r)}, spb#{r})",
      "    rn#{r} = if ng#{r} == 1 do zero8 - mp#{r} else mp#{r} end",
      "    su#{r} = {#{lbit.("trd", r)}, #{tb}} + {rn#{r}[7..7], rn#{r}}",
      "    ln#{r} = #{sat9.("su#{r}")}"
    ]
  end)

cnu_a =
  Enum.flat_map(0..(z - 1), fn r ->
    ["          m1_#{r} = m1n#{r}", "          m2_#{r} = m2n#{r}", "          ix_#{r} = ixn#{r}", "          sp_#{r} = spn#{r}"]
  end)

cnu_hand =
  Enum.flat_map(0..(z - 1), fn r ->
    ["            mb1_#{r} = m1n#{r}", "            mb2_#{r} = m2n#{r}", "            ixb#{r} = ixn#{r}", "            spb#{r} = spn#{r}"]
  end)

cnu_clr = Enum.flat_map(0..(z - 1), fn r -> ["        m1_#{r} = c255", "        m2_#{r} = c255", "        sp_#{r} = 0"] end)

tword = "{" <> Enum.map_join((z - 1)..0//-1, ", ", &"t#{&1}") <> "}"
rword = "{" <> Enum.map_join((z - 1)..0//-1, ", ", &"rn#{&1}") <> "}"
lword = "{" <> Enum.map_join((z - 1)..0//-1, ", ", &"ln#{&1}") <> "}"
lsg = "{" <> Enum.map_join((z - 1)..0//-1, ", ", &"lw_data[#{8 * &1 + 7}..#{8 * &1 + 7}]") <> "}"
ldx = "{" <> Enum.map_join((z - 1)..0//-1, ", ", fn r -> "replicate(ld_word[#{6 * r + 5}..#{6 * r + 5}], 2), ld_word[#{6 * r + 5}..#{6 * r}]" end) <> "}"

hd_decls = Enum.map(0..(ncols - 1), &"  wire :hd#{&1}, 27, init: 0")
hd_write = ["        case lw_addr do"] ++ Enum.flat_map(0..(ncols - 1), &["          #{&1} ->", "            hd#{&1} = lsg"]) ++ ["        end"]

# Parity of check (i, r): XOR over the row's edges of hd_j bit (r + h) mod z.
pv_decls = Enum.map(0..(nlayers - 1), &"  wire :pchk#{&1}, 27")
pv_comb =
  Enum.map(0..(nlayers - 1), fn i ->
    terms =
      for e <- layer_edges[i] do
        "{" <> Enum.map_join((z - 1)..0//-1, ", ", fn r -> b = rem(r + e.h, z); "hd#{e.j}[#{b}..#{b}]" end) <> "}"
      end

    "    pchk#{i} = " <> Enum.reduce(tl(terms), hd(terms), fn t, acc -> "bxor(#{acc}, #{t})" end)
  end)

syn_or = "    synor = " <> Enum.reduce(1..(nlayers - 1), "pchk0", fn i, acc -> "bor(#{acc}, pchk#{i})" end)
out_mux = ["    out_word = 0", "    case ob do"] ++ Enum.flat_map(0..11, &["      #{&1} ->", "        out_word = hd#{&1}"]) ++ ["    end"]

src = ~S'''
defmodule Hw.LdpcDec do
  @moduledoc """
  OcuSync LDPC decoder, n = 648, R = 1/2, Z = 27, layered normalised
  min-sum. GENERATED by `scripts/gen_ldpc_dec.exs`; edit the generator, not
  this file.

  Bit-exact twin of `OcuSync.Phy.LdpcFixed` (nervezynq/ocusync) and of the
  model in `test/ldpc_dec_test.exs`. Prototype: `OcuSync.Phy.Ldpc` (see the
  provenance note there).

  * Load: 24 blocks of 27 6-bit LLRs (log P0 / P1), `ld_word` lane r =
    bits 6r + 5 .. 6r = codeword bit 27 ld_blk + r; then `start` with
    `max_iter`.
  * `lmem` holds the posteriors L (27 lanes x 8 bit per block column,
    saturated to -127..127); `rmem` one check-message word per prototype
    edge, so iteration 1 reads R as 0 and nothing is cleared; `tmem` one
    T word per edge.
  * Static schedule, @@TITER@@ cycles per iteration plus one for the
    syndrome (ROM indexed by `cc`). Phase A, one edge per cycle: the L block
    rotated by the edge's shift h (lane r takes lane (r + h) mod 27),
    `T = sat(L - R)` to `tmem`, and per lane the two smallest |T| (strict
    `<`), the first minimum's slot and the sign product. When a layer's A
    finishes these move to B-side registers and A starts the next layer while
    phase B drains this one: `R = +-(3 m + 2) >> 2` (m = min2 at the first
    minimum's slot, min1 elsewhere), `L = sat(T + R)` rotated back and
    stored. Edge orders inside A and B are the generator's (they do not
    change any value; see the generator header).
  * `hd0..hd23` mirror the sign of every stored L; the 324 checks are static
    XORs over them. After each iteration: stop when every check is zero or at
    `max_iter`.
  * Then `out_word` streams the 12 information blocks as hard bits
    (L < 0 = 1), `out_blk` 0..11, and `done` pulses with `ok` and `iters`.

  Contains written memories: verified under iverilog only.
  """

  use Hw.Component

  clock :clk, freq: 32.0

  input :enable, 1
  input :ld_valid, 1
  input :ld_blk, 5
  input :ld_word, 162
  input :start, 1
  input :max_iter, 4

  output :busy, 1
  output :done, 1
  output :ok, 1
  output :iters, 4
  output :out_valid, 1
  output :out_blk, 4
  output :out_word, 27

  memory :lmem, width: 216, depth: 32, sync_read: :clk
  memory :rmem, width: 216, depth: 128, sync_read: :clk
  memory :tmem, width: 216, depth: 128, sync_read: :clk

  wire :zero8, 8
  wire :zero216, 216
  wire :c255, 8

  wire :st, 3, init: 0
  wire :it, 4, init: 0
  # it1 == (it == 1), registered next to it. The 216-bit rv select was a
  # LUT4 decode of `it` on 216 LUT inputs (hw.census); split over 4 copies.
  wire :it1, 1, init: 0
  fanout :it1, 4
  wire :cc, 7, init: 0
  wire :p_v, 1, init: 0
  wire :p_g, 7, init: 0
  wire :p_last, 1, init: 0
  wire :q_v, 1, init: 0
  wire :q_g, 7, init: 0
  wire :o, 5, init: 0
  wire :pv4, 1, init: 0
  wire :ob, 4, init: 0
  wire :done_q, 1, init: 0
  wire :ok_q, 1, init: 0
  wire :it_q, 4, init: 0

  wire :a_v, 1
  wire :a_g, 7
  wire :a_last, 1
  wire :b_v, 1
  wire :b_g, 7
  wire :a_j, 5
  wire :p_h, 5, init: 0
  wire :p_slot, 3, init: 0
  wire :q_j, 5, init: 0
  wire :q_h, 5, init: 0
  wire :q_slot, 3, init: 0
  wire :pn_h, 5
  wire :pn_slot, 3
  wire :qn_j, 5
  wire :qn_h, 5
  wire :qn_slot, 3
  wire :ldsel, 1, init: 0
  # lw_data select: 222 LUT inputs on one FF (hw.census); split over 4 copies.
  fanout :ldsel, 4
  wire :p_hb, 5, init: 31
  wire :q_hb, 5, init: 31
  wire :phb, 5
  wire :qhb, 5
  wire :lrd, 216
  wire :rrd, 216
  wire :trd, 216
  wire :lrot, 216
  wire :lrot_s1, 216
  wire :lrot_s2, 216
  wire :lwr_s1, 216
  wire :lwr_s2, 216
  wire :rv, 216
  wire :lnew, 216
  wire :lwr, 216
  wire :lw_en, 1
  wire :lw_addr, 5
  wire :lw_data, 216
  wire :lsg, 27
  wire :synor, 27
  wire :syn_ok, 1
@@HD_DECLS@@
@@PV_DECLS@@
@@LANE_DECLS@@

  comb do
    zero8 = 0
    zero216 = 0
    c255 = 255

    a_v = 0
    a_g = 0
    a_last = 0
    b_v = 0
    b_g = 0
@@CYC_ROM@@
    a_j = 0
@@ROM_A@@
    pn_h = 0
    pn_slot = 0
@@ROM_P@@
    qn_j = 0
    qn_h = 0
    qn_slot = 0
@@ROM_Q@@

    phb = bnot(p_hb)
    qhb = bnot(q_hb)
    lrd = lmem[a_j]
    rrd = rmem[a_g]
    trd = tmem[b_g]
@@ROT_FWD@@
    rv = if it1 == 1 do zero216 else rrd end
@@LANE_COMB@@
    lnew = @@LWORD@@
@@ROT_INV@@

    lw_en = if (st == 1 and q_v == 1) or (st == 0 and ld_valid == 1) do 1 else 0 end
    lw_addr = if ldsel == 1 do q_j else ld_blk end
    lw_data = if ldsel == 1 do lwr else @@LDX@@ end
    lsg = @@LSG@@

@@PV_COMB@@
@@SYN_OR@@
    syn_ok = if synor == 0 do 1 else 0 end

    busy = if st != 0 do 1 else 0 end
    done = done_q
    ok = ok_q
    iters = it_q
    out_valid = pv4
    out_blk = ob
@@OUT_MUX@@
  end

  # st: 0 idle / load, 1 iterate (cc = 0 .. @@TLAST@@), 2 syndrome decision,
  # 4 output, 5 done.
  on :clk do
    done_q = 0
    pv4 = 0
    if enable == 0 do
      st = 0
      ldsel = 0
      p_v = 0
      q_v = 0
    else
      if lw_en == 1 do
        lmem[lw_addr] = lw_data
@@HD_WRITE@@
      end

      if p_v == 1 do
        tmem[p_g] = @@TWORD@@
@@CNU_A@@
        if p_last == 1 do
@@CNU_HAND@@
        end
      end
      # Row minima restart at (255, 255, +) after each row and at start, so
      # the first edge needs no first-edge select (a <= 128 < 255). The
      # constants come last and map to the FF set/reset pins.
      if (p_v == 1 and p_last == 1) or (st == 0 and start == 1) do
@@CNU_CLR@@
      end

      if q_v == 1 do
        rmem[q_g] = @@RWORD@@
      end

      if st == 0 and start == 1 do
        it = 1
        it1 = 1
        cc = 0
        p_v = 0
        q_v = 0
        st = 1
        ldsel = 1
      end

      if st == 1 do
        p_v = a_v
        p_g = a_g
        p_h = pn_h
        p_hb = bnot(pn_h)
        p_slot = pn_slot
        p_last = a_last
        q_v = b_v
        q_g = b_g
        q_j = qn_j
        q_h = qn_h
        q_hb = bnot(qn_h)
        q_slot = qn_slot
        if cc == @@TLAST@@ do
          st = 2
          ldsel = 0
        else
          cc = cc + 1
        end
      end

      if st == 2 do
        if syn_ok == 1 or it == max_iter do
          ok_q = syn_ok
          it_q = it
          st = 4
          o = 0
        else
          it = it + 1
          it1 = if it == 0 do 1 else 0 end
          cc = 0
          st = 1
          ldsel = 1
        end
      end

      if st == 4 do
        pv4 = 1
        ob = o[3..0]
        if o == 11 do
          st = 5
        else
          o = o + 1
        end
      end

      if st == 5 do
        done_q = 1
        st = 0
      end
    end
  end
end
'''

src =
  src
  |> String.replace("@@HD_DECLS@@", Enum.join(hd_decls, "\n"))
  |> String.replace("@@PV_DECLS@@", Enum.join(pv_decls, "\n"))
  |> String.replace("@@LANE_DECLS@@", Enum.join(lane_decls, "\n"))
  |> String.replace("@@CYC_ROM@@", Enum.join(cyc_rom, "\n"))
  |> String.replace("@@ROM_A@@", Enum.join(edge_rom.("a_g", [{"a_j", :j}]), "\n"))
  |> String.replace("@@ROM_P@@", Enum.join(edge_rom.("a_g", [{"pn_h", :h}, {"pn_slot", :slot}]), "\n"))
  |> String.replace("@@ROM_Q@@", Enum.join(edge_rom.("b_g", [{"qn_j", :j}, {"qn_h", :h}, {"qn_slot", :slot}]), "\n"))
  |> String.replace("@@ROT_FWD@@", Enum.join(log_rot2.(:fwd, "lrd", "p_h", "phb", "lrot"), "\n"))
  |> String.replace("@@ROT_INV@@", Enum.join(log_rot2.(:inv, "lnew", "q_h", "qhb", "lwr"), "\n"))
  |> String.replace("@@LANE_COMB@@", Enum.join(lane_comb, "\n"))
  |> String.replace("@@LWORD@@", lword)
  |> String.replace("@@RWORD@@", rword)
  |> String.replace("@@TWORD@@", tword)
  |> String.replace("@@LDX@@", ldx)
  |> String.replace("@@LSG@@", lsg)
  |> String.replace("@@PV_COMB@@", Enum.join(pv_comb, "\n"))
  |> String.replace("@@SYN_OR@@", syn_or)
  |> String.replace("@@OUT_MUX@@", Enum.join(out_mux, "\n"))
  |> String.replace("@@HD_WRITE@@", Enum.join(hd_write, "\n"))
  |> String.replace("@@CNU_A@@", Enum.join(cnu_a, "\n"))
  |> String.replace("@@CNU_HAND@@", Enum.join(cnu_hand, "\n"))
  |> String.replace("@@CNU_CLR@@", Enum.join(cnu_clr, "\n"))
  |> String.replace("@@TITER@@", Integer.to_string(t_iter))
  |> String.replace("@@TLAST@@", Integer.to_string(t_iter - 1))

out = Path.expand("../lib/hw/std/ldpc_dec.ex", __DIR__)
File.write!(out, src)
IO.puts("wrote #{out} (#{src |> String.split("\n") |> length()} lines, #{ne} edges, #{nlayers} layers, dc_max #{dc_max}, #{t_iter} + 1 cycles/iteration)")
