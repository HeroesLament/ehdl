defmodule Hw.DSL.Primitives.Declarations do
  @moduledoc """
  Port and signal declaration macros.

  Every macro captures `__CALLER__` at expansion time and stores a
  `source_location` field in the registered attribute map. This is
  consumed by `Hw.Analysis` and the LSP server for diagnostics and
  go-to-definition.

  ## Structural type annotations

  The `wire`, `input`, `output`, and `inout` macros accept four optional
  structural type keyword arguments:

    - `clock_domain:` — which clock domain owns this signal (atom)
    - `sense:` — active logic level: `:high` (default) or `:low`
    - `endian:` — byte order for multi-byte signals: `:little` or `:big`
    - `persist:` — reset scope: `:full` (default) or `:power_on_only`

  The `clock` macro accepts:

    - `freq:` — frequency in MHz (existing)
    - `domain:` — domain name atom, defaults to the clock name
    - `reset:` — reset signal name (atom) for this domain
    - `reset_style:` — `:sync` (default), `:async`, or `:none`
  """

  alias Hw.Analysis.Location

  defp normalize_width({:__aliases__, _, [name]}) when is_atom(name), do: name
  defp normalize_width({op, _, [a, b]}) when op in [:+, :-, :*, :/] do
    Macro.escape({op, normalize_width(a), normalize_width(b)})
  end
  defp normalize_width({:div, _, [a, b]}) do
    Macro.escape({:div, normalize_width(a), normalize_width(b)})
  end
  defp normalize_width({:clog2, _, [a]}) do
    Macro.escape({:clog2, normalize_width(a)})
  end
  defp normalize_width(width), do: width

  defmacro param(name, opts \\ []) do
    loc = Location.from_env(__CALLER__)
    quote do
      @hw_params %{
        name:            unquote(name),
        default:         Keyword.get(unquote(opts), :default, nil),
        source_location: unquote(Macro.escape(loc))
      }
    end
  end

  defmacro clock(name, opts \\ []) do
    loc = Location.from_env(__CALLER__)
    quote do
      @hw_clocks %{
        name:            unquote(name),
        edge:            Keyword.get(unquote(opts), :edge, :posedge),
        freq_mhz:        Keyword.get(unquote(opts), :freq, nil),
        # Clock domain — defaults to the clock name if not specified
        domain:          Keyword.get(unquote(opts), :domain, unquote(name)),
        # Reset properties for this clock domain
        reset:           Keyword.get(unquote(opts), :reset, nil),
        reset_style:     Keyword.get(unquote(opts), :reset_style, :sync),
        source_location: unquote(Macro.escape(loc))
      }
    end
  end

  defmacro input(name, width, opts \\ []) do
    width = normalize_width(width)
    loc   = Location.from_env(__CALLER__)
    quote do
      @hw_signals %{
        name:            unquote(name),
        width:           unquote(width),
        direction:       :input,
        signed:          if(Keyword.get(unquote(opts), :signed, false), do: :signed, else: :unsigned),
        clock_domain:    Keyword.get(unquote(opts), :clock_domain),
        sense:           Keyword.get(unquote(opts), :sense, :high),
        endian:          Keyword.get(unquote(opts), :endian),
        persist:         Keyword.get(unquote(opts), :persist, :full),
        source_location: unquote(Macro.escape(loc))
      }
    end
  end

  defmacro output(name, width, opts \\ []) do
    width = normalize_width(width)
    loc   = Location.from_env(__CALLER__)
    quote do
      @hw_signals %{
        name:            unquote(name),
        width:           unquote(width),
        direction:       :output,
        signed:          if(Keyword.get(unquote(opts), :signed, false), do: :signed, else: :unsigned),
        init:            Keyword.get(unquote(opts), :init),
        clock_domain:    Keyword.get(unquote(opts), :clock_domain),
        sense:           Keyword.get(unquote(opts), :sense, :high),
        endian:          Keyword.get(unquote(opts), :endian),
        persist:         Keyword.get(unquote(opts), :persist, :full),
        source_location: unquote(Macro.escape(loc))
      }
    end
  end

  defmacro wire(name, width, opts \\ []) do
    width = normalize_width(width)
    loc   = Location.from_env(__CALLER__)
    quote do
      @hw_signals %{
        name:            unquote(name),
        width:           unquote(width),
        direction:       :internal,
        signed:          if(Keyword.get(unquote(opts), :signed, false), do: :signed, else: :unsigned),
        init:            Keyword.get(unquote(opts), :init),
        clock_domain:    Keyword.get(unquote(opts), :clock_domain),
        sense:           Keyword.get(unquote(opts), :sense, :high),
        endian:          Keyword.get(unquote(opts), :endian),
        persist:         Keyword.get(unquote(opts), :persist, :full),
        source_location: unquote(Macro.escape(loc))
      }
    end
  end

  defmacro inout(name, width, opts \\ []) do
    width = normalize_width(width)
    loc   = Location.from_env(__CALLER__)
    quote do
      @hw_signals %{
        name:            unquote(name),
        width:           unquote(width),
        direction:       :inout,
        signed:          if(Keyword.get(unquote(opts), :signed, false), do: :signed, else: :unsigned),
        clock_domain:    Keyword.get(unquote(opts), :clock_domain),
        sense:           Keyword.get(unquote(opts), :sense, :high),
        endian:          Keyword.get(unquote(opts), :endian),
        persist:         Keyword.get(unquote(opts), :persist, :full),
        pullmode:        Keyword.get(unquote(opts), :pullmode, :none),
        source_location: unquote(Macro.escape(loc))
      }
    end
  end

  defmacro complex(name, width, opts \\ []) do
    width     = normalize_width(width)
    re_name   = :"#{name}_re"
    im_name   = :"#{name}_im"
    direction = Keyword.get(opts, :direction, :internal)
    init      = Keyword.get(opts, :init)
    loc       = Location.from_env(__CALLER__)

    quote do
      @hw_signals %{
        name:            unquote(re_name),
        width:           unquote(width),
        direction:       unquote(direction),
        signed:          :signed,
        init:            unquote(init),
        source_location: unquote(Macro.escape(loc))
      }
      @hw_signals %{
        name:            unquote(im_name),
        width:           unquote(width),
        direction:       unquote(direction),
        signed:          :signed,
        init:            unquote(init),
        source_location: unquote(Macro.escape(loc))
      }
      @hw_complex %{name: unquote(name), width: unquote(width)}
    end
  end

  defmacro memory(name, opts) do
    {width, opts} = Keyword.pop!(opts, :width)
    {depth, opts} = Keyword.pop!(opts, :depth)
    width = normalize_width(width)
    depth = normalize_width(depth)
    loc   = Location.from_env(__CALLER__)

    quote do
      init_val = case {Keyword.get(unquote(opts), :init), Keyword.get(unquote(opts), :init_file)} do
        {nil, nil}  -> nil
        {list, nil} when is_list(list) -> list
        {nil, file} when is_binary(file) -> {:file, file}
        {_, _} -> raise ArgumentError, "Cannot specify both :init and :init_file"
      end

      @hw_memories %{
        name:            unquote(name),
        width:           unquote(width),
        depth:           unquote(depth),
        init:            init_val,
        sync_read:       Keyword.get(unquote(opts), :sync_read, false),
        source_location: unquote(Macro.escape(loc))
      }
    end
  end

  defmacro blackbox(name, module_name, opts) do
    loc = Location.from_env(__CALLER__)
    quote do
      @hw_blackboxes %{
        name:            unquote(name),
        module:          unquote(module_name),
        params:          Keyword.get(unquote(opts), :params, []),
        ports:           Keyword.fetch!(unquote(opts), :ports),
        attrs:           Keyword.get(unquote(opts), :attrs, []),
        source_location: unquote(Macro.escape(loc))
      }
    end
  end

  defmacro tristate(name, opts) do
    loc = Location.from_env(__CALLER__)
    quote do
      @hw_tristates %{
        name:            unquote(name),
        io:              Keyword.fetch!(unquote(opts), :io),
        output:          Keyword.fetch!(unquote(opts), :output),
        enable:          Keyword.fetch!(unquote(opts), :enable),
        input:           Keyword.fetch!(unquote(opts), :input),
        source_location: unquote(Macro.escape(loc))
      }
    end
  end

  defmacro provides(interface_module, opts) do
    name = Keyword.fetch!(opts, :as)
    loc  = Location.from_env(__CALLER__)
    quote do
      @hw_interface_bindings %{
        name:            unquote(name),
        interface:       unquote(interface_module),
        role:            :provider,
        source_location: unquote(Macro.escape(loc))
      }
    end
  end

  defmacro consumes(interface_module, opts) do
    name = Keyword.fetch!(opts, :as)
    loc  = Location.from_env(__CALLER__)
    quote do
      @hw_interface_bindings %{
        name:            unquote(name),
        interface:       unquote(interface_module),
        role:            :consumer,
        source_location: unquote(Macro.escape(loc))
      }
    end
  end
end
