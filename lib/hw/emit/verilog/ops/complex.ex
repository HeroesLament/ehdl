defmodule Hw.Emit.Verilog.Ops.Complex do
  @moduledoc "Verilog emission for complex number operations."

  alias Hw.IR.Ops.{ComplexMul, ComplexAdd, ComplexSub, ComplexMagSq, ComplexConj}
  import Hw.Emit.Verilog.Ops.Value, only: [emit_value: 1]

  # Complex multiply: (a+jb)(c+jd) = (ac-bd) + j(ad+bc)
  def emit(%ComplexMul{output_re: out_re, output_im: out_im,
                       a_re: a_re, a_im: a_im, b_re: b_re, b_im: b_im}) do
    a_re_v = emit_value(a_re)
    a_im_v = emit_value(a_im)
    b_re_v = emit_value(b_re)
    b_im_v = emit_value(b_im)

    # Use $signed to ensure arithmetic is signed
    [
      "  assign #{out_re.name} = $signed(#{a_re_v}) * $signed(#{b_re_v}) - $signed(#{a_im_v}) * $signed(#{b_im_v});",
      "  assign #{out_im.name} = $signed(#{a_re_v}) * $signed(#{b_im_v}) + $signed(#{a_im_v}) * $signed(#{b_re_v});"
    ]
  end

  # Complex add
  def emit(%ComplexAdd{output_re: out_re, output_im: out_im,
                       a_re: a_re, a_im: a_im, b_re: b_re, b_im: b_im}) do
    [
      "  assign #{out_re.name} = #{emit_value(a_re)} + #{emit_value(b_re)};",
      "  assign #{out_im.name} = #{emit_value(a_im)} + #{emit_value(b_im)};"
    ]
  end

  # Complex subtract
  def emit(%ComplexSub{output_re: out_re, output_im: out_im,
                       a_re: a_re, a_im: a_im, b_re: b_re, b_im: b_im}) do
    [
      "  assign #{out_re.name} = #{emit_value(a_re)} - #{emit_value(b_re)};",
      "  assign #{out_im.name} = #{emit_value(a_im)} - #{emit_value(b_im)};"
    ]
  end

  # Magnitude squared: re² + im²
  def emit(%ComplexMagSq{output: out, a_re: a_re, a_im: a_im}) do
    a_re_v = emit_value(a_re)
    a_im_v = emit_value(a_im)
    "  assign #{out.name} = $signed(#{a_re_v}) * $signed(#{a_re_v}) + $signed(#{a_im_v}) * $signed(#{a_im_v});"
  end

  # Conjugate: (re, -im)
  def emit(%ComplexConj{output_re: out_re, output_im: out_im, a_re: a_re, a_im: a_im}) do
    [
      "  assign #{out_re.name} = #{emit_value(a_re)};",
      "  assign #{out_im.name} = -#{emit_value(a_im)};"
    ]
  end
end
