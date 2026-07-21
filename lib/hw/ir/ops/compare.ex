# Comparison operations: Eq, Neq, Lt, Gt, Lte, Gte
# All produce 1-bit output.

defmodule Hw.IR.Ops.Eq do
  @moduledoc "Equality comparison (output is 1-bit)"
  @enforce_keys [:output, :a, :b]
  defstruct [:output, :a, :b]
end

defmodule Hw.IR.Ops.Neq do
  @moduledoc "Inequality comparison (output is 1-bit)"
  @enforce_keys [:output, :a, :b]
  defstruct [:output, :a, :b]
end

defmodule Hw.IR.Ops.Lt do
  @moduledoc "Less than comparison (output is 1-bit)"
  @enforce_keys [:output, :a, :b]
  defstruct [:output, :a, :b]
end

defmodule Hw.IR.Ops.Gt do
  @moduledoc "Greater than comparison (output is 1-bit)"
  @enforce_keys [:output, :a, :b]
  defstruct [:output, :a, :b]
end

defmodule Hw.IR.Ops.Lte do
  @moduledoc "Less than or equal comparison (output is 1-bit)"
  @enforce_keys [:output, :a, :b]
  defstruct [:output, :a, :b]
end

defmodule Hw.IR.Ops.Gte do
  @moduledoc "Greater than or equal comparison (output is 1-bit)"
  @enforce_keys [:output, :a, :b]
  defstruct [:output, :a, :b]
end
