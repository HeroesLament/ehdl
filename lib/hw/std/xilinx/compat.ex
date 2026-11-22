defmodule Hw.Xilinx.Compat do
  @moduledoc false
  # Old top-level names for components that moved under `Hw.Xilinx`. Each shim
  # delegates every `__hw_*__/0` callback to the new module, so instantiating
  # the old name elaborates to exactly the same design. Kept until the designs
  # outside this repo that use the old names (picobeam `xc7_m5_top`, mimohalow
  # `designs/libresdr/top`) have moved over; then delete this file.

  defmacro delegate_component(target) do
    quote bind_quoted: [target: target] do
      Code.ensure_compiled!(target)

      for {fun, 0} <- target.__info__(:functions),
          String.starts_with?(Atom.to_string(fun), "__hw_") do
        defdelegate unquote(fun)(), to: target
      end
    end
  end
end

defmodule Hw.PS7 do
  @moduledoc "Renamed `Hw.Xilinx.PS7`. This alias delegates to it."
  require Hw.Xilinx.Compat
  Hw.Xilinx.Compat.delegate_component(Hw.Xilinx.PS7)
end

defmodule Hw.PS7AXI do
  @moduledoc "Renamed `Hw.Xilinx.PS7AXI`. This alias delegates to it."
  require Hw.Xilinx.Compat
  Hw.Xilinx.Compat.delegate_component(Hw.Xilinx.PS7AXI)
end

defmodule Hw.PS7HP do
  @moduledoc "Renamed `Hw.Xilinx.PS7HP`. This alias delegates to it."
  require Hw.Xilinx.Compat
  Hw.Xilinx.Compat.delegate_component(Hw.Xilinx.PS7HP)
end
