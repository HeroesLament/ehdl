# Generate clean Verilog for synthesis testing
# Run with: mix run examples/synth_test.exs
# Then: yosys -p "read_verilog synth_test.v; synth; stat"

defmodule Test.Counter do
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

defmodule Test.RAM do
  use Hw.Component
  clock :clk
  input :addr, 4
  input :din, 8
  input :we, 1
  output :dout, 8

  memory :ram, width: 8, depth: 16

  comb do
    dout <= ram[addr]
  end

  on :clk do
    if we do
      ram[addr] <= din
    end
  end
end

defmodule Test.Comparator do
  use Hw.Component
  input :a, 8
  input :b, 8
  output :lt, 1
  output :gt, 1
  output :eq, 1

  comb do
    lt <= (a < b)
    gt <= (a > b)
    eq <= (a == b)
  end
end

defmodule Test.Shifter do
  use Hw.Component
  input :a, 8
  output :shl, 8
  output :shr, 8

  comb do
    shl <= (a <<< 2)
    shr <= (a >>> 2)
  end
end

defmodule Test.BitManip do
  use Hw.Component
  input :w, 16
  output :hi, 8
  output :lo, 8
  output :swap, 16

  comb do
    hi <= w[15..8]
    lo <= w[7..0]
    swap <= {w[7..0], w[15..8]}
  end
end

defmodule Test.Multiplier do
  use Hw.Component
  input :a, 8
  input :b, 8
  output :product, 16

  comb do
    product <= a * b
  end
end

defmodule Test.Negation do
  use Hw.Component
  input :a, 8
  output :neg_a, 8

  comb do
    neg_a <= -a
  end
end

defmodule Test.DivMod do
  use Hw.Component
  input :a, 8
  input :b, 8
  output :quotient, 8
  output :remainder, 8

  comb do
    quotient <= div(a, b)
    remainder <= rem(a, b)
  end
end

defmodule Test.Reduction do
  use Hw.Component
  input :data, 8
  output :all_ones, 1
  output :any_ones, 1
  output :parity, 1

  comb do
    all_ones <= reduce_and(data)
    any_ones <= reduce_or(data)
    parity <= reduce_xor(data)
  end
end

defmodule Test.Replicate do
  use Hw.Component
  input :bit, 1
  output :byte, 8

  comb do
    byte <= replicate(bit, 8)
  end
end

defmodule Test.AsyncReset do
  use Hw.Component
  clock :clk
  input :rst, 1
  input :en, 1
  output :count, 8

  on :clk, async_reset: :rst do
    if rst do
      count <= 0
    else
      if en do
        count <= count + 1
      end
    end
  end
end

defmodule Test.Ternary do
  use Hw.Component
  input :sel, 1
  input :a, 8
  input :b, 8
  output :result, 8

  comb do
    # Ternary expression: if(cond, do: then, else: else)
    result <= if(sel, do: a, else: b)
  end
end

defmodule Test.ArithShift do
  use Hw.Component
  input :a, 8, signed: true
  output :lshr, 8      # Logical shift right
  output :ashr, 8      # Arithmetic shift right (sign-extending)

  comb do
    lshr <= (a >>> 2)         # Logical: fills with 0
    ashr <= shra(a, 2)        # Arithmetic: fills with sign bit
  end
end

defmodule Test.SyncRAM do
  use Hw.Component
  clock :clk
  input :addr, 4
  input :din, 8
  input :we, 1
  output :dout, 8

  # Sync read: output is registered (1 cycle latency)
  memory :ram, width: 8, depth: 16, sync_read: :clk

  comb do
    dout <= ram[addr]
  end

  on :clk do
    if we do
      ram[addr] <= din
    end
  end
end

defmodule Test.ParamCounter do
  use Hw.Component
  param :WIDTH, default: 8
  param :MAX_VAL, default: 255

  clock :clk
  input :rst, 1
  input :en, 1
  output :count, WIDTH
  output :at_max, 1

  on :clk do
    if rst do
      count <= 0
    else
      if en do
        count <= count + 1
      end
    end
  end

  comb do
    at_max <= (count == MAX_VAL)
  end
end

defmodule Test.GenerateAdder do
  use Hw.Component
  param :BASE, default: 0

  input :a, 8
  output :out0, 8
  output :out1, 8
  output :out2, 8
  output :out3, 8

  # Generate adds 0,1,2,3 to input
  comb do
    out0 <= a + BASE
    out1 <= a + BASE + 1
    out2 <= a + BASE + 2
    out3 <= a + BASE + 3
  end
end

defmodule Test.InitValues do
  use Hw.Component
  clock :clk
  input :en, 1
  output :count, 8, init: 0
  output :state, 2, init: 1

  on :clk do
    if en do
      count <= count + 1
      state <= state + 1
    end
  end
end

defmodule Test.ParamArith do
  use Hw.Component
  param :WIDTH, default: 8
  param :DEPTH, default: 256

  input :data, WIDTH
  output :double, WIDTH * 2
  output :addr, clog2(DEPTH)

  comb do
    double <= {data, data}
    addr <= 0
  end
end

defmodule Test.NewPrimitives do
  use Hw.Component

  input :a, 8
  input :b, 8
  input :signed_val, 8, signed: true
  output :pop, 4
  output :minimum, 8
  output :maximum, 8
  output :absolute, 8

  comb do
    pop <= popcount(a)
    minimum <= min(a, b)
    maximum <= max(a, b)
    absolute <= abs(signed_val)
  end
end

defmodule Test.ExtendOps do
  use Hw.Component

  input :narrow, 8
  input :data, 8
  output :par, 1
  output :wide_signed, 16
  output :wide_unsigned, 16
  output :reversed, 8

  comb do
    par <= parity(data)
    wide_signed <= sign_extend(narrow, 16)
    wide_unsigned <= zero_extend(narrow, 16)
    reversed <= reverse_bits(data)
  end
end

defmodule Test.ROMInit do
  use Hw.Component

  input :addr, 4
  output :data, 8

  # ROM with inline init - 16 values (quadrant of sine table, scaled 0-255)
  memory :sin_lut, width: 8, depth: 16, init: [
    128, 152, 176, 198, 217, 233, 245, 252,
    255, 252, 245, 233, 217, 198, 176, 152
  ]

  comb do
    data <= sin_lut[addr]
  end
end

defmodule Test.DSPOps do
  use Hw.Component

  # Simple mul_round test
  input :a, 16, signed: true
  input :b, 16, signed: true
  output :product, 16, signed: true

  comb do
    # Q15 × Q15 → Q15 with rounding
    product <= mul_round(a, b, 15)
  end
end

defmodule Test.SimpleFSM do
  use Hw.Component

  clock :clk
  input :go, 1
  output :count, 8

  fsm :state, clock: :clk, init: :idle do
    case state do
      :idle ->
        count <= 0
        on go == 1, next: :running

      :running ->
        count <= count + 1
        on count == 255, next: :idle
    end
  end
end

# Write all modules to file
modules = [
  Test.Counter,
  Test.RAM,
  Test.Comparator,
  Test.Shifter,
  Test.BitManip,
  Test.Multiplier,
  Test.Negation,
  Test.DivMod,
  Test.Reduction,
  Test.Replicate,
  Test.AsyncReset,
  Test.Ternary,
  Test.ArithShift,
  Test.SyncRAM,
  Test.ParamCounter,
  Test.GenerateAdder,
  Test.InitValues,
  Test.ParamArith,
  Test.NewPrimitives,
  Test.ExtendOps,
  Test.ROMInit,
  Test.DSPOps,
  Test.SimpleFSM,
  # Stdlib
  Hw.CORDIC,
  Hw.FIFO,
  Hw.AXI4Master,
  Hw.AXI4Slave
]

path = "synth_test.v"
Hw.to_file!(modules, path)

IO.puts("Written #{length(modules)} modules to #{path}")
IO.puts("")

# Run yosys synthesis
IO.puts("Running Yosys synthesis...")
IO.puts(String.duplicate("-", 60))

case System.find_executable("yosys") do
  nil ->
    IO.puts("⚠ Yosys not found in PATH")
    IO.puts("Install with: brew install yosys (macOS) or apt install yosys (Linux)")
    IO.puts("Then run: yosys -p \"read_verilog #{path}; synth; stat\"")

  _yosys_path ->
    case System.cmd("yosys", ["-p", "read_verilog #{path}; synth; stat"], stderr_to_stdout: true) do
      {output, 0} ->
        # Extract just the stats section
        output
        |> String.split("\n")
        |> Enum.drop_while(&(not String.contains?(&1, "Printing statistics")))
        |> Enum.take_while(&(not String.contains?(&1, "End of script")))
        |> Enum.join("\n")
        |> IO.puts()

        IO.puts(String.duplicate("-", 60))
        IO.puts("✓ All modules synthesized successfully")

      {output, code} ->
        IO.puts(:stderr, "Yosys failed with exit code #{code}")
        IO.puts(:stderr, output)
        System.halt(1)
    end
end
