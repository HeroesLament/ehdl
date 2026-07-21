# Complex number operations for DSP

defmodule Hw.IR.Ops.ComplexMul do
  @moduledoc """
  Complex multiplication.

  (a_re + j*a_im) * (b_re + j*b_im) =
    (a_re*b_re - a_im*b_im) + j*(a_re*b_im + a_im*b_re)
  """

  @enforce_keys [:output_re, :output_im, :a_re, :a_im, :b_re, :b_im]
  defstruct [:output_re, :output_im, :a_re, :a_im, :b_re, :b_im]
end

defmodule Hw.IR.Ops.ComplexAdd do
  @moduledoc """
  Complex addition.

  (a_re + j*a_im) + (b_re + j*b_im) =
    (a_re + b_re) + j*(a_im + b_im)
  """

  @enforce_keys [:output_re, :output_im, :a_re, :a_im, :b_re, :b_im]
  defstruct [:output_re, :output_im, :a_re, :a_im, :b_re, :b_im]
end

defmodule Hw.IR.Ops.ComplexSub do
  @moduledoc """
  Complex subtraction.

  (a_re + j*a_im) - (b_re + j*b_im) =
    (a_re - b_re) + j*(a_im - b_im)
  """

  @enforce_keys [:output_re, :output_im, :a_re, :a_im, :b_re, :b_im]
  defstruct [:output_re, :output_im, :a_re, :a_im, :b_re, :b_im]
end

defmodule Hw.IR.Ops.ComplexMagSq do
  @moduledoc """
  Complex magnitude squared.

  |a|² = a_re² + a_im²

  Avoids the sqrt needed for actual magnitude.
  """

  @enforce_keys [:output, :a_re, :a_im]
  defstruct [:output, :a_re, :a_im]
end

defmodule Hw.IR.Ops.ComplexConj do
  @moduledoc """
  Complex conjugate.

  conj(a_re + j*a_im) = a_re - j*a_im
  """

  @enforce_keys [:output_re, :output_im, :a_re, :a_im]
  defstruct [:output_re, :output_im, :a_re, :a_im]
end
