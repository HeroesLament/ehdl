defmodule Hw.Emit.Verilog.Ops.Memory do
  @moduledoc "Verilog emission for memory operations."

  alias Hw.IR.Ops.MemRead
  import Hw.Emit.Verilog.Ops.Value, only: [emit_value: 1]

  # Async memory read (combinational)
  def emit(%MemRead{output: out, memory: mem_name, addr: addr, clock: nil}) do
    "  assign #{out.name} = #{mem_name}[#{emit_value(addr)}];"
  end

  # Sync memory read - emitted in sequential block, not here
  def emit(%MemRead{clock: clock}) when clock != nil do
    nil  # Handled by sequential.ex
  end
end
