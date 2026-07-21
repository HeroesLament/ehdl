defmodule Hw.Interface do
  @moduledoc """
  DSL for defining typed, directional signal bundles.

  An interface is a named contract between two components — a provider
  and a consumer. It declares a set of signals with their widths,
  signedness, and which side drives each one.

  ## Example

      defmodule Hw.Interface.TxPacket do
        use Hw.Interface

        # Signals declared with direction relative to the provider.
        # :provider_drives — provider outputs this, consumer inputs it
        # :consumer_drives — consumer outputs this, provider inputs it

        signal :pkt_req,    1, :consumer_drives
        signal :pkt_ack,    1, :provider_drives
        signal :pkt_pid,    8, :consumer_drives
        signal :byte_data,  8, :consumer_drives
        signal :byte_valid, 1, :consumer_drives
        signal :byte_ready, 1, :provider_drives
        signal :pkt_done,   1, :provider_drives
      end

  ## Parameterized Interfaces

      defmodule Hw.Interface.AXI4 do
        use Hw.Interface

        param :data_width, :pos_integer
        param :addr_width, :pos_integer
        param :id_width,   :pos_integer, default: 1

        signal :awaddr,  {:param, :addr_width},                   :manager_drives
        signal :wdata,   {:param, :data_width},                   :manager_drives
        signal :wstrb,   {:param, :data_width, &div(&1, 8)},      :manager_drives
        signal :awvalid, 1,                                        :manager_drives
        signal :awready, 1,                                        :subordinate_drives
      end

  ## Usage in Components

  Use `provides/2` and `consumes/2` in a `use Hw.Component` module:

      defmodule Hw.USB.SIE do
        use Hw.Component

        provides Hw.Interface.TxPacket, as: :tx
        consumes Hw.Interface.RxPacket, as: :rx
      end

  And `connect/3` in a top-level module:

      defmodule HelloBoard.Top do
        use Hw.Component

        instance :sie, Hw.USB.SIE, ...
        instance :cdc, Hw.USB.CDCSerial, ...

        connect :sie, :tx, :cdc, :tx
      end

  ## Role Naming Convention

  For symmetric interfaces (like AXI), use role-specific names that
  reflect the protocol:
    - AXI4: `:manager_drives` / `:subordinate_drives`
    - APB:  `:requester_drives` / `:completer_drives`

  For simple asymmetric interfaces, `:provider_drives` / `:consumer_drives`
  is the default convention.
  """

  alias Hw.Analysis.Location
  alias Hw.IR.Types.Signal

  @type drive_direction :: :provider_drives | :consumer_drives | atom()

  @type signal_spec :: %{
    name:            atom(),
    width:           Signal.width(),
    signed:          Signal.signedness(),
    drives:          drive_direction(),
    source_location: Location.t() | nil
  }

  @type param_spec :: %{
    name:            atom(),
    constraint:      atom() | {:range, integer(), integer()} | {:one_of, [term()]} | nil,
    default:         term() | nil,
    source_location: Location.t() | nil
  }

  @type t :: %{
    module:  module(),
    signals: [signal_spec()],
    params:  [param_spec()]
  }

  defmacro __using__(_opts) do
    quote do
      import Hw.Interface, only: [signal: 3, signal: 4, param: 2, param: 3]

      # Accumulate signal and param specs at compile time
      Module.register_attribute(__MODULE__, :__hw_interface_signals__, accumulate: true)
      Module.register_attribute(__MODULE__, :__hw_interface_params__,  accumulate: true)

      @before_compile Hw.Interface
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      @doc "All signal specs declared on this interface, in declaration order."
      def __hw_interface_signals__ do
        # Attributes accumulate in reverse order
        Enum.reverse(@__hw_interface_signals__)
      end

      @doc "All param specs declared on this interface, in declaration order."
      def __hw_interface_params__ do
        Enum.reverse(@__hw_interface_params__)
      end

      @doc "Human-readable summary of this interface for debugging."
      def describe do
        params = __hw_interface_params__()
        signals = __hw_interface_signals__()

        param_str = if params == [] do
          ""
        else
          param_lines = Enum.map(params, fn p ->
            default = if p.default, do: " = #{inspect(p.default)}", else: ""
            "  param #{p.name} :: #{p.constraint}#{default}"
          end)
          Enum.join(param_lines, "\n") <> "\n"
        end

        signal_lines = Enum.map(signals, fn s ->
          width_str = case s.width do
            n when is_integer(n)          -> "#{n}"
            {:param, name}                -> "param(#{name})"
            {:param, name, _f}            -> "f(param(#{name}))"
          end
          "  #{s.drives}  #{s.name} :: #{width_str}"
        end)

        "#{inspect(__MODULE__)}\n#{param_str}#{Enum.join(signal_lines, "\n")}"
      end
    end
  end

  @doc """
  Declare a signal on this interface.

  ## Arguments

  - `name` — signal name atom
  - `width` — bit width: integer, `{:param, name}`, or `{:param, name, fun}`
  - `drives` — which role drives this signal
  - `opts` — keyword options: `signed: true`

  ## Examples

      signal :pkt_req,  1,                      :consumer_drives
      signal :wdata,    {:param, :data_width},   :manager_drives
      signal :wstrb,    {:param, :data_width, &div(&1, 8)}, :manager_drives
      signal :data,     8,                       :provider_drives, signed: true
  """
  defmacro signal(name, width, drives, opts \\ []) do
    loc = quote do: Hw.Analysis.Location.from_env(__ENV__)
    quote do
      @__hw_interface_signals__ %{
        name:            unquote(name),
        width:           unquote(width),
        signed:          if(unquote(opts[:signed]), do: :signed, else: :unsigned),
        drives:          unquote(drives),
        source_location: unquote(loc)
      }
    end
  end

  @doc """
  Declare a parameter on this interface.

  Parameters allow interface signal widths to be set at instantiation time.

  ## Examples

      param :data_width, :pos_integer
      param :id_width,   :pos_integer, default: 1
  """
  defmacro param(name, constraint, opts \\ []) do
    loc = quote do: Hw.Analysis.Location.from_env(__ENV__)
    quote do
      @__hw_interface_params__ %{
        name:            unquote(name),
        constraint:      unquote(constraint),
        default:         unquote(opts[:default]),
        source_location: unquote(loc)
      }
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers used by Hw.Analysis
  # ---------------------------------------------------------------------------

  @doc """
  Given an interface module and a role, return the `Signal.direction()`
  for each signal as seen from that role's perspective.

  For a provider, signals the provider drives are `:output`,
  and signals the consumer drives are `:input`.

  For a consumer, it's flipped.
  """
  @spec signal_directions(module(), drive_direction()) ::
    %{atom() => Signal.direction()}
  def signal_directions(interface_module, role) do
    provider_role = provider_role(interface_module)
    consumer_role = consumer_role(interface_module)

    for spec <- interface_module.__hw_interface_signals__(), into: %{} do
      direction = cond do
        spec.drives == provider_role and role == provider_role -> :output
        spec.drives == provider_role and role == consumer_role -> :input
        spec.drives == consumer_role and role == provider_role -> :input
        spec.drives == consumer_role and role == consumer_role -> :output
        true -> :input
      end
      {spec.name, direction}
    end
  end

  @doc """
  Resolve a signal width against a map of param bindings.

  Returns `{:ok, pos_integer()}` if resolved, `{:error, reason}` if not.
  """
  @spec resolve_width(Signal.width(), %{atom() => term()}) ::
    {:ok, pos_integer()} | {:error, String.t()}
  def resolve_width(width, _bindings) when is_integer(width), do: {:ok, width}

  def resolve_width({:param, name}, bindings) do
    case Map.get(bindings, name) do
      nil -> {:error, "unresolved param #{name}"}
      val when is_integer(val) and val > 0 -> {:ok, val}
      val -> {:error, "param #{name} = #{inspect(val)} is not a positive integer"}
    end
  end

  def resolve_width({:param, name, fun}, bindings) do
    case Map.get(bindings, name) do
      nil -> {:error, "unresolved param #{name}"}
      val when is_integer(val) and val > 0 ->
        result = fun.(val)
        if is_integer(result) and result > 0 do
          {:ok, result}
        else
          {:error, "param #{name} resolver returned #{inspect(result)}, expected pos_integer"}
        end
      val -> {:error, "param #{name} = #{inspect(val)} is not a positive integer"}
    end
  end

  # Infer the provider and consumer role names from the interface's signals.
  # Convention: first drive direction seen is the "provider" role.
  defp provider_role(interface_module) do
    interface_module.__hw_interface_signals__()
    |> Enum.map(& &1.drives)
    |> Enum.uniq()
    |> List.first()
  end

  defp consumer_role(interface_module) do
    interface_module.__hw_interface_signals__()
    |> Enum.map(& &1.drives)
    |> Enum.uniq()
    |> Enum.at(1)
  end
end
