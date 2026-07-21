defmodule Hw.DSL.Component do
  @moduledoc """
  DSL for defining hardware components.

  ## Example

      defmodule MyDesigns.Counter do
        use Hw.Component

        clock :clk
        input :rst, 1
        input :en, 1
        output :count, 8

        on :clk do
          if rst do
            count <= 0
          else
            if en do
              count <= count + 1
            end
          end
        end
      end

      verilog = Hw.compile!(MyDesigns.Counter)

  ## How it works

  Macros collect declarations into module attributes.
  At compile time, `@before_compile` builds the IR.
  The module then exposes `__hw_design__/0` which returns the IR.

  ## Source Locations

  Every declaration macro captures `__ENV__` at expansion time and
  stores a `source_location` field. This is used by `Hw.Analysis`
  and the LSP server for diagnostics and go-to-definition.
  """

  defmacro __using__(_opts) do
    quote do
      import Hw.DSL.Component
      import Hw.DSL.Primitives.Declarations
      import Hw.DSL.Primitives.LogicBlocks

      Module.register_attribute(__MODULE__, :hw_params,      accumulate: true)
      Module.register_attribute(__MODULE__, :hw_clocks,      accumulate: true)
      Module.register_attribute(__MODULE__, :hw_signals,     accumulate: true)
      Module.register_attribute(__MODULE__, :hw_logic,       accumulate: true)
      Module.register_attribute(__MODULE__, :hw_instances,   accumulate: true)
      Module.register_attribute(__MODULE__, :hw_interfaces,  accumulate: true)
      Module.register_attribute(__MODULE__, :hw_connections, accumulate: true)
      Module.register_attribute(__MODULE__, :hw_defhw,       accumulate: true)
      Module.register_attribute(__MODULE__, :hw_memories,    accumulate: true)
      Module.register_attribute(__MODULE__, :hw_blackboxes,  accumulate: true)
      Module.register_attribute(__MODULE__, :hw_tristates,   accumulate: true)
      Module.register_attribute(__MODULE__, :hw_complex,     accumulate: true)
      Module.register_attribute(__MODULE__, :hw_fsm,         accumulate: true)

      # Interface bindings registered by provides/consumes (step [2])
      Module.register_attribute(__MODULE__, :hw_interface_bindings, accumulate: true)

      @before_compile Hw.DSL.Component
    end
  end

  defmacro __before_compile__(env) do
    params      = Module.get_attribute(env.module, :hw_params)      |> Enum.reverse()
    clocks      = Module.get_attribute(env.module, :hw_clocks)      |> Enum.reverse()
    signals     = Module.get_attribute(env.module, :hw_signals)     |> Enum.reverse()
    logic       = Module.get_attribute(env.module, :hw_logic)       |> Enum.reverse()
    instances   = Module.get_attribute(env.module, :hw_instances)   |> Enum.reverse()
    interfaces  = Module.get_attribute(env.module, :hw_interfaces)  |> Enum.reverse()
    connections = Module.get_attribute(env.module, :hw_connections) |> Enum.reverse()
    memories    = Module.get_attribute(env.module, :hw_memories)    |> Enum.reverse()
    blackboxes  = Module.get_attribute(env.module, :hw_blackboxes)  |> Enum.reverse()
    tristates   = Module.get_attribute(env.module, :hw_tristates)   |> Enum.reverse()
    complex     = Module.get_attribute(env.module, :hw_complex)     |> Enum.reverse()
    fsms        = Module.get_attribute(env.module, :hw_fsm)         |> Enum.reverse()
    defhws      = Module.get_attribute(env.module, :hw_defhw)       |> Enum.reverse()
    iface_bindings = Module.get_attribute(env.module, :hw_interface_bindings) |> Enum.reverse()

    design_name = env.module
      |> Module.split()
      |> List.last()
      |> Macro.underscore()
      |> String.to_atom()

    quote do
      @doc false
      def __hw_params__,             do: unquote(Macro.escape(params))

      @doc false
      def __hw_clocks__,             do: unquote(Macro.escape(clocks))

      @doc false
      def __hw_signals__,            do: unquote(Macro.escape(signals))

      @doc false
      def __hw_logic__,              do: unquote(Macro.escape(logic))

      @doc false
      def __hw_instances__,          do: unquote(Macro.escape(instances))

      @doc false
      def __hw_interfaces__,         do: unquote(Macro.escape(interfaces))

      @doc false
      def __hw_connections__,        do: unquote(Macro.escape(connections))

      @doc false
      def __hw_memories__,           do: unquote(Macro.escape(memories))

      @doc false
      def __hw_blackboxes__,         do: unquote(Macro.escape(blackboxes))

      @doc false
      def __hw_tristates__,          do: unquote(Macro.escape(tristates))

      @doc false
      def __hw_complex__,            do: unquote(Macro.escape(complex))

      @doc false
      def __hw_fsm__,                do: unquote(Macro.escape(fsms))

      @doc false
      def __hw_defhw__,              do: unquote(Macro.escape(defhws))

      @doc false
      def __hw_design_name__,        do: unquote(design_name)

      @doc """
      Interface bindings declared via `provides/2` and `consumes/2`.
      Used by `Hw.Analysis` to verify interface connections.
      """
      def __hw_interface_bindings__, do: unquote(Macro.escape(iface_bindings))

      @doc """
      Returns the elaborated hardware IR for this component.
      """
      def __hw_design__ do
        Hw.Compile.Elaborate.elaborate(__MODULE__)
      end
    end
  end
end
