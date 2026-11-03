defmodule Hw.RotTab do
  @moduledoc """
  Table rotator: `(x, y)` rotated by `a` (signed 16-bit turns) with the gain
  of the 16-step CORDIC it replaces (K = 1.6468), on two DSP-mapped products
  per output and a quarter-wave cosine table, instead of 17 fabric adder
  stages.

      p = ((a + 8) >> 4) mod 4096        12-bit phase, rounded
      q = p >> 10, r = p mod 1024        quadrant, residual
      (x1, y1) = (x, y) rotated by q * 90 degrees (exact)
      C = T[r], S = (r == 0 ? 0 : T[1024 - r])
      T[i] = round(K * 65536 * cos(2 pi i / 4096))
      xo = (x1 C - y1 S + 32768) >> 16
      yo = (x1 S + y1 C + 32768) >> 16

  `model/3` is that, in Elixir; it is the spec the block twins and tests
  use (`OcuSync.Phy.SyncFixed.rotate/3` computes the same thing
  independently). Phase error is at most 2^-13 turn (0.044 degree); the
  products round to nearest, so there is no floor-shift DC bias.

  x and y are 25-bit two's complement (|x|, |y| < 2^24); xo and yo are
  27-bit. `tag` rides along. Latency 2: inputs on cycle n (with `in_v`),
  outputs registered at the end of cycle n + 1, valid on n + 2. One input
  per cycle.
  """

  use Hw.Component

  @k Enum.reduce(0..15, 1.0, fn i, acc -> acc * :math.sqrt(1 + :math.pow(2, -2 * i)) end)
  @table for i <- 0..1023, do: round(@k * 65536 * :math.cos(2 * :math.pi() * i / 4096))

  @doc "CORDIC gain the table carries."
  def gain, do: @k

  @doc "Quarter-wave table entries T[0..1023]."
  def table, do: @table

  @doc "Bit-exact model of the block."
  def model(x, y, a) do
    p = Bitwise.band(Bitwise.bsr(a + 8, 4), 4095)
    q = Bitwise.bsr(p, 10)
    r = Bitwise.band(p, 1023)

    {x1, y1} =
      case q do
        0 -> {x, y}
        1 -> {-y, x}
        2 -> {-x, -y}
        3 -> {y, -x}
      end

    c = Enum.at(@table, r)
    s = if r == 0, do: 0, else: Enum.at(@table, 1024 - r)
    {Bitwise.bsr(x1 * c - y1 * s + 32768, 16), Bitwise.bsr(x1 * s + y1 * c + 32768, 16)}
  end

  clock :clk, freq: 32.0

  input :in_v, 1
  input :x, 25
  input :y, 25
  input :a, 16
  input :tag, 48

  output :out_v, 1
  output :xo, 27
  output :yo, 27
  output :out_tag, 48

  memory :ctab, width: 18, depth: 1024, sync_read: :clk, init: @table
  memory :stab, width: 18, depth: 1024, sync_read: :clk, init: @table

  wire :rtz18, 18
  wire :rtz25, 25
  wire :rtz43, 43
  wire :c8, 16
  wire :c32k, 43

  wire :ap, 16
  wire :q, 2
  wire :r, 10
  wire :rs, 10
  wire :nx, 25
  wire :ny, 25
  wire :xq, 25
  wire :yq, 25

  wire :iv, 1
  wire :itag, 48
  wire :v1, 1, init: 0
  wire :tag1, 48, init: 0
  wire :x1, 25, init: 0
  wire :y1, 25, init: 0
  wire :z1, 1, init: 0

  wire :tc, 18
  wire :ts, 18
  wire :c, 18
  wire :s, 18

  wire :pxc_u, 43
  wire :pxc_ka, 43
  wire :pxc, 43
  wire :pys_u, 43
  wire :pys_ka, 43
  wire :pys, 43
  wire :pxs_u, 43
  wire :pxs_ka, 43
  wire :pxs, 43
  wire :pyc_u, 43
  wire :pyc_ka, 43
  wire :pyc, 43
  wire :sx, 43
  wire :sy, 43


  comb do
    rtz18 = 0
    rtz25 = 0
    rtz43 = 0
    c8 = 8
    iv = in_v
    itag = tag
    c32k = 32768

    ap = a + c8
    q = ap[15..14]
    r = ap[13..4]
    rs = rtz18[9..0] - r
    tc = ctab[r]
    ts = stab[rs]

    nx = rtz25 - x
    ny = rtz25 - y
    xq = x
    yq = y

    case q do
      0 ->
        xq = x
        yq = y

      1 ->
        xq = ny
        yq = x

      2 ->
        xq = nx
        yq = ny

      3 ->
        xq = y
        yq = nx
    end

    c = tc
    s = if z1 == 1 do rtz18 else ts end

    # Signed products from unsigned ones (C and S are non-negative, so only
    # the x / y sign corrects).
    pxc_u = x1 * c
    pxc_ka = if x1[24..24] == 1 do {c, rtz25} else rtz43 end
    pxc = pxc_u - pxc_ka
    pys_u = y1 * s
    pys_ka = if y1[24..24] == 1 do {s, rtz25} else rtz43 end
    pys = pys_u - pys_ka
    pxs_u = x1 * s
    pxs_ka = if x1[24..24] == 1 do {s, rtz25} else rtz43 end
    pxs = pxs_u - pxs_ka
    pyc_u = y1 * c
    pyc_ka = if y1[24..24] == 1 do {c, rtz25} else rtz43 end
    pyc = pyc_u - pyc_ka

    sx = pxc - pys + c32k
    sy = pxs + pyc + c32k
  end

  on :clk do
    v1 = iv
    tag1 = itag
    x1 = xq
    y1 = yq
    z1 = if r == 0 do 1 else 0 end

    out_v = v1
    out_tag = tag1
    xo = sx[42..16]
    yo = sy[42..16]
  end
end
