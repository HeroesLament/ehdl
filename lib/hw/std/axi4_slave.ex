defmodule Hw.AXI4Slave do
  @moduledoc """
  AXI4 Read-only DMA master for Zynq HP ports (TX path).

  Reads data from DDR ring buffer and streams to FPGA logic.
  Despite the name "Slave" (from the data flow perspective), this is
  still an AXI master that initiates read transactions.

  ## Parameters

  - `DATA_WIDTH` - AXI data width, typically 64 for HP ports (default: 64)
  - `ADDR_WIDTH` - Address width (default: 32)
  - `BURST_LEN` - Beats per burst, 1-256 (default: 16)
  - `FIFO_DEPTH` - Internal buffer depth (default: 256)

  ## Ports

  ### Stream Output
  - `m_data` - Output data to FPGA logic
  - `m_valid` - Data valid
  - `m_ready` - Backpressure from downstream (input)

  ### Configuration (directly mapped registers from ARM)
  - `base_addr` - Ring buffer base address in DDR
  - `ring_size` - Ring buffer size (must be power of 2)
  - `enable` - Enable DMA transfers
  - `read_ptr` - Current read position (output, ARM polls this)
  - `write_ptr` - ARM's write position (input, ARM updates this)

  ### AXI4 Master Interface (Read Channels)
  - `m_axi_ar*` - Read address channel
  - `m_axi_r*` - Read data channel

  ## Usage

      instance :tx_dma, Hw.AXI4Slave, DATA_WIDTH: 64, BURST_LEN: 16

      # Connect stream output
      my_data = tx_dma.m_data
      my_valid = tx_dma.m_valid
      tx_dma.m_ready = my_ready

      # ARM writes samples to DDR, updates write_ptr
      # FPGA reads and streams out

  ## Ring Buffer Operation

  ARM writes samples to DDR and updates `write_ptr`.
  FPGA reads from `read_ptr` up to `write_ptr`, wrapping at ring boundary.
  FPGA exposes `read_ptr` so ARM knows what's been consumed.
  """

  use Hw.Component

  param :DATA_WIDTH, default: 64
  param :ADDR_WIDTH, default: 32
  param :BURST_LEN, default: 16
  param :FIFO_DEPTH, default: 256

  clock :aclk
  input :aresetn, 1  # Active-low reset (AXI convention)

  # Stream output
  output :m_data, DATA_WIDTH
  output :m_valid, 1
  input :m_ready, 1

  # Ring buffer configuration
  input :base_addr, ADDR_WIDTH
  input :ring_size, ADDR_WIDTH
  input :enable, 1
  input :write_ptr, ADDR_WIDTH   # ARM updates this
  output :read_ptr, ADDR_WIDTH   # FPGA exposes this

  # AXI4 Read Address Channel
  output :m_axi_araddr, ADDR_WIDTH
  output :m_axi_arlen, 8
  output :m_axi_arsize, 3
  output :m_axi_arburst, 2
  output :m_axi_arvalid, 1
  input :m_axi_arready, 1

  # AXI4 Read Data Channel
  input :m_axi_rdata, DATA_WIDTH
  input :m_axi_rresp, 2
  input :m_axi_rlast, 1
  input :m_axi_rvalid, 1
  output :m_axi_rready, 1

  # Internal FIFO
  memory :fifo_mem, width: DATA_WIDTH, depth: FIFO_DEPTH
  wire :fifo_wr_ptr, clog2(FIFO_DEPTH)
  wire :fifo_rd_ptr, clog2(FIFO_DEPTH)
  wire :fifo_count, clog2(FIFO_DEPTH) + 1

  # Burst state
  wire :beat_count, 8
  wire :current_addr, ADDR_WIDTH
  wire :burst_bytes, ADDR_WIDTH

  # Internal signals
  wire :rst, 1
  wire :fifo_not_full, 1
  wire :fifo_not_empty, 1
  wire :fifo_has_space, 1
  wire :data_available, 1
  wire :available_bytes, ADDR_WIDTH
  wire :can_burst, 1
  wire :is_last_beat, 1

  # State indicators (set by FSM, read by on blocks)
  wire :in_recv_data, 1

  # Combinational logic
  comb do
    # Active-low to active-high reset conversion
    rst = bnot(aresetn)

    # FIFO status
    fifo_count = fifo_wr_ptr - fifo_rd_ptr
    fifo_not_full = (fifo_count < FIFO_DEPTH - 1)
    fifo_not_empty = (fifo_count > 0)
    fifo_has_space = (fifo_count <= FIFO_DEPTH - BURST_LEN)

    # How much data is available in DDR ring buffer?
    # available = (write_ptr - current_addr) wrapped
    available_bytes = band(write_ptr - current_addr, ring_size - 1)

    # Can we do a full burst?
    data_available = (available_bytes >= BURST_LEN * (DATA_WIDTH / 8))
    can_burst = band(band(fifo_has_space, data_available), enable)

    # Bytes per burst for address increment
    burst_bytes = BURST_LEN * (DATA_WIDTH / 8)

    # Stream output from FIFO
    m_data = fifo_mem[fifo_rd_ptr]
    m_valid = fifo_not_empty

    # Expose current address as read pointer
    read_ptr = current_addr

    # Fixed AXI parameters
    m_axi_arsize = 3  # 8 bytes (64-bit)
    m_axi_arburst = 1  # INCR
    m_axi_arlen = BURST_LEN - 1

    # Last beat tracking
    is_last_beat = (beat_count == BURST_LEN - 1)
  end

  # FSM for burst control
  fsm :state, clock: :aclk, init: :idle do
    defaults do
      m_axi_arvalid = 0
      m_axi_rready = 0
      in_recv_data = 0
    end

    case state do
      :idle ->
        # Wait for space in FIFO and data available in DDR
        on can_burst == 1, next: :send_addr

      :send_addr ->
        # Present read address, wait for ready
        m_axi_araddr = current_addr
        m_axi_arvalid = 1
        on m_axi_arready == 1, next: :recv_data

      :recv_data ->
        # Receive data beats
        m_axi_rready = 1
        in_recv_data = 1
        on m_axi_rvalid == 1 and m_axi_rlast == 1, next: :idle
    end
  end

  # FIFO write from AXI read data
  on :aclk do
    if rst == 1 do
      fifo_wr_ptr = 0
      beat_count = 0
    else
      if in_recv_data == 1 and m_axi_rvalid == 1 do
        fifo_mem[fifo_wr_ptr] = m_axi_rdata
        fifo_wr_ptr = fifo_wr_ptr + 1
        if is_last_beat == 1 do
          beat_count = 0
        else
          beat_count = beat_count + 1
        end
      end
    end
  end

  # FIFO read to stream output
  on :aclk do
    if rst == 1 do
      fifo_rd_ptr = 0
    else
      if fifo_not_empty == 1 and m_ready == 1 do
        fifo_rd_ptr = fifo_rd_ptr + 1
      end
    end
  end

  # Address management
  on :aclk do
    if rst == 1 do
      current_addr = base_addr
    else
      # Update address after burst complete (rlast received)
      if in_recv_data == 1 and m_axi_rvalid == 1 and m_axi_rlast == 1 do
        # Wrap within ring buffer
        current_addr = base_addr + band(current_addr - base_addr + burst_bytes, ring_size - 1)
      end
    end
  end
end
