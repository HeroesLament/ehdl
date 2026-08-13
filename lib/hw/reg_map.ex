defmodule Hw.RegMap do
  @moduledoc """
  A register map declared once, consumed by both the fabric and the driver.

  The bug class this removes: an offset written twice, in two languages, that
  silently disagree. This project has already paid for that twice -- a control
  bit read at the wrong index, and a capture address mask carried by hand at
  every call site.

  A spec is a map of `register_name => [{field_name, access, width}, ...]`.
  Fields pack **LSB-first in declaration order**; offsets are computed, never
  written. Anything over 32 bits raises at load time.

  ## Access modes

    * `:rw`      -- CPU writes, fabric reads (a `ctrl*` word)
    * `:ro`      -- fabric drives, CPU reads (a `status*` word)
    * `:wtoggle` -- CPU flips the bit, fabric edge-detects it as a one-shot
                    command. Chosen over a true write-1-auto-clear pulse
                    because it needs no change to `Hw.AXI4Lite.Slave`, and it
                    is what the capture arm bit already does by hand.

  Use `_pad` for reserved space; it is packed but not exported.
  """

  @word_bits 32

  @type field :: {atom, :rw | :ro | :wtoggle, pos_integer}
  @type spec :: %{atom => [field]}

  @doc "Load and validate a spec file. Raises on overflow or a bad access mode."
  def load!(path) do
    {spec, _} = Code.eval_file(path)
    validate!(spec)
    spec
  end

  @doc "Validate a spec, raising with a specific message on the first problem."
  def validate!(spec) do
    Enum.each(spec, fn {reg, fields} ->
      total =
        Enum.reduce(fields, 0, fn {name, access, width}, off ->
          unless access in [:rw, :ro, :wtoggle] do
            raise ArgumentError, "#{reg}.#{name}: unknown access #{inspect(access)}"
          end

          unless is_integer(width) and width > 0 do
            raise ArgumentError, "#{reg}.#{name}: width must be a positive integer"
          end

          off + width
        end)

      if total > @word_bits do
        raise ArgumentError,
              "register #{reg} overflows: #{total} bits declared, #{@word_bits} available"
      end
    end)

    spec
  end

  @doc """
  Expand a spec into `{field, register, hi, lo, access, width}` tuples.

  This is the only place bit offsets are computed. Both code generators consume
  this, so they cannot drift apart.
  """
  def fields(spec) do
    Enum.flat_map(spec, fn {reg, fields} ->
      {out, _} =
        Enum.map_reduce(fields, 0, fn {name, access, width}, off ->
          {{name, reg, off + width - 1, off, access, width}, off + width}
        end)

      Enum.reject(out, fn {name, _, _, _, _, _} -> name == :_pad end)
    end)
  end

  @doc """
  Emit the EHDL slice lines for a `comb do` block.

  Control fields unpack out of their word; status fields are listed as a
  concatenation to build, since EHDL packs those in the other direction.
  Print it and paste it, or diff it against the design to catch drift.
  """
  def to_ehdl(spec) do
    {ctrl, status} =
      spec
      |> fields()
      |> Enum.split_with(fn {_, _, _, _, a, _} -> a != :ro end)

    unpack =
      ctrl
      |> Enum.map(fn {name, reg, hi, lo, _, _} -> "    #{name} = #{reg}[#{hi}..#{lo}]" end)

    pack =
      status
      |> Enum.group_by(fn {_, reg, _, _, _, _} -> reg end)
      |> Enum.map(fn {reg, fs} ->
        parts =
          fs
          |> Enum.sort_by(fn {_, _, hi, _, _, _} -> -hi end)
          |> Enum.map(fn {name, _, _, _, _, _} -> to_string(name) end)

        used = Enum.reduce(fs, 0, fn {_, _, _, _, _, w}, a -> a + w end)
        pad = if used < @word_bits, do: ["pad#{@word_bits - used}"], else: []
        "    #{reg} = {#{Enum.join(pad ++ parts, ", ")}}"
      end)

    Enum.join(["  # --- control (unpack) ---" | unpack] ++
                ["", "  # --- status (pack) ---" | pack], "\n")
  end

  @doc "Emit the spec as JSON, for tooling or an SVD converter."
  def to_json(spec) do
    body =
      spec
      |> fields()
      |> Enum.map(fn {name, reg, hi, lo, access, width} ->
        ~s(    {"field":"#{name}","register":"#{reg}","hi":#{hi},"lo":#{lo},) <>
          ~s("access":"#{access}","width":#{width}})
      end)
      |> Enum.join(",\n")

    "{\n  \"fields\": [\n" <> body <> "\n  ]\n}\n"
  end
end
