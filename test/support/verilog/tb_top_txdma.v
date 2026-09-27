// TX DMA gate for the full radio top (LibreSDRRadio.Top): DDR ring -> HP0
// reader -> dual-clock tbuf -> Hw.AD936xTxPort, observed at the ODDR inputs.
//
// PS7 is the behavioural stub from tb_hp_loop.v (DDR-backed HP0 with seeded
// random stalls). The other Xilinx primitives are pass-through models; the
// TX framer's pin-level behaviour is covered by its own tests and silicon,
// so frames are decoded from its ODDR D1/D2 inputs.
//
// A: cyclic mode, whole 1 MB ring = f(k). Prime with run=1/src=0, then
//    select DMA: the first DMA frame must be f(0), then NA consecutive
//    frames f(1).., no underflow after the sticky clear.
// B: streaming mode, ring = g(k), head = base + 64 KB (8192 frames). Must
//    play exactly g(0..8191), then zero frames with the underflow sticky
//    set and 512 bursts read.
// DATA_CLK 61.44 MHz (fastest 2R2T LVDS rate the config uses), AXI 100 MHz.
// Prints "DONE fails=<n>".
`timescale 1ns/1ps

module BUFG(input I, output O); assign O = I; endmodule
module IBUFDS #(parameter DIFF_TERM="TRUE", IBUF_LOW_PWR="TRUE", IOSTANDARD="LVDS_25")
  (input I, input IB, output O); assign O = I; endmodule
module OBUFDS #(parameter IOSTANDARD="LVDS_25", SLEW="SLOW")
  (input I, output O, output OB); assign O = I; assign OB = ~I; endmodule
module ODDR #(parameter DDR_CLK_EDGE="SAME_EDGE", INIT=0, SRTYPE="SYNC")
  (input C, input CE, input D1, input D2, input R, input S, output Q);
  reg q1 = 0, q2 = 0;
  always @(posedge C) begin q1 <= D1; q2 <= D2; end
  assign Q = C ? q1 : q2;
endmodule
module IDELAYE2 #(parameter IDELAY_TYPE="VAR_LOAD", IDELAY_VALUE=0, DELAY_SRC="IDATAIN",
  HIGH_PERFORMANCE_MODE="FALSE", PIPE_SEL="FALSE", CINVCTRL_SEL="FALSE",
  SIGNAL_PATTERN="DATA", REFCLK_FREQUENCY=200.0)
  (input IDATAIN, output DATAOUT, input C, input LD, input CE, input INC,
   input [4:0] CNTVALUEIN, output [4:0] CNTVALUEOUT);
  assign DATAOUT = IDATAIN; assign CNTVALUEOUT = CNTVALUEIN;
endmodule
module IDELAYCTRL(input REFCLK, input RST, output RDY); assign RDY = 1'b1; endmodule

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
  // Silicon drives these low out of reset; X here would poison the PL's
  // init-only FIFO pointers (tbuf has no reset by design).
  initial begin
    SAXIHP0ARREADY = 0; SAXIHP0RVALID = 0; SAXIHP0RLAST = 0; SAXIHP0RDATA = 0;
    SAXIHP0AWREADY = 0; SAXIHP0WREADY = 0; SAXIHP0BVALID = 0;
  end
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
  reg dclk = 0;
  always #8.138 dclk = ~dclk;   // 61.44 MHz

  top dut (.ad9363_data_clk_p(dclk), .ad9363_data_clk_n(~dclk));

  localparam [31:0] TX = 32'h3FD00000, RING = 32'h00100000;
  localparam integer WORDS = 131072, NA = 6000, NB = 8192;
  // EMIO bank 2 bits
  localparam [31:0] CLR = 1<<2, TXEN = 1<<3, SRC = 1<<8, RDEN = 1<<9, CYC = 1<<10, RUN = 1<<11;

  integer fails = 0, w, t, n, got_first;
  reg [47:0] fr, exp;
  reg [5:0] r0, r1, r2, r3, f0, f1, f2, f3;
  reg frd = 0;
  reg newframe = 0;

  function [63:0] fa; input integer k; reg [11:0] i1, q1, i2, q2;
    begin i1 = k; q1 = ~k; i2 = k * 7 + 3; q2 = (k >> 12) ^ 12'hA5C;
      fa = {16'hBEEF, q2, i2, q1, i1}; end endfunction
  function [63:0] gb; input integer k; reg [11:0] i1, q1, i2, q2;
    begin i1 = k * 5 + 1; q1 = k ^ 12'h3C3; i2 = ~(k * 3); q2 = 12'h111 + (k >> 3);
      gb = {16'hCAFE, q2, i2, q1, i1}; end endfunction
  function [18:0] widx; input [31:0] a; begin widx = (a - 32'h3FC00000) >> 3; end endfunction

  task check(input cond, input [8*48-1:0] what);
    begin if (!cond) begin fails = fails + 1; $display("FAIL %0s", what); end end
  endtask

  // Frame decoder: phases 0,1 (frame high) carry channel 1, MSB half first.
  integer ph = 3;
  always @(negedge dclk) begin
    newframe <= 0;
    if (dut.tx_fr_rise && !frd) ph = 0; else ph = ph + 1;
    frd <= dut.tx_fr_rise;
    case (ph)
      0: begin r0 = dut.tx_rise; f0 = dut.tx_fall; end
      1: begin r1 = dut.tx_rise; f1 = dut.tx_fall; end
      2: begin r2 = dut.tx_rise; f2 = dut.tx_fall; end
      3: begin r3 = dut.tx_rise; f3 = dut.tx_fall;
           fr = {f2, f3, r2, r3, f0, f1, r0, r1};   // {Q2, I2, Q1, I1}
           newframe <= 1; end
    endcase
  end

  task next_frame; begin @(posedge newframe); end endtask

  task set_gpio(input [31:0] b2); begin dut.ps_ps7.gpio_o[31:0] = b2; end endtask

  initial begin
    for (w = 0; w < WORDS; w = w + 1) dut.ps_ps7.ddr[widx(TX + w * 8)] = fa(w);
    repeat (20) @(posedge dut.ps_ps7.clk);
    dut.ps_ps7.rstn = 1;
    repeat (50) @(posedge dut.ps_ps7.clk);

    // ---- A: cyclic ---------------------------------------------------------
    set_gpio(TXEN);                                   // pattern out, reader idle
    repeat (400) @(posedge dut.ps_ps7.clk);
    set_gpio(TXEN | RUN | RDEN | CYC);                // prime
    t = 0;
    while (dut.tb_count_w < 1000 && t < 20000) begin @(posedge dut.ps_ps7.clk); t = t + 1; end
    check(t < 20000, "A: FIFO primed");
    repeat (2000) @(posedge dut.ps_ps7.clk);
    check(dut.rd_bursts == 63 || dut.rd_bursts == 64, "A: reader holds at ~full FIFO");
    $display("A: primed count_w=%0d bursts=%0d", dut.tb_count_w, dut.rd_bursts);
    set_gpio(TXEN | RUN | RDEN | CYC | SRC | CLR);
    // First non-pattern frame must be f(0). Pattern frames have Q2 = A5C and
    // I1 = ~Q1; f(0) is {A5C,003,FFF,000} which also satisfies that, so key on
    // I2: the pattern's I2 is a rotation of ctr, f(0)'s is 003.
    got_first = 0;
    for (n = 0; n < 64 && !got_first; n = n + 1) begin
      next_frame;
      exp = fa(0);
      if ($test$plusargs("dbg") && n < 12) $display("A search %0d: %h (want %h) dma=%b live=%b", n, fr, exp, dut.tx_dma, dut.tb_live);
      if (fr == exp) got_first = 1;
    end
    check(got_first, "A: f(0) appears after source switch");
    set_gpio(TXEN | RUN | RDEN | CYC | SRC);          // release clear
    for (n = 1; n < NA; n = n + 1) begin
      next_frame; exp = fa(n);
      if (fr !== exp) begin
        if (fails < 8) $display("FAIL A frame %0d: got %h want %h", n, fr, exp);
        fails = fails + 1;
      end
    end
    check(dut.tx_uflow == 0, "A: no underflow");
    check(dut.ps_ps7.ar_protocol_errs == 0, "A: AR protocol");
    $display("A: %0d frames checked, bursts=%0d rd_ptr=%h", NA, dut.rd_bursts, dut.rd_read_ptr);

    // ---- B: streaming, finite head ----------------------------------------
    set_gpio(TXEN);                                   // run low: reset + drain
    repeat (3000) @(posedge dut.ps_ps7.clk);
    check(dut.tb_count_w == 0, "B: drained");
    check(dut.rd_read_ptr == TX, "B: reader reset to base");
    for (w = 0; w < NB; w = w + 1) dut.ps_ps7.ddr[widx(TX + w * 8)] = gb(w);
    dut.ps_ps7.gpio_o[63:32] = TX + NB * 8;
    repeat (10) @(posedge dut.ps_ps7.clk);
    set_gpio(TXEN | RUN | RDEN);                      // prime
    repeat (3000) @(posedge dut.ps_ps7.clk);
    $display("B primed: head_q=%h rd_head=%h rptr=%h bursts=%0d cntw=%0d cntr=%0d space=%b rstn=%b en=%b cyc=%b emio=%h",
      dut.head_q, dut.rd_head, dut.rd_read_ptr, dut.rd_bursts, dut.tb_count_w, dut.tb_count_r,
      dut.rd_m_space, dut.rd_resetn, dut.rd_enable, dut.rd_cyclic, dut.emio_out);
    set_gpio(TXEN | RUN | RDEN | SRC | CLR);
    got_first = 0;
    for (n = 0; n < 64 && !got_first; n = n + 1) begin
      next_frame;
      exp = gb(0);
      if (fr == exp) got_first = 1;
    end
    check(got_first, "B: g(0) appears after source switch");
    set_gpio(TXEN | RUN | RDEN | SRC);
    for (n = 1; n < NB; n = n + 1) begin
      next_frame; exp = gb(n);
      // The framer latches frame k+1 while frame k is on the wire, so the
      // empty-FIFO latch (and the sticky) precedes the last data frame's
      // decode: check one frame early.
      if (n == NB - 2) check(dut.tx_uflow == 0, "B: no underflow while data lasts");
      if (fr !== exp) begin
        if (fails < 16) $display("FAIL B frame %0d: got %h want %h", n, fr, exp);
        fails = fails + 1;
      end
    end
    // Past the end: zero frames, sticky set.
    for (n = 0; n < 8; n = n + 1) next_frame;
    check(fr == 48'd0, "B: zero frames after the data ends");
    check(dut.tx_uflow == 1, "B: underflow sticky set");
    repeat (10) @(posedge dut.ps_ps7.clk);
    check(dut.tx_uflow_sync == 1, "B: underflow visible in AXI domain");
    check(dut.rd_bursts == NB / 16, "B: bursts == 512");
    check(dut.rd_read_ptr == TX + NB * 8, "B: read_ptr == head");
    check(dut.status0[22:10] == ((NB * 8) >> 7), "B: STATUS0 read_ptr field");
    check(dut.status0[31] == 1, "B: STATUS0 uflow bit");
    check(dut.ps_ps7.ar_protocol_errs == 0, "B: AR protocol");

    $display("DONE fails=%0d", fails);
    $finish;
  end

  initial if ($test$plusargs("dbg")) begin
    #3000;
    repeat (6) begin
      #2000;
      $display("t=%0t axi=%b dclk=%b rstn=%b emio=%h run=%b rd_rstn=%b wr=%h rbin=%h rg1=%h rdp=%h cntw=%h cntr=%h space=%b arv=%b st=%h",
        $time, dut.axi_clk, dut.data_clk, dut.fclk_reset0_n, dut.emio_out, dut.rd_run, dut.rd_resetn,
        dut.tb_wr_ptr, dut.tb_rd_bin, dut.tb_rg_s1, dut.tb_rd_ptr, dut.tb_count_w, dut.tb_count_r,
        dut.rd_m_space, dut.hp_arvalid, dut.rd_read_ptr);
    end
  end

  initial begin #20_000_000; $display("TIMEOUT"); $display("DONE fails=-1"); $finish; end
endmodule
