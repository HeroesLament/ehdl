defmodule Hw do
  @moduledoc """
  Hardware elaboration and emission library.

  Hw takes explicit hardware descriptions and emits boring, correct Verilog.

  ## Philosophy

  - No inference: widths, signedness, clocks must be explicit
  - No surprises: output Verilog is what you'd write by hand
  - Fail early: bad designs error at elaboration, not simulation

  ## Quick Start (DSL)

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

  ## Quick Start (IR directly)

      alias Hw.IR.{Design, Types, Ops}
      alias Types.{Signal, Clock, Const}

      design = Design.new(:adder)
      |> Design.add_clock(Clock.posedge(:clk))
      |> Design.add_signal(Signal.input(:a, 16, signed: :signed))
      # ... etc

      verilog = Hw.compile!(design)
  """

  alias Hw.IR.Design
  alias Hw.Compile.{Validate, Elaborate}
  alias Hw.Emit.Verilog

  @doc """
  Validate a design against all hardware rules.

  Accepts either a `%Design{}` struct or a module that `use`s `Hw.Component`.

  Returns `{:ok, design}` if valid, `{:error, errors}` otherwise.
  """
  def validate(module) when is_atom(module) do
    module.__hw_design__() |> validate()
  end

  def validate(%Design{} = design) do
    Validate.validate(design)
  end

  @doc """
  Validate a design, raising on error.
  """
  def validate!(module) when is_atom(module) do
    module.__hw_design__() |> validate!()
  end

  def validate!(%Design{} = design) do
    Validate.validate!(design)
  end

  @doc """
  Emit a design as Verilog text.

  Accepts either a `%Design{}` struct or a module that `use`s `Hw.Component`.
  """
  def emit(module_or_design, opts \\ [])

  def emit(module, opts) when is_atom(module) do
    module.__hw_design__() |> emit(opts)
  end

  def emit(%Design{} = design, opts) do
    Verilog.emit(design, opts)
  end

  @doc """
  Validate and emit in one step.

  Returns `{:ok, verilog_string}` or `{:error, errors}`.
  """
  def compile(module_or_design, opts \\ [])

  def compile(module, opts) when is_atom(module) do
    module.__hw_design__() |> compile(opts)
  end

  def compile(%Design{} = design, opts) do
    with {:ok, design} <- validate(design) do
      {:ok, emit(design, opts)}
    end
  end

  @doc """
  Validate and emit, raising on error.
  """
  def compile!(module_or_design, opts \\ [])

  def compile!(module, opts) when is_atom(module) do
    module.__hw_design__() |> compile!(opts)
  end

  def compile!(%Design{} = design, opts) do
    design |> validate!() |> emit(opts)
  end

  @doc """
  Compile module(s) and write to file.

  ## Examples

      Hw.to_file!(MyCounter, "counter.v")
      Hw.to_file!([Mod1, Mod2], "design.v")
  """
  def to_file!(module_or_list, path, opts \\ [])

  def to_file!(modules, path, opts) when is_list(modules) do
    verilog = modules
    |> Enum.map(&compile!(&1, opts))
    |> Enum.join("\n")

    File.write!(path, verilog)
    path
  end

  def to_file!(module, path, opts) when is_atom(module) do
    to_file!([module], path, opts)
  end

  @doc """
  Elaborate a module into IR without validation.

  Useful for debugging the elaboration process.
  """
  def elaborate(module) when is_atom(module) do
    Elaborate.elaborate(module)
  end

  @doc """
  Get the raw IR from a module.
  """
  def design(module) when is_atom(module) do
    module.__hw_design__()
  end
end

# Convenience alias so users can `use Hw.Component`
defmodule Hw.Component do
  @moduledoc """
  Alias for `Hw.DSL.Component`.

  Use this to define hardware components:

      defmodule MyDesigns.Counter do
        use Hw.Component

        clock :clk
        input :en, 1
        output :count, 8

        on :clk do
          if en, do: count <= count + 1
        end
      end
  """

  defmacro __using__(opts) do
    quote do
      use Hw.DSL.Component, unquote(opts)
    end
  end
end
