# Memory operations: Mem (declaration), MemRead, MemWrite

defmodule Hw.IR.Ops.Mem do
  @moduledoc """
  Memory declaration (block RAM or distributed).

  This declares a memory array. Actual reads/writes are separate ops.
  Synthesis tools infer block RAM vs distributed based on size.

  sync_read: true = registered output (1 cycle latency, better for block RAM)
  sync_read: false = async read (combinational, works for distributed RAM)
  """

  @enforce_keys [:name, :width, :depth]
  defstruct [:name, :width, :depth, :init, sync_read: false]
end

defmodule Hw.IR.Ops.MemRead do
  @moduledoc """
  Memory read operation.

  clock: nil = async read (combinational)
  clock: signal = sync read (registered output)
  """

  @enforce_keys [:output, :memory, :addr]
  defstruct [:output, :memory, :addr, :clock]
end

defmodule Hw.IR.Ops.MemWrite do
  @moduledoc """
  Memory write operation.

  Always synchronous (clocked). Enable signal controls write.
  """

  @enforce_keys [:memory, :addr, :data, :enable, :clock]
  defstruct [:memory, :addr, :data, :enable, :clock]
end
