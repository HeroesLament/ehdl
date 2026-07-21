defmodule Hw.AXI4Master do
  @moduledoc """
  AXI4 Write-only DMA master for Zynq HP ports.

  Streams data from an input interface into DDR via burst writes.
  Implements a ring buffer with configurable base address and size.

  ## Parameters

  - `DATA_WIDTH` - AXI data width, typically 64 for HP ports (default: 64)
  - `ADDR_WIDTH` - Address width (default: 32)
  - `BURST_LEN` - Beats per burst, 1-256 (default: 16)
  - `FIFO_DEPTH` - Internal buffer depth (default: 256)

  ## Ports

  ### Stream Input
  - `s_data` - Input data
  - `s_valid` - Data valid
  - `s_ready` - Backpressure (output)

  ### Configuration (directly mapped registers from ARM)
  - `base_addr` - Ring buffer base address in DDR
  - `ring_size` - Ring buffer size (must be power of 2)
  - `enable` - Enable DMA transfers
  - `write_ptr` - Current write position (output, ARM polls this)

  ### AXI4 Master Interface
  - `m_axi_*` - Standard AXI4 write channels (AW, W, B)

  ## Usage

      instance :dma, Hw.AXI4Master, DATA_WIDTH: 64, BURST_LEN: 16

      # Connect stream input
      dma.s_data = my_data
      dma.s_valid = my_valid
      my_ready = dma.s_ready

      # Connect to HP port (directly or via interconnect)
      # ... AXI signal connections ...

  ## Ring Buffer Operation

  The DMA writes sequentially from `base_addr`, wrapping at `base_addr + ring_size`.
  ARM reads `write_ptr` to know how much data is available, then reads directly
  from the mmap'd DDR region. ARM maintains its own read pointer.

  ## Implementation Notes

  - Bursts are aligned to burst boundaries
  - Uses INCR burst type
  - All byte strobes enabled (no partial writes)
  - Write responses are accepted but errors not yet handled
  """

  use Hw.Component

  param :DATA_WIDTH, default: 64
  param :ADDR_WIDTH, default: 32
  param :BURST_LEN, default: 16
  param :FIFO_DEPTH, default: 256

  clock :aclk
  input :aresetn, 1  # Active-low reset (AXI convention)

  # Stream input
  input :s_data, DATA_WIDTH
  input :s_valid, 1
  output :s_ready, 1

  # Ring buffer configuration
  input :base_addr, ADDR_WIDTH
  input :ring_size, ADDR_WIDTH
  input :enable, 1
  output :write_ptr, ADDR_WIDTH

  # AXI4 Write Address Channel
  output :m_axi_awaddr, ADDR_WIDTH
  output :m_axi_awlen, 8
  output :m_axi_awsize, 3
  output :m_axi_awburst, 2
  output :m_axi_awvalid, 1
  input :m_axi_awready, 1

  # AXI4 Write Data Channel
  output :m_axi_wdata, DATA_WIDTH
  output :m_axi_wstrb, DATA_WIDTH / 8
  output :m_axi_wlast, 1
  output :m_axi_wvalid, 1
  input :m_axi_wready, 1

  # AXI4 Write Response Channel
  input :m_axi_bresp, 2
  input :m_axi_bvalid, 1
  output :m_axi_bready, 1

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
  wire :fifo_has_burst, 1
  wire :addr_accepted, 1
  wire :data_accepted, 1
  wire :burst_complete, 1
  wire :is_last_beat, 1

  # State indicators (set by FSM, read by on blocks)
  wire :in_send_data, 1
  wire :in_wait_resp, 1

  # Combinational logic
  comb do
    # Active-low to active-high reset conversion
    rst = bnot(aresetn)

    # FIFO status
    fifo_count = fifo_wr_ptr - fifo_rd_ptr
    fifo_not_full = (fifo_count < FIFO_DEPTH - 1)
    fifo_has_burst = (fifo_count >= BURST_LEN)

    # Handshake helpers
    addr_accepted = band(m_axi_awvalid, m_axi_awready)
    data_accepted = band(m_axi_wvalid, m_axi_wready)
    is_last_beat = (beat_count == BURST_LEN - 1)
    burst_complete = band(m_axi_bvalid, m_axi_bready)

    # Bytes per burst for address increment
    burst_bytes = BURST_LEN * (DATA_WIDTH / 8)

    # Stream ready when FIFO not full
    s_ready = band(fifo_not_full, enable)

    # Expose current address as write pointer
    write_ptr = current_addr

    # Always ready to accept write responses
    m_axi_bready = 1

    # Fixed AXI parameters
    # awsize = log2(bytes_per_beat) = log2(DATA_WIDTH/8)
    # For 64-bit: log2(8) = 3
    # For 32-bit: log2(4) = 2
    m_axi_awsize = 3  # Hardcoded for 64-bit, TODO: derive from DATA_WIDTH
    m_axi_awburst = 1  # INCR
    m_axi_awlen = BURST_LEN - 1

    # All byte strobes valid (0xFF for 64-bit)
    m_axi_wstrb = 0xFF  # Hardcoded for 64-bit

    # FIFO read data to AXI
    m_axi_wdata = fifo_mem[fifo_rd_ptr]

    # Last beat indicator
    m_axi_wlast = is_last_beat
  end

  # FSM for burst control
  fsm :state, clock: :aclk, init: :idle do
    defaults do
      m_axi_awvalid = 0
      m_axi_wvalid = 0
      in_send_data = 0
      in_wait_resp = 0
    end

    case state do
      :idle ->
        # Wait for enough data and enabled
        on enable == 1 and fifo_has_burst == 1, next: :send_addr

      :send_addr ->
        # Present address, wait for ready
        m_axi_awaddr = current_addr
        m_axi_awvalid = 1
        on m_axi_awready == 1, next: :send_data

      :send_data ->
        # Stream data beats
        m_axi_wvalid = 1
        in_send_data = 1
        on m_axi_wready == 1 and is_last_beat == 1, next: :wait_resp

      :wait_resp ->
        # Wait for write response
        in_wait_resp = 1
        on m_axi_bvalid == 1, next: :idle
    end
  end

  # FIFO write logic
  on :aclk do
    if rst == 1 do
      fifo_wr_ptr = 0
    else
      if s_valid == 1 and fifo_not_full == 1 and enable == 1 do
        fifo_mem[fifo_wr_ptr] = s_data
        fifo_wr_ptr = fifo_wr_ptr + 1
      end
    end
  end

  # FIFO read and beat counter logic
  on :aclk do
    if rst == 1 do
      fifo_rd_ptr = 0
      beat_count = 0
    else
      if in_send_data == 1 and m_axi_wready == 1 do
        fifo_rd_ptr = fifo_rd_ptr + 1
        if is_last_beat == 1 do
          beat_count = 0
        else
          beat_count = beat_count + 1
        end
      end
    end
  end

  # Address management
  on :aclk do
    if rst == 1 do
      current_addr = base_addr
    else
      # Update address after burst response received
      if in_wait_resp == 1 and m_axi_bvalid == 1 do
        # Wrap within ring buffer
        # new_addr = base + ((current - base + burst_bytes) & (ring_size - 1))
        current_addr = base_addr + band(current_addr - base_addr + burst_bytes, ring_size - 1)
      end
    end
  end
end
