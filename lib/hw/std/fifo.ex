defmodule Hw.FIFO do
  @moduledoc """
  Synchronous FIFO (First-In-First-Out) buffer.

  Single clock domain FIFO with parameterizable width and depth.
  Uses a circular buffer with read/write pointers.

  ## Parameters

  - `WIDTH` - Data width in bits (default: 8)
  - `DEPTH` - Number of entries, must be power of 2 (default: 16)

  ## Ports

  - `clk` - Clock
  - `rst` - Synchronous reset (active high)
  - `wr_en` - Write enable
  - `wr_data` - Data to write
  - `rd_en` - Read enable
  - `rd_data` - Data read out
  - `empty` - High when FIFO is empty
  - `full` - High when FIFO is full
  - `count` - Number of entries currently in FIFO

  ## Usage

      instance :rx_fifo, Hw.FIFO, WIDTH: 8, DEPTH: 64

      # Write
      rx_fifo.wr_en = data_valid
      rx_fifo.wr_data = incoming_byte

      # Read
      rx_fifo.rd_en = consumer_ready and bnot(rx_fifo.empty)
      outgoing_byte = rx_fifo.rd_data

  ## Implementation Notes

  - Read data is available on the cycle AFTER rd_en is asserted
  - Writing to a full FIFO or reading from empty FIFO is ignored
  - Simultaneous read/write is supported
  - DEPTH must be a power of 2 for efficient pointer arithmetic
  """

  use Hw.Component

  param :WIDTH, default: 8
  param :DEPTH, default: 16

  clock :clk
  input :rst, 1
  input :wr_en, 1
  input :wr_data, WIDTH
  input :rd_en, 1
  output :rd_data, WIDTH
  output :empty, 1
  output :full, 1
  output :count, clog2(DEPTH) + 1

  # Internal storage
  memory :mem, width: WIDTH, depth: DEPTH

  # Pointers (extra bit for full/empty detection)
  # For DEPTH=16: ptr is 5 bits, addr is 4 bits
  wire :wr_ptr, clog2(DEPTH) + 1
  wire :rd_ptr, clog2(DEPTH) + 1

  # Status signals
  wire :ptr_match, 1
  wire :msb_diff, 1

  # Internal: wrap mask for address extraction
  # For DEPTH=16: mask = 0xF (4 bits), msb_pos = 4
  wire :wr_addr, clog2(DEPTH)
  wire :rd_addr, clog2(DEPTH)
  wire :wr_msb, 1
  wire :rd_msb, 1

  comb do
    # Extract address portions using mask (DEPTH - 1)
    # This works because DEPTH must be power of 2
    wr_addr = wr_ptr &&& (DEPTH - 1)
    rd_addr = rd_ptr &&& (DEPTH - 1)

    # Extract MSB using shift
    wr_msb = wr_ptr >>> clog2(DEPTH)
    rd_msb = rd_ptr >>> clog2(DEPTH)

    # Pointers match when addresses are equal
    ptr_match = (wr_addr == rd_addr)

    # MSB differs when pointers have wrapped differently
    msb_diff = (wr_msb != rd_msb)

    # Empty when pointers are exactly equal
    empty = ptr_match and bnot(msb_diff)

    # Full when addresses match but MSBs differ (one full wrap ahead)
    full = ptr_match and msb_diff

    # Count = difference between pointers
    count = wr_ptr - rd_ptr

    # Read data from memory at read address
    rd_data = mem[rd_addr]
  end

  on :clk do
    if rst == 1 do
      wr_ptr = 0
      rd_ptr = 0
    else
      # Write logic
      if wr_en == 1 and full == 0 do
        mem[wr_addr] = wr_data
        wr_ptr = wr_ptr + 1
      end

      # Read logic
      if rd_en == 1 and empty == 0 do
        rd_ptr = rd_ptr + 1
      end
    end
  end
end
