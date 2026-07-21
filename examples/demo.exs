# Hw Examples - Run with: mix run examples/demo.exs
#
# Demonstrates:
# 1. Basic DSL usage
# 2. Instance composition (flattening)
# 3. Interface traits
# 4. Multiply, Memory, Tristate, Blackbox

IO.puts("=" |> String.duplicate(60))
IO.puts("Hw Examples")
IO.puts("=" |> String.duplicate(60))

# =============================================================================
# Example 1: Basic Counter
# =============================================================================

defmodule Examples.Counter do
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

IO.puts("\n## Example 1: Basic Counter\n")
IO.puts(Hw.compile!(Examples.Counter))

# =============================================================================
# Example 2: Combinational Adder
# =============================================================================

defmodule Examples.Adder do
  use Hw.Component

  input :a, 8
  input :b, 8
  output :sum, 8

  comb do
    sum <= a + b
  end
end

IO.puts("\n## Example 2: Combinational Adder\n")
IO.puts(Hw.compile!(Examples.Adder))

# =============================================================================
# Example 3: Signed Arithmetic
# =============================================================================

defmodule Examples.SignedMul do
  use Hw.Component

  clock :clk
  input :a, 16, signed: true
  input :b, 16, signed: true
  output :product, 16, signed: true

  on :clk do
    product <= a + b  # Just demo signed signals
  end
end

IO.puts("\n## Example 3: Signed Signals\n")
IO.puts(Hw.compile!(Examples.SignedMul))

# =============================================================================
# Example 4: Instance Composition
# =============================================================================

# Child: A simple counter (reusing from above)
defmodule Examples.Child.Counter do
  use Hw.Component

  clock :clk
  input :rst, 1
  input :en, 1
  output :count, 4

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

# Parent: Instantiates two counters
defmodule Examples.DualCounter do
  use Hw.Component

  clock :clk
  input :rst, 1
  input :en_a, 1
  input :en_b, 1
  output :count_a, 4
  output :count_b, 4

  # Two instances of the same counter
  instance :cnt_a, Examples.Child.Counter,
    clk: :clk,
    rst: :rst,
    en: :en_a

  instance :cnt_b, Examples.Child.Counter,
    clk: :clk,
    rst: :rst,
    en: :en_b

  # Wire child outputs to parent outputs
  comb do
    count_a <= cnt_a.count
    count_b <= cnt_b.count
  end
end

IO.puts("\n## Example 4: Instance Composition (Two Counters)\n")
IO.puts(Hw.compile!(Examples.DualCounter))

# =============================================================================
# Example 5: Interface Traits
# =============================================================================

# Define a simple valid/ready streaming interface
defmodule Examples.Interface.Stream do
  use Hw.Interface

  param :width, default: 8

  signal :data, :width
  signal :valid, 1
  signal :ready, 1, flip: true  # Flips direction for sink
end

# Source: produces data
defmodule Examples.StreamSource do
  use Hw.Component

  clock :clk
  input :rst, 1
  input :trigger, 1

  # Interface expands to: out_data, out_valid, out_ready
  interface :out, Examples.Interface.Stream, width: 8, role: :source

  on :clk do
    if rst do
      out_data <= 0
      out_valid <= 0
    else
      if trigger do
        out_data <= 42
        out_valid <= 1
      else
        out_valid <= 0
      end
    end
  end
end

IO.puts("\n## Example 5: Interface Trait (Stream Source)\n")
IO.puts(Hw.compile!(Examples.StreamSource))

# Sink: consumes data
defmodule Examples.StreamSink do
  use Hw.Component

  clock :clk
  input :rst, 1
  output :received, 8

  # Interface with role: :sink flips ready direction
  interface :in, Examples.Interface.Stream, width: 8, role: :sink

  on :clk do
    if rst do
      received <= 0
    else
      if in_valid do
        received <= in_data
      end
    end
  end

  # Always ready
  comb do
    in_ready <= 1
  end
end

IO.puts("\n## Example 6: Interface Trait (Stream Sink)\n")
IO.puts(Hw.compile!(Examples.StreamSink))

# =============================================================================
# Example 7: Multiple Interfaces
# =============================================================================

defmodule Examples.DataProcessor do
  use Hw.Component

  clock :clk
  input :rst, 1

  interface :din, Examples.Interface.Stream, width: 8, role: :sink
  interface :dout, Examples.Interface.Stream, width: 8, role: :source

  on :clk do
    if rst do
      dout_data <= 0
      dout_valid <= 0
    else
      if din_valid do
        dout_data <= din_data + 1  # Increment data
        dout_valid <= 1
      else
        dout_valid <= 0
      end
    end
  end

  comb do
    din_ready <= 1  # Always ready
  end
end

IO.puts("\n## Example 7: Multiple Interfaces (Processor)\n")
IO.puts(Hw.compile!(Examples.DataProcessor))

# =============================================================================
# Example 8: Constant Port Connections
# =============================================================================

defmodule Examples.WithConstant do
  use Hw.Component

  clock :clk
  input :rst, 1
  output :out, 4

  # Connect 'en' port to constant 1 (always enabled)
  instance :cnt, Examples.Child.Counter,
    clk: :clk,
    rst: :rst,
    en: 1

  comb do
    out <= cnt.count
  end
end

IO.puts("\n## Example 8: Constant Port Connection\n")
IO.puts(Hw.compile!(Examples.WithConstant))

# =============================================================================
# Example 9: Multiply
# =============================================================================

defmodule Examples.Multiplier do
  use Hw.Component

  clock :clk
  input :a, 8
  input :b, 8
  output :product, 8

  # Combinational multiply
  comb do
    product <= a * b
  end
end

IO.puts("\n## Example 9: Multiply\n")
IO.puts(Hw.compile!(Examples.Multiplier))

# =============================================================================
# Example 10: Memory (Block RAM)
# =============================================================================

defmodule Examples.SimpleRAM do
  use Hw.Component

  clock :clk
  input :addr, 4        # 4-bit address = 16 locations
  output :data_out, 8

  # Declare a 16x8 memory
  memory :ram, width: 8, depth: 16

  # Async read (combinational)
  comb do
    data_out <= ram[addr]
  end
end

IO.puts("\n## Example 10: Memory (Async Read)\n")
IO.puts(Hw.compile!(Examples.SimpleRAM))

# =============================================================================
# Example 11: Tristate / Bidirectional IO
# =============================================================================

defmodule Examples.BidirectionalBus do
  use Hw.Component

  clock :clk
  input :drive_en, 1       # 1 = drive bus, 0 = read bus
  input :data_to_bus, 8    # Data to write to bus
  output :data_from_bus, 8 # Data read from bus
  inout :bus, 8            # The bidirectional bus

  # Tristate buffer: drives bus when enabled, reads when not
  tristate :bus_driver,
    io: :bus,
    output: :data_to_bus,
    enable: :drive_en,
    input: :data_from_bus
end

IO.puts("\n## Example 11: Tristate / Bidirectional IO\n")
IO.puts(Hw.compile!(Examples.BidirectionalBus))

# =============================================================================
# Example 12: Blackbox (Vendor Primitive)
# =============================================================================

defmodule Examples.WithPLL do
  use Hw.Component

  clock :clk_12mhz
  output :clk_48mhz, 1
  output :locked, 1

  # Instantiate iCE40 PLL primitive (not elaborated, passed through)
  blackbox :pll, "SB_PLL40_CORE",
    params: [
      FEEDBACK_PATH: "SIMPLE",
      DIVR: 0,
      DIVF: 63,
      DIVQ: 4,
      FILTER_RANGE: 1
    ],
    ports: [
      REFERENCECLK: :clk_12mhz,
      PLLOUTCORE: :clk_48mhz,
      LOCK: :locked,
      RESETB: 1,
      BYPASS: 0
    ]
end

IO.puts("\n## Example 12: Blackbox (iCE40 PLL)\n")
IO.puts(Hw.compile!(Examples.WithPLL))

# =============================================================================
# Example 13: Memory with Sync Write
# =============================================================================

defmodule Examples.RAMWithWrite do
  use Hw.Component

  clock :clk
  input :addr, 4
  input :data_in, 8
  input :write_en, 1
  output :data_out, 8

  memory :ram, width: 8, depth: 16

  # Async read
  comb do
    data_out <= ram[addr]
  end

  # Sync write
  on :clk do
    if write_en do
      ram[addr] <= data_in
    end
  end
end

IO.puts("\n## Example 13: Memory with Sync Write\n")
IO.puts(Hw.compile!(Examples.RAMWithWrite))

# =============================================================================
# Example 14: Comparisons
# =============================================================================

defmodule Examples.Comparator do
  use Hw.Component

  input :a, 8
  input :b, 8
  output :is_less, 1
  output :is_greater, 1
  output :is_equal, 1
  output :is_not_equal, 1

  comb do
    is_less <= (a < b)
    is_greater <= (a > b)
    is_equal <= (a == b)
    is_not_equal <= (a != b)
  end
end

IO.puts("\n## Example 14: Comparisons\n")
IO.puts(Hw.compile!(Examples.Comparator))

# =============================================================================
# Example 15: Shifts
# =============================================================================

defmodule Examples.Shifter do
  use Hw.Component

  input :data, 8
  input :amount, 3
  output :shift_left, 8
  output :shift_right, 8

  comb do
    shift_left <= (data <<< amount)
    shift_right <= (data >>> amount)
  end
end

IO.puts("\n## Example 15: Shifts\n")
IO.puts(Hw.compile!(Examples.Shifter))

# =============================================================================
# Example 16: Bit Slices and Concat
# =============================================================================

defmodule Examples.BitManip do
  use Hw.Component

  input :word, 16
  output :high_byte, 8
  output :low_byte, 8
  output :swapped, 16

  comb do
    high_byte <= word[15..8]
    low_byte <= word[7..0]
    swapped <= {word[7..0], word[15..8]}
  end
end

IO.puts("\n## Example 16: Bit Slices and Concat\n")
IO.puts(Hw.compile!(Examples.BitManip))

# =============================================================================
# Summary
# =============================================================================

IO.puts("\n" <> String.duplicate("=", 60))
IO.puts("All examples compiled successfully!")
IO.puts(String.duplicate("=", 60))

IO.puts("""

Features demonstrated:
  1. Basic DSL (clock, input, output, on, comb)
  2. Signed arithmetic
  3. Instance composition with flattening
  4. Interface traits with role-based direction
  5. Constant port connections
  6. Multiply operator
  7. Memory (block RAM with async read)
  8. Tristate / bidirectional IO (inout)
  9. Blackbox vendor primitives (PLL example)
  10. Memory with sync write
  11. Comparisons (<, >, ==, !=, <=, >=)
  12. Shifts (<<<, >>>)
  13. Bit slices (sig[15..8])
  14. Concatenation ({a, b})

Current limitations:
  - Nested instances (instance inside instance) not yet supported
  - connect macro for instance-to-instance wiring not yet implemented
  - No parameterized modules yet
""")
