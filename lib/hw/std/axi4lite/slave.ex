defmodule Hw.AXI4Lite.Slave do
  @moduledoc """
  AXI4-Lite slave register file — the PS↔PL control plane.

  This is the component the ARM pokes to talk to the fabric. It is deliberately
  the *smallest* thing that proves a Zynq PL design is alive and addressable:
  a magic constant to confirm the AXI link, a scratch register to confirm
  writes land, and a control/status pair to confirm data crosses in both
  directions.

  ## Register map (byte offsets from the AXI base address)

  | Offset | Name     | Access | Meaning                                     |
  |--------|----------|--------|---------------------------------------------|
  | 0x00   | MAGIC    | RO     | `MAGIC` param. Reads back "EHD1" by default |
  | 0x04   | VERSION  | RO     | `VERSION` param                             |
  | 0x08   | SCRATCH  | RW     | Free register. Write/readback proof         |
  | 0x0C   | CTRL0    | RW     | Drives `ctrl0` into the fabric              |
  | 0x10   | CTRL1    | RW     | Drives `ctrl1` into the fabric              |
  | 0x14   | CTRL2    | RW     | Drives `ctrl2` into the fabric              |
  | 0x18   | CTRL3    | RW     | Drives `ctrl3` into the fabric              |
  | 0x1C   | STATUS0  | RO     | Samples `status0` from the fabric           |
  | 0x20   | STATUS1  | RO     | Samples `status1` from the fabric           |
  | 0x24   | STATUS2  | RO     | Samples `status2` from the fabric           |
  | 0x28   | STATUS3  | RO     | Samples `status3` from the fabric           |

  Four of each rather than one. A single 32-bit control word runs out the
  moment a design carries anything real: an SPI byte, a chip-select hold bit, a
  go strobe and a handful of radio pin controls do not share 32 bits with any
  comfort, and packing them tighter makes the Elixir side a bitfield puzzle for
  no gain. Unused registers cost four flops each and are optimised away when
  the fabric leaves the port unconnected.

  Reads outside the map return 0 with an OKAY response — see "Error handling".

  ## Bring-up sequence this is designed for

      # from IEx, after loading the bitstream via fpga_manager
      0x45484431 = read32(base + 0x00)   # link works at all
      write32(base + 0x08, 0xDEADBEEF)
      0xDEADBEEF = read32(base + 0x08)   # writes land and persist
      write32(base + 0x0C, 1)            # PS -> PL
      read32(base + 0x1C)                # PL -> PS

  ## IMPORTANT: FSM outputs are registered

  EHDL registers signals driven from an `fsm` block. Two consequences, both of
  which silently produce protocol-violating AXI if you forget them:

  1. **A value set in a state body persists into the next state.** Setting
     `s_axi_arready = 1` in `:idle` leaves ARREADY high for the first cycle of
     `:resp`, where a back-to-back master gets a second AR accepted that is
     never answered — one RVALID for two ARs, and the master hangs. Every
     ready/valid is therefore explicitly deasserted *inside* the `on` block
     that performs the transition.

  2. **A ready/valid is low on the first cycle of the state that asserts it.**
     So a transition must never test only the far side of the handshake. If
     `:idle` transitioned on `s_axi_arvalid` alone, a master asserting ARVALID
     early would be latched and answered without ever having seen ARREADY.
     Every transition below tests *both* halves, which is what the AXI spec
     means by a handshake.

  Cost of doing this correctly is a one-cycle bubble between transactions.
  Irrelevant for control registers; do not copy this structure into a
  data-path component without revisiting it.

  ## Why DATA_WIDTH is fixed at 32

  AXI4-Lite on the Zynq-7000 M_AXI_GP ports is 32-bit, and honouring byte
  strobes requires a byte-lane mux sized to the data width. Rather than take a
  `DATA_WIDTH` parameter and then hardcode `wstrb = 0xFF` for 64-bit — which is
  what `Hw.AXI4Master` does today, silently corrupting any other width — this
  component does not pretend to be generic. Widening it means generating the
  lane mux, not editing a constant.

  ## Error handling

  Unmapped reads return zero with `RRESP = OKAY`, and unmapped writes are
  accepted and discarded with `BRESP = OKAY`. Returning DECERR would be more
  correct AXI, but on Zynq an error response propagates to the CPU as a bus
  abort — a stray `/dev/mem` read of the wrong offset would oops the kernel.
  During bring-up a quiet zero is far more debuggable than a dead board.

  ## Ports

  - `aclk`    — AXI clock. On Zynq this is `FCLK_CLK0` via a `BUFG`
  - `aresetn` — active-low reset, AXI convention
  - `s_axi_*` — AXI4-Lite slave interface
  - `ctrl0..3`   — CTRL registers, driven into the fabric
  - `status0..3` — sampled into the STATUS registers
  """

  use Hw.Component

  param :MAGIC,   default: 0x45484431
  param :VERSION, default: 0x00010000

  clock :aclk
  input :aresetn, 1

  # Write address channel
  input  :s_axi_awaddr,  17
  input  :s_axi_awvalid, 1
  output :s_axi_awready, 1

  # Write data channel
  input  :s_axi_wdata,  32
  input  :s_axi_wstrb,  4
  input  :s_axi_wvalid, 1
  output :s_axi_wready, 1

  # Write response channel
  output :s_axi_bresp,  2
  output :s_axi_bvalid, 1
  input  :s_axi_bready, 1

  # Read address channel
  input  :s_axi_araddr,  17
  input  :s_axi_arvalid, 1
  output :s_axi_arready, 1

  # Read data channel
  output :s_axi_rdata,  32
  output :s_axi_rresp,  2
  output :s_axi_rvalid, 1
  input  :s_axi_rready, 1

  # Fabric-facing
  output :ctrl0, 32
  output :ctrl1, 32
  output :ctrl2, 32
  output :ctrl3, 32

  # Pulses for one `aclk` cycle when a read of STATUS3 completes. A capture
  # buffer behind STATUS3 uses it to auto-advance its read pointer, which turns
  # readout from three bus transactions per word into one.
  #
  # That matters more than it looks. A single AXI-Lite read through the Zynq GP
  # port costs ~1.06 us of bus time but ~215 us when it is its own userspace
  # round trip -- measured. Auto-advance is what lets N words come back in ONE
  # round trip instead of N.
  output :status3_rd, 1

  # Pulses for one `aclk` cycle when a write to CTRL2 commits. Paired with
  # `status3_rd`: one loads a pointer, the other advances it, and a consumer
  # needs both or it cannot distinguish "seek here" from "seek here again after
  # reading N words". Comparing CTRL2 against the pointer instead does NOT
  # work -- they differ on every cycle after the first auto-advance, so the
  # pointer would be dragged back continuously.
  output :ctrl2_wr, 1

  # Memory window. Address bit 16 selects it: offsets below 0x10000 are the
  # register file, at or above it are `mem_rdata`.
  #
  # `mem_raddr` is driven COMBINATIONALLY from the incoming address, one cycle
  # before `araddr_q` latches it. That is deliberate and it is what makes a
  # synchronous-read BRAM work here with no extra wait state: the memory sees
  # the address in `:idle`, its data is valid in `:resp`, which is exactly when
  # RVALID is asserted.
  #
  # Why bother, when an auto-advancing register already reads the buffer: a
  # repeated read of ONE address measures ~25 us per word, while consecutive
  # reads of DIFFERENT addresses measure ~1.06 us. Mapping the buffer is worth
  # ~23x on readout, which is larger than the 30.9x the auto-advance itself
  # bought.
  output :mem_raddr, 15
  input  :mem_rdata, 32

  input  :status0, 32
  input  :status1, 32
  input  :status2, 32
  input  :status3, 32

  wire :rst, 1

  wire :ctrl0_reg, 32, init: 0
  wire :ctrl1_reg, 32, init: 0
  wire :ctrl2_reg, 32, init: 0
  wire :ctrl3_reg, 32, init: 0
  wire :scratch_reg, 32, init: 0
  wire :awaddr_q,    17, init: 0
  wire :araddr_q,    17, init: 0
  wire :reg_rdata,   32

  wire :rd_index, 4
  wire :wr_index, 4

  # Byte-lane write mask, expanded from WSTRB.
  wire :m0, 8
  wire :m1, 8
  wire :m2, 8
  wire :m3, 8
  wire :wmask, 32

  comb do
    rst = not aresetn
    ctrl0 = ctrl0_reg
    ctrl1 = ctrl1_reg
    ctrl2 = ctrl2_reg
    ctrl3 = ctrl3_reg

    # Word index: drop the 2 byte-address bits, keep 4 bits of register select.
    rd_index = araddr_q >>> 2
    wr_index = awaddr_q >>> 2

    # Expand each strobe bit to a byte of mask, so a partial write leaves the
    # untouched lanes alone instead of clobbering the whole word.
    m0 = if s_axi_wstrb[0..0] == 1, do: 0xFF, else: 0x00
    m1 = if s_axi_wstrb[1..1] == 1, do: 0xFF, else: 0x00
    m2 = if s_axi_wstrb[2..2] == 1, do: 0xFF, else: 0x00
    m3 = if s_axi_wstrb[3..3] == 1, do: 0xFF, else: 0x00
    wmask = {m3, m2, m1, m0}

    # Word address into the memory window, taken from the LIVE address so the
    # BRAM has a cycle to respond.
    mem_raddr = s_axi_araddr[16..2]

    # Read mux. Registered address in, so there is no combinational path from
    # ARVALID to RDATA. Default first: unmapped offsets read as zero.
    reg_rdata = 0
    hdl_case <<rd_index::4>> do
      <<0::4>> -> reg_rdata = MAGIC
      <<1::4>> -> reg_rdata = VERSION
      <<2::4>> -> reg_rdata = scratch_reg
      <<3::4>> -> reg_rdata = ctrl0_reg
      <<4::4>> -> reg_rdata = ctrl1_reg
      <<5::4>> -> reg_rdata = ctrl2_reg
      <<6::4>> -> reg_rdata = ctrl3_reg
      <<7::4>> -> reg_rdata = status0
      <<8::4>> -> reg_rdata = status1
      <<9::4>> -> reg_rdata = status2
      <<10::4>> -> reg_rdata = status3
    end

    s_axi_rdata = if araddr_q[16..16] == 1, do: mem_rdata, else: reg_rdata
  end

  # Merge a strobed write into a register: keep the masked-out lanes, take the
  # rest.
  defhw merge_scratch() do
    scratch_reg = bor(band(scratch_reg, bnot(wmask)), band(s_axi_wdata, wmask))
  end

  defhw merge_ctrl0() do
    ctrl0_reg = bor(band(ctrl0_reg, bnot(wmask)), band(s_axi_wdata, wmask))
  end

  defhw merge_ctrl1() do
    ctrl1_reg = bor(band(ctrl1_reg, bnot(wmask)), band(s_axi_wdata, wmask))
  end

  defhw merge_ctrl2() do
    ctrl2_reg = bor(band(ctrl2_reg, bnot(wmask)), band(s_axi_wdata, wmask))
  end

  defhw merge_ctrl3() do
    ctrl3_reg = bor(band(ctrl3_reg, bnot(wmask)), band(s_axi_wdata, wmask))
  end

  # Dispatch a write to whichever register the latched address selects.
  # Unmapped offsets fall through and are discarded.
  defhw commit_write() do
    hdl_case <<wr_index::4>> do
      <<2::4>> -> merge_scratch()
      <<3::4>> -> merge_ctrl0()
      <<4::4>> -> merge_ctrl1()
      <<5::4>> -> merge_ctrl2()
      <<6::4>> -> merge_ctrl3()
    end
  end

  fsm :wr_state, clock: :aclk, reset: :rst, init: :idle do
    defaults do
      s_axi_awready = 0
      s_axi_wready  = 0
      s_axi_bvalid  = 0
      s_axi_bresp   = 0
      ctrl2_wr      = 0
    end

    case wr_state do
      :idle ->
        s_axi_awready = 1
        # Full handshake: ARREADY is low on the first cycle here, so testing
        # AWVALID alone would accept an address the master never saw accepted.
        on s_axi_awready and s_axi_awvalid do
          awaddr_q      = s_axi_awaddr
          s_axi_awready = 0
          next :data
        end

      :data ->
        s_axi_wready = 1
        on s_axi_wready and s_axi_wvalid do
          commit_write()

          if wr_index == 5 do
            ctrl2_wr = 1
          end

          s_axi_wready = 0
          next :resp
        end

      :resp ->
        s_axi_bvalid = 1
        s_axi_bresp  = 0
        on s_axi_bvalid and s_axi_bready do
          s_axi_bvalid = 0
          next :idle
        end
    end
  end

  fsm :rd_state, clock: :aclk, reset: :rst, init: :idle do
    defaults do
      s_axi_arready = 0
      s_axi_rvalid  = 0
      s_axi_rresp   = 0
      status3_rd    = 0
    end

    case rd_state do
      :idle ->
        s_axi_arready = 1
        on s_axi_arready and s_axi_arvalid do
          araddr_q      = s_axi_araddr
          s_axi_arready = 0
          next :resp
        end

      :resp ->
        s_axi_rvalid = 1
        s_axi_rresp  = 0
        on s_axi_rvalid and s_axi_rready do
          s_axi_rvalid = 0
          # Fire on the completed handshake, not on entry to :resp, so a master
          # that holds RREADY low does not advance the pointer under a read it
          # has not taken yet.
          if rd_index == 10 do
            status3_rd = 1
          end

          next :idle
        end
    end
  end
end
