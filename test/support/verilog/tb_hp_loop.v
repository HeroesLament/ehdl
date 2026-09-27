// HP0 loopback gate (LibreSDRRadio.HPLoop.Top) against a behavioural PS7.
//
// The stub PS7 models what the loopback needs and nothing else: FCLK0 +
// FCLK_RESET0_N, EMIO GPIO, and HP0 as a DDR-backed AXI3 slave on both the
// read and write channels, with seeded random stalls (ARREADY parked high
// as the real PS does, RVALID gaps, AWREADY/WREADY stalls, BVALID delay).
//
// Test: fill the TX ring ahead of head in chunks, ring the doorbell, wait for
// the writer to catch up, verify every RX word byte-exact. 8704 bursts total
// = 1 MB + 64 KB, so both 1 MB rings wrap. Error counters must stay 0.
// Prints "DONE fails=<n>".
`timescale 1ns/1ps

module BUFG(input I, output O);
  assign O = I;
endmodule

module PS7 (
  output [3:0] FCLKCLK, output [3:0] FCLKRESETN,
  input MAXIGP0ACLK,
  output [11:0] MAXIGP0AWID, output [31:0] MAXIGP0AWADDR, output [3:0] MAXIGP0AWLEN,
  output [1:0] MAXIGP0AWSIZE, output [1:0] MAXIGP0AWBURST, output [2:0] MAXIGP0AWPROT,
  output MAXIGP0AWVALID, input MAXIGP0AWREADY,
  output [11:0] MAXIGP0WID, output [31:0] MAXIGP0WDATA, output [3:0] MAXIGP0WSTRB,
  output MAXIGP0WLAST, output MAXIGP0WVALID, input MAXIGP0WREADY,
  input [11:0] MAXIGP0BID, input [1:0] MAXIGP0BRESP, input MAXIGP0BVALID, output MAXIGP0BREADY,
  output [11:0] MAXIGP0ARID, output [31:0] MAXIGP0ARADDR, output [3:0] MAXIGP0ARLEN,
  output [1:0] MAXIGP0ARSIZE, output [1:0] MAXIGP0ARBURST, output [2:0] MAXIGP0ARPROT,
  output MAXIGP0ARVALID, input MAXIGP0ARREADY,
  input [11:0] MAXIGP0RID, input [31:0] MAXIGP0RDATA, input [1:0] MAXIGP0RRESP,
  input MAXIGP0RLAST, input MAXIGP0RVALID, output MAXIGP0RREADY,
  input SAXIHP0ACLK,
  input [5:0] SAXIHP0AWID, input [31:0] SAXIHP0AWADDR, input [3:0] SAXIHP0AWLEN,
  input [1:0] SAXIHP0AWSIZE, input [1:0] SAXIHP0AWBURST, input [1:0] SAXIHP0AWLOCK,
  input [3:0] SAXIHP0AWCACHE, input [2:0] SAXIHP0AWPROT, input [3:0] SAXIHP0AWQOS,
  input SAXIHP0AWVALID, output reg SAXIHP0AWREADY,
  input [5:0] SAXIHP0WID, input [63:0] SAXIHP0WDATA, input [7:0] SAXIHP0WSTRB,
  input SAXIHP0WLAST, input SAXIHP0WVALID, output reg SAXIHP0WREADY,
  output [5:0] SAXIHP0BID, output [1:0] SAXIHP0BRESP, output reg SAXIHP0BVALID, input SAXIHP0BREADY,
  output SAXIHP0ARESETN, output [5:0] SAXIHP0WACOUNT, output [7:0] SAXIHP0WCOUNT,
  input [5:0] SAXIHP0ARID, input [31:0] SAXIHP0ARADDR, input [3:0] SAXIHP0ARLEN,
  input [1:0] SAXIHP0ARSIZE, input [1:0] SAXIHP0ARBURST, input [1:0] SAXIHP0ARLOCK,
  input [3:0] SAXIHP0ARCACHE, input [2:0] SAXIHP0ARPROT, input [3:0] SAXIHP0ARQOS,
  input SAXIHP0ARVALID, output reg SAXIHP0ARREADY,
  output [5:0] SAXIHP0RID, output reg [63:0] SAXIHP0RDATA, output [1:0] SAXIHP0RRESP,
  output reg SAXIHP0RLAST, output reg SAXIHP0RVALID, input SAXIHP0RREADY,
  output [2:0] SAXIHP0RACOUNT, output [7:0] SAXIHP0RCOUNT,
  input [63:0] EMIOGPIOI, output [63:0] EMIOGPIOO, output [63:0] EMIOGPIOTN
);
  // DDR window 0x3FC0_0000 .. 0x3FFF_FFFF (4 MB) as 64-bit words.
  localparam [31:0] DDR_BASE = 32'h3FC00000;
  reg [63:0] ddr [0:524287];

  reg clk = 0, rstn = 0;
  always #5 clk = ~clk;
  assign FCLKCLK = {3'b0, clk};
  assign FCLKRESETN = {3'b111, rstn};

  reg [63:0] gpio_o = 64'd0;
  assign EMIOGPIOO = gpio_o;
  assign EMIOGPIOTN = 64'd0;

  assign MAXIGP0AWVALID = 0; assign MAXIGP0WVALID = 0; assign MAXIGP0ARVALID = 0;
  assign MAXIGP0BREADY = 0; assign MAXIGP0RREADY = 0;
  assign SAXIHP0ARESETN = rstn;
  assign SAXIHP0BID = 0; assign SAXIHP0BRESP = 0;
  assign SAXIHP0RID = 0; assign SAXIHP0RRESP = 0;
  assign SAXIHP0WACOUNT = 0; assign SAXIHP0WCOUNT = 0;
  assign SAXIHP0RACOUNT = 0; assign SAXIHP0RCOUNT = 0;

  integer seed = 20260926;
  function stall; input integer pct; begin stall = (($random(seed) & 32'h7fffffff) % 100) < pct; end endfunction
  function [18:0] widx; input [31:0] a; begin widx = (a - DDR_BASE) >> 3; end endfunction

  // Read slave: one burst at a time (the reader never has two outstanding).
  reg        r_busy = 0;
  reg [31:0] r_addr;
  reg [3:0]  r_left;
  integer    ar_protocol_errs = 0;
  always @(posedge clk) begin
    if (!rstn) begin
      SAXIHP0ARREADY <= 1; SAXIHP0RVALID <= 0; SAXIHP0RLAST <= 0; r_busy <= 0;
    end else begin
      if (SAXIHP0ARVALID && SAXIHP0ARREADY) begin
        if (r_busy) ar_protocol_errs = ar_protocol_errs + 1;
        if (SAXIHP0ARLEN != 4'd15 || SAXIHP0ARSIZE != 2'd3 || SAXIHP0ARBURST != 2'd1
            || SAXIHP0ARADDR[6:0] != 0) ar_protocol_errs = ar_protocol_errs + 1;
        r_busy <= 1; r_addr <= SAXIHP0ARADDR; r_left <= SAXIHP0ARLEN;
        SAXIHP0ARREADY <= 0;
      end
      if (SAXIHP0RVALID && SAXIHP0RREADY) begin
        SAXIHP0RVALID <= 0;
        if (SAXIHP0RLAST) begin r_busy <= 0; SAXIHP0ARREADY <= 1; end
        else begin r_addr <= r_addr + 8; r_left <= r_left - 1; end
      end else if (r_busy && !SAXIHP0RVALID && !stall(30)) begin
        SAXIHP0RVALID <= 1;
        SAXIHP0RDATA  <= ddr[widx(r_addr)];
        SAXIHP0RLAST  <= (r_left == 0);
      end
    end
  end

  // Write slave.
  reg        w_busy = 0;
  reg [31:0] w_addr;
  integer    aw_protocol_errs = 0;
  always @(posedge clk) begin
    if (!rstn) begin
      SAXIHP0AWREADY <= 0; SAXIHP0WREADY <= 0; SAXIHP0BVALID <= 0; w_busy <= 0;
    end else begin
      SAXIHP0AWREADY <= !w_busy && !SAXIHP0BVALID && !stall(40);
      if (SAXIHP0AWVALID && SAXIHP0AWREADY) begin
        if (SAXIHP0AWLEN != 4'd15 || SAXIHP0AWADDR[6:0] != 0) aw_protocol_errs = aw_protocol_errs + 1;
        w_busy <= 1; w_addr <= SAXIHP0AWADDR; SAXIHP0AWREADY <= 0;
      end
      SAXIHP0WREADY <= w_busy && !stall(30);
      if (SAXIHP0WVALID && SAXIHP0WREADY && w_busy) begin
        ddr[widx(w_addr)] <= SAXIHP0WDATA;
        w_addr <= w_addr + 8;
        if (SAXIHP0WLAST) begin w_busy <= 0; SAXIHP0WREADY <= 0; SAXIHP0BVALID <= 1; end
      end
      if (SAXIHP0BVALID && SAXIHP0BREADY) SAXIHP0BVALID <= 0;
    end
  end
endmodule

module tb;
  top dut ();

  localparam [31:0] TX = 32'h3FD00000, RX = 32'h3FF00000, RING = 32'h00100000;
  localparam integer CHUNK = 256;            // bursts per doorbell
  localparam integer TOTAL = 8704;           // 1 MB + 64 KB: both rings wrap
  integer fails = 0, done = 0, b, w, t;
  reg [63:0] st, want;
  reg [31:0] off;

  function [63:0] pat; input integer i; begin pat = {~i[31:0], i[31:0]} ^ 64'h5A5A_0000_0000_A5A5; end endfunction
  function [18:0] widx; input [31:0] a; begin widx = (a - 32'h3FC00000) >> 3; end endfunction

  task check(input cond, input [8*48-1:0] what);
    begin if (!cond) begin fails = fails + 1; $display("FAIL %0s", what); end end
  endtask

  initial begin
    for (w = 0; w < 524288; w = w + 1) dut.ps_ps7.ddr[w] = 64'hDEAD_BEEF_DEAD_BEEF;
    repeat (20) @(posedge dut.ps_ps7.clk);
    dut.ps_ps7.rstn = 1;
    repeat (10) @(posedge dut.ps_ps7.clk);

    // EMIO smoke bits before any DMA.
    st = dut.ps_ps7.EMIOGPIOI;
    check(st[61] == 1 && st[62] == 1 && st[63] == 0, "emio smoke 61..63");

    // run=1, both enables, head = base (empty).
    dut.ps_ps7.gpio_o = {TX, 32'h7};
    repeat (20) @(posedge dut.ps_ps7.clk);
    check(dut.ps_ps7.EMIOGPIOI[15:0] == 0, "no bursts while head==base");

    while (done < TOTAL) begin
      // Producer: fill the next CHUNK bursts (wrapping), then ring the bell.
      for (w = done * 16; w < (done + CHUNK) * 16; w = w + 1) begin
        off = (w * 8) & (RING - 1);
        dut.ps_ps7.ddr[widx(TX + off)] = pat(w);
      end
      done = done + CHUNK;
      dut.ps_ps7.gpio_o[63:32] = TX + ((done * 128) & (RING - 1));
      t = 0;
      while (dut.ps_ps7.EMIOGPIOI[31:16] != (done & 16'hFFFF) && t < 200000) begin
        @(posedge dut.ps_ps7.clk); t = t + 1;
      end
      if (t >= 200000) begin
        st = dut.ps_ps7.EMIOGPIOI;
        $display("TIMEOUT done=%0d rd_bursts=%0d wr_bursts=%0d rptr_lo=%h head=%h head_q=%h lb_count=%0d",
                 done, st[15:0], st[31:16], st[47:32], dut.ps_ps7.gpio_o[63:32], dut.head_q, dut.lb_count);
        $display("  aw v/r=%b/%b w v/r/last=%b/%b/%b b v/r=%b/%b w_busy=%b w_addr=%h wr_state=%0d wr_bursts=%0d s_avail=%b wr_en=%b rstn=%b",
                 dut.hp_awvalid, dut.hp_awready, dut.hp_wvalid, dut.hp_wready, dut.hp_wlast,
                 dut.hp_bvalid, dut.hp_bready, dut.ps_ps7.w_busy, dut.ps_ps7.w_addr, dut.wr_state, dut.wr_bursts, dut.wr_s_avail, dut.wr_enable, dut.eng_resetn);
        $finish;
      end
      for (w = (done - CHUNK) * 16; w < done * 16; w = w + 1) begin
        off = (w * 8) & (RING - 1);
        want = pat(w);
        if (dut.ps_ps7.ddr[widx(RX + off)] !== want) begin
          if (fails < 8) $display("FAIL word %0d: got %h want %h", w, dut.ps_ps7.ddr[widx(RX + off)], want);
          fails = fails + 1;
        end
      end
    end

    st = dut.ps_ps7.EMIOGPIOI;
    check(st[15:0] == (TOTAL & 16'hFFFF), "reader bursts == TOTAL");
    check(st[31:16] == (TOTAL & 16'hFFFF), "writer bursts == TOTAL");
    check(st[51:48] == 0, "rresp_errs == 0");
    check(st[55:52] == 0, "rlast_errs == 0");
    check(st[59:56] == 0, "bresp_errs == 0");
    check(st[47:32] == ((TOTAL * 128) & (RING - 1)) >> 4, "read_ptr[19:4] == head");
    check(dut.ps_ps7.ar_protocol_errs == 0, "AR protocol");
    check(dut.ps_ps7.aw_protocol_errs == 0, "AW protocol");

    // Quiesce: no stray bursts with head == read_ptr.
    repeat (500) @(posedge dut.ps_ps7.clk);
    check(dut.ps_ps7.EMIOGPIOI[15:0] == (TOTAL & 16'hFFFF), "idle when empty");

    $display("DONE fails=%0d bursts=%0d", fails, TOTAL);
    $finish;
  end
endmodule
