# Generates lib/hw/std/fft64.ex (Hw.Fft64). The block is regular but wide
# (six SDF stages holding 63 complex delay registers, two 64-entry twiddle
# ROMs), so its EHDL source is written by this script rather than by hand;
# the output is committed and is what the tests and the build read.
#
#   mix run scripts/gen_fft64.exs
#
# Spec: OcuSync.Phy.FftFixed (nervezynq/ocusync) and the model in
# test/fft64_test.exs. Change all three together.
import Bitwise

defmodule Gen do
  # {replicate(sign), sig}: sign-extend `sig` (w bits) to `to` bits.
  def sx(sig, w, to) when to > w, do: "{replicate(#{sig}[#{w - 1}..#{w - 1}], #{to - w}), #{sig}}"
  def sx(sig, w, w), do: sig

  # Two's-complement constant as a w-bit unsigned literal.
  def u(v, w), do: v &&& (1 <<< w) - 1

  def log2(1), do: 0
  def log2(n), do: 1 + log2(div(n, 2))
end

tw = fn m ->
  a = 2 * :math.pi() * m / 64
  {round(:math.cos(a) * 65536), round(-:math.sin(a) * 65536)}
end

bit = fn q, b -> q >>> b &&& 1 end
# Exponent of W_64 applied at stream position q (FftFixed: level 1 multiplies
# by W_64^(n3 e), level 2 by W_16^(n3 e) = W_64^(4 n3 e)).
tw_m = %{
  t1: fn q -> (q &&& 15) * (bit.(q, 5) + 2 * bit.(q, 4)) end,
  t2: fn q -> 4 * (q &&& 3) * (bit.(q, 3) + 2 * bit.(q, 2)) end
}

# {tag, kind, src, in_w, out_w, delay}
blocks = [
  {"s1", :bf2i, "s0", 18, 19, 32},
  {"s2", :bf2ii, "s1", 19, 20, 16},
  {"t1", :tw, "s2", 20, 21, nil},
  {"s3", :bf2i, "t1", 21, 22, 8},
  {"s4", :bf2ii, "s3", 22, 23, 4},
  {"t2", :tw, "s4", 23, 24, nil},
  {"s5", :bf2i, "t2", 24, 25, 2},
  {"s6", :bf2ii, "s5", 25, 26, 1}
]

# Every block registers {v, r, i, p, l}: strobe, re, im, stream position, live.
regs = fn tag, w ->
  [
    "  wire :#{tag}_v, 1, init: 0",
    "  wire :#{tag}_r, #{w}, init: 0",
    "  wire :#{tag}_i, #{w}, init: 0",
    "  wire :#{tag}_p, 6, init: 0",
    "  wire :#{tag}_l, 1, init: 0",
    "  wire :#{tag}_t, 12, init: 0"
  ]
end

gen_bf = fn {tag, kind, src, wi, wo, d} ->
  lg = Gen.log2(d)
  old = "#{tag}_d#{d - 1}"

  decls =
    ["", "  # --- #{tag}: #{kind |> to_string() |> String.upcase()}, delay #{d}, #{wi} -> #{wo} bits ---"] ++
      regs.(tag, wo) ++
      Enum.flat_map(0..(d - 1), fn k -> ["  wire :#{tag}_d#{k}_r, #{wo}, init: 0", "  wire :#{tag}_d#{k}_i, #{wo}, init: 0"] end) ++
      Enum.map(~w(h j), &"  wire :#{tag}_#{&1}, 1") ++
      Enum.map(~w(z nx xr xi br bi sr si fr fi or oi nr ni), &"  wire :#{tag}_#{&1}, #{wo}")

  rot =
    case kind do
      :bf2i ->
        [
          "    #{tag}_j = 0",
          "    #{tag}_nx = 0",
          "    #{tag}_br = #{tag}_xr",
          "    #{tag}_bi = #{tag}_xi"
        ]

      :bf2ii ->
        # (-j) x = xi - j xr, applied to the second operand of a k1 = 1 group.
        [
          "    #{tag}_j = #{src}_p[#{lg + 1}..#{lg + 1}]",
          "    #{tag}_nx = #{tag}_z - #{tag}_xr",
          "    #{tag}_br = if #{tag}_j == 1 do #{tag}_xi else #{tag}_xr end",
          "    #{tag}_bi = if #{tag}_j == 1 do #{tag}_nx else #{tag}_xi end"
        ]
    end

  comb =
    [
      "",
      "    # #{tag}: h = half of the #{2 * d}-block; first half fills the delay,",
      "    # second half emits old + b and stores old - b.",
      "    #{tag}_z = 0",
      "    #{tag}_h = #{src}_p[#{lg}..#{lg}]",
      "    #{tag}_xr = #{Gen.sx("#{src}_r", wi, wo)}",
      "    #{tag}_xi = #{Gen.sx("#{src}_i", wi, wo)}"
    ] ++
      rot ++
      [
        "    #{tag}_sr = #{old}_r + #{tag}_br",
        "    #{tag}_si = #{old}_i + #{tag}_bi",
        "    #{tag}_fr = #{old}_r - #{tag}_br",
        "    #{tag}_fi = #{old}_i - #{tag}_bi",
        "    #{tag}_or = if #{tag}_h == 1 do #{tag}_sr else #{old}_r end",
        "    #{tag}_oi = if #{tag}_h == 1 do #{tag}_si else #{old}_i end",
        "    #{tag}_nr = if #{tag}_h == 1 do #{tag}_fr else #{tag}_xr end",
        "    #{tag}_ni = if #{tag}_h == 1 do #{tag}_fi else #{tag}_xi end"
      ]

  shift =
    Enum.flat_map((d - 1)..1//-1, fn k ->
      ["      #{tag}_d#{k}_r = #{tag}_d#{k - 1}_r", "      #{tag}_d#{k}_i = #{tag}_d#{k - 1}_i"]
    end)

  seq =
    [
      "",
      "  on :clk do",
      "    #{tag}_v = #{src}_v",
      "    if #{src}_v == 1 do",
      "      #{tag}_r = #{tag}_or",
      "      #{tag}_i = #{tag}_oi",
      "      #{tag}_p = #{src}_p - #{d}",
      "      #{tag}_l = #{src}_l",
      "      #{tag}_t = #{src}_t",
      "      #{tag}_d0_r = #{tag}_nr",
      "      #{tag}_d0_i = #{tag}_ni"
    ] ++ shift ++ ["    end", "  end"]

  {decls, comb, seq}
end

gen_tw = fn {tag, :tw, src, wa, wo, nil} ->
  pw = wa + 18
  m = tw_m[String.to_atom(tag)]
  prods = [{"rr", "r", "wr"}, {"ii", "i", "wi"}, {"ri", "r", "wi"}, {"ir", "i", "wr"}]

  decls =
    ["", "  # --- #{tag}: twiddle, #{wa} x 18 -> #{wo} bits, products #{pw} ---"] ++
      [
        "  wire :#{tag}_wr, 18",
        "  wire :#{tag}_wi, 18",
        "  wire :#{tag}_za, #{wa}",
        "  wire :#{tag}_zw, 18",
        "  wire :#{tag}_zp, #{pw}",
        "  wire :#{tag}_sa_r, 1",
        "  wire :#{tag}_sa_i, 1",
        "  wire :#{tag}_sw_r, 1",
        "  wire :#{tag}_sw_i, 1"
      ] ++
      Enum.flat_map(prods, fn {x, _, _} ->
        ["  wire :#{tag}_u_#{x}, #{pw}", "  wire :#{tag}_ka_#{x}, #{pw}", "  wire :#{tag}_kb_#{x}, #{pw}", "  wire :#{tag}_m_#{x}, #{pw}"]
      end) ++
      ["  wire :#{tag}m_v, 1, init: 0", "  wire :#{tag}m_p, 6, init: 0", "  wire :#{tag}m_l, 1, init: 0", "  wire :#{tag}m_t, 12, init: 0"] ++
      Enum.map(prods, fn {x, _, _} -> "  wire :#{tag}m_#{x}, #{pw}, init: 0" end) ++
      ["  wire :#{tag}_half, #{pw + 1}", "  wire :#{tag}_er, #{pw + 1}", "  wire :#{tag}_ei, #{pw + 1}", "  wire :#{tag}_or, #{wo}", "  wire :#{tag}_oi, #{wo}"] ++
      regs.(tag, wo)

  rom =
    Enum.flat_map(0..63, fn q ->
      {wr, wi} = tw.(m.(q))
      ["      #{q} ->", "        #{tag}_wr = #{Gen.u(wr, 18)}", "        #{tag}_wi = #{Gen.u(wi, 18)}"]
    end)

  # Signed product mod 2^pw from an unsigned one: subtract w << wa when a is
  # negative and a << 18 when w is negative (the LtfSync idiom).
  mul =
    Enum.flat_map(prods, fn {x, a, w} ->
      [
        "    #{tag}_u_#{x} = #{src}_#{a} * #{tag}_#{w}",
        "    #{tag}_ka_#{x} = if #{tag}_sa_#{a} == 1 do {#{tag}_#{w}, #{tag}_za} else #{tag}_zp end",
        "    #{tag}_kb_#{x} = if #{tag}_sw_#{String.last(w)} == 1 do {#{src}_#{a}, #{tag}_zw} else #{tag}_zp end",
        "    #{tag}_m_#{x} = #{tag}_u_#{x} - #{tag}_ka_#{x} - #{tag}_kb_#{x}"
      ]
    end)

  sxp = fn s -> Gen.sx(s, pw, pw + 1) end

  comb =
    [
      "",
      "    # #{tag}: W by stream position (W_64^m, m = #{if tag == "t1", do: "n3 (k1 + 2 k2)", else: "4 n3' (k1' + 2 k2')"}).",
      "    #{tag}_za = 0",
      "    #{tag}_zw = 0",
      "    #{tag}_zp = 0",
      "    #{tag}_wr = 0",
      "    #{tag}_wi = 0",
      "    case #{src}_p do"
    ] ++
      rom ++
      [
        "    end",
        "    #{tag}_sa_r = #{src}_r[#{wa - 1}..#{wa - 1}]",
        "    #{tag}_sa_i = #{src}_i[#{wa - 1}..#{wa - 1}]",
        "    #{tag}_sw_r = #{tag}_wr[17..17]",
        "    #{tag}_sw_i = #{tag}_wi[17..17]"
      ] ++
      mul ++
      [
        "    # Exact complex sum, then one round-half-up: (s + 2^15) >>> 16.",
        "    #{tag}_half = 32768",
        "    #{tag}_er = #{sxp.("#{tag}m_rr")} - #{sxp.("#{tag}m_ii")} + #{tag}_half",
        "    #{tag}_ei = #{sxp.("#{tag}m_ri")} + #{sxp.("#{tag}m_ir")} + #{tag}_half",
        "    #{tag}_or = #{tag}_er[#{15 + wo}..16]",
        "    #{tag}_oi = #{tag}_ei[#{15 + wo}..16]"
      ]

  seq =
    [
      "",
      "  on :clk do",
      "    #{tag}m_v = #{src}_v",
      "    if #{src}_v == 1 do"
    ] ++
      Enum.map(prods, fn {x, _, _} -> "      #{tag}m_#{x} = #{tag}_m_#{x}" end) ++
      [
        "      #{tag}m_p = #{src}_p",
        "      #{tag}m_l = #{src}_l",
        "      #{tag}m_t = #{src}_t",
        "    end",
        "  end",
        "",
        "  on :clk do",
        "    #{tag}_v = #{tag}m_v",
        "    if #{tag}m_v == 1 do",
        "      #{tag}_r = #{tag}_or",
        "      #{tag}_i = #{tag}_oi",
        "      #{tag}_p = #{tag}m_p",
        "      #{tag}_l = #{tag}m_l",
        "      #{tag}_t = #{tag}m_t",
        "    end",
        "  end"
      ]

  {decls, comb, seq}
end

parts =
  Enum.map(blocks, fn
    {_, :tw, _, _, _, _} = b -> gen_tw.(b)
    b -> gen_bf.(b)
  end)

decls = Enum.flat_map(parts, &elem(&1, 0))
comb = Enum.flat_map(parts, &elem(&1, 1))
seq = Enum.flat_map(parts, &elem(&1, 2))

header = ~S'''
defmodule Hw.Fft64 do
  @moduledoc """
  64-point FFT, radix-2^2 single-path delay feedback (SDF), decimation in
  frequency: the OcuSync receive block after CP removal (nervezynq
  notes/ocusync/02). GENERATED by `scripts/gen_fft64.exs`; edit the
  generator, not this file.

  Bit-exact twin of `OcuSync.Phy.FftFixed` (nervezynq/ocusync) and of the
  model in `test/fft64_test.exs`.

  Six butterfly stages with feedback delays 32, 16, 8, 4, 2, 1 (BF2I,
  BF2II alternating; BF2II applies the exact -j to the second operand of a
  k1 = 1 group), and a twiddle multiplier after stages 2 and 4. Each stage
  carries the 6-bit stream position of its sample (`p`, position minus the
  stage delay) and the `live` flag with the data, so every control bit is
  a slice of the position it arrives with.

  Twiddles: W_64^m as 18-bit Q1.16 (W^0 = 65536), a 64-entry ROM per
  multiplier indexed by stream position. The complex sum of the four exact
  products is rounded once, `(s + 2^15) >>> 16`. Products use the LtfSync
  idiom: an unsigned multiply corrected by the operand signs, so the EHDL
  simulator and the emitted Verilog agree by construction.

  Widths, signed: in 18; stages 19, 20; twiddle 21; 22, 23; twiddle 24;
  25, 26 = out. No scaling, no output rounding.

  Stream contract: `in_valid` at most every 4 cycles (stages overlap the
  next sample; the twiddle blocks are two cycles each). Samples are taken
  in symbols of 64 from `enable`; symbol k's bins leave while symbol k + 1
  enters (63 samples of latency: one more symbol, or 63 zeros, flushes the
  last). `out_valid` marks bins of real symbols only (the first 63 outputs
  after `enable` are pipeline fill). Bins leave in bit-reversed order:
  `out_pos` counts 0..63 within the symbol, `out_bin` = bitrev6(out_pos)
  is the DFT index. `out_tag` is the `in_tag` of the symbol whose bins are
  leaving: latched when input position 63 arrives and carried with the
  stage registers (not through the delay lines).
  """

  use Hw.Component

  clock :clk, freq: 32.0

  input :enable, 1
  input :in_valid, 1
  input :in_i, 18
  input :in_q, 18
  input :in_tag, 12

  output :out_valid, 1
  output :out_i, 26
  output :out_q, 26
  output :out_pos, 6
  output :out_bin, 6
  output :out_tag, 12

  # --- s0: input register, position counter, live after 63 samples -------
  wire :cnt, 6, init: 0
  wire :seen, 6, init: 0
  wire :tagq, 12, init: 0
'''

src = [
  String.trim_trailing(header),
  regs.("s0", 18) |> Enum.join("\n"),
  Enum.join(decls, "\n"),
  "",
  "  comb do",
  "    out_valid = if s6_l == 1 do s6_v else 0 end",
  "    out_i = s6_r",
  "    out_q = s6_i",
  "    out_pos = s6_p",
  "    out_tag = s6_t",
  "    out_bin = {s6_p[0..0], s6_p[1..1], s6_p[2..2], s6_p[3..3], s6_p[4..4], s6_p[5..5]}",
  Enum.join(comb, "\n"),
  "  end",
  "",
  "  on :clk do",
  "    if enable == 0 do",
  "      s0_v = 0",
  "      cnt = 0",
  "      seen = 0",
  "    else",
  "      s0_v = in_valid",
  "      if in_valid == 1 do",
  "        s0_r = in_i",
  "        s0_i = in_q",
  "        s0_p = cnt",
  "        if cnt == 63 do",
  "          s0_t = in_tag",
  "          tagq = in_tag",
  "        else",
  "          s0_t = tagq",
  "        end",
  "        cnt = cnt + 1",
  "        if seen == 63 do",
  "          s0_l = 1",
  "        else",
  "          s0_l = 0",
  "          seen = seen + 1",
  "        end",
  "      end",
  "    end",
  "  end",
  Enum.join(seq, "\n"),
  "end",
  ""
]

out = Path.expand("../lib/hw/std/fft64.ex", __DIR__)
File.write!(out, Enum.join(src, "\n"))
IO.puts("wrote #{out} (#{out |> File.read!() |> String.split("\n") |> length()} lines)")
