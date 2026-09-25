// Independent check of Hw.AXIHPReader's emitted Verilog (module axihp_reader),
// outside the EHDL simulator. Run by test/verilog_strict_test.exs; mirrors
// test/axi_hp_reader_test.exs, so a disagreement between the two points at
// the EHDL simulator, not the RTL.
//
//   iverilog -g2012 -o tb tb_axi_hp_reader.v axi_hp_reader.v && vvp tb
//   (add -DDUMP for tb_axi_hp_reader.vcd)
//
// Stimulus changes on negedge, the DUT samples on posedge: no races.
`timescale 1ns/1ps

module tb;
  localparam [31:0] BASE = 32'h0010_0000;

  reg aclk = 0;
  always #5 aclk = ~aclk;

  reg aresetn = 0, m_space = 1, enable = 1;
  reg [31:0] base_addr = BASE, ring_size = 32'h1000, head_addr = BASE;
  reg m_axi_arready = 0, m_axi_rvalid = 0, m_axi_rlast = 0;
  reg [63:0] m_axi_rdata = 0;
  reg [1:0] m_axi_rresp = 0;
  reg [5:0] m_axi_rid = 0;

  wire m_wen, m_axi_rready, m_axi_arvalid;
  wire [63:0] m_data;
  wire [31:0] m_axi_araddr, read_ptr;
  wire [3:0] m_axi_arlen, m_axi_arcache, m_axi_arqos;
  wire [1:0] m_axi_arburst, m_axi_arsize, m_axi_arlock;
  wire [2:0] m_axi_arprot;
  wire [5:0] m_axi_arid;
  wire [15:0] bursts;
  wire [7:0] rresp_errs, rlast_errs;

  axihp_reader dut (
    .aclk(aclk), .aresetn(aresetn),
    .m_data(m_data), .m_wen(m_wen), .m_space(m_space),
    .base_addr(base_addr), .ring_size(ring_size), .head_addr(head_addr), .enable(enable),
    .read_ptr(read_ptr), .bursts(bursts), .rresp_errs(rresp_errs), .rlast_errs(rlast_errs),
    .m_axi_arid(m_axi_arid), .m_axi_araddr(m_axi_araddr), .m_axi_arlen(m_axi_arlen),
    .m_axi_arsize(m_axi_arsize), .m_axi_arburst(m_axi_arburst), .m_axi_arlock(m_axi_arlock),
    .m_axi_arcache(m_axi_arcache), .m_axi_arprot(m_axi_arprot), .m_axi_arqos(m_axi_arqos),
    .m_axi_arvalid(m_axi_arvalid), .m_axi_arready(m_axi_arready),
    .m_axi_rid(m_axi_rid), .m_axi_rdata(m_axi_rdata), .m_axi_rresp(m_axi_rresp),
    .m_axi_rlast(m_axi_rlast), .m_axi_rvalid(m_axi_rvalid), .m_axi_rready(m_axi_rready)
  );

  // --- sink: record every push ------------------------------------------------
  reg [63:0] sink [0:255];
  integer n_sink = 0;
  always @(posedge aclk) if (m_wen) begin sink[n_sink] = m_data; n_sink = n_sink + 1; end

  integer fails = 0;
  task check(input cond, input [8*64-1:0] what);
    begin
      if (cond) $display("PASS %0s", what);
      else begin $display("FAIL %0s", what); fails = fails + 1; end
    end
  endtask

  task reset_dut(input [31:0] ring, input [31:0] head, input en);
    begin
      @(negedge aclk);
      aresetn = 0; ring_size = ring; head_addr = head; enable = en; m_space = 1;
      m_axi_arready = 0; m_axi_rvalid = 0; m_axi_rlast = 0; m_axi_rresp = 0;
      repeat (2) @(negedge aclk);
      aresetn = 1;
      repeat (2) @(negedge aclk);
      n_sink = 0;
    end
  endtask

  // Wait for ARVALID, capture ARADDR/ARLEN, one-cycle ARREADY pulse.
  reg [31:0] ar_addr; reg [3:0] ar_len;
  task accept_ar(output ok);
    integer t;
    begin
      ok = 0;
      for (t = 0; t < 50 && !ok; t = t + 1) begin
        @(negedge aclk);
        if (m_axi_arvalid) ok = 1;
      end
      if (ok) begin
        ar_addr = m_axi_araddr; ar_len = m_axi_arlen;
        m_axi_arready = 1;
        @(negedge aclk);
        m_axi_arready = 0;
      end
    end
  endtask

  // Serve 16 beats tag+0..tag+15. gap: one RVALID-low cycle before each beat.
  // Each beat is held until sampled with RREADY high at a posedge.
  task serve(input [63:0] tag, input gap, input [1:0] resp, input integer last_at);
    integer i, t; reg took;
    begin
      for (i = 0; i < 16; i = i + 1) begin
        if (gap) begin m_axi_rvalid = 0; @(negedge aclk); end
        m_axi_rvalid = 1; m_axi_rdata = tag + i; m_axi_rresp = resp;
        m_axi_rlast = (i == last_at);
        took = 0;
        for (t = 0; t < 20 && !took; t = t + 1) begin
          took = m_axi_rready;   // registered: this is its value AT the coming posedge
          @(posedge aclk);
          @(negedge aclk);
        end
        if (!took) begin $display("FAIL beat %0d never accepted", i); fails = fails + 1; end
      end
      m_axi_rvalid = 0; m_axi_rlast = 0; m_axi_rresp = 0;
      @(negedge aclk);
    end
  endtask

  function sink_is(input [63:0] tag, input integer from);
    integer i; reg ok;
    begin
      ok = 1;
      for (i = 0; i < 16; i = i + 1) if (sink[from + i] !== tag + i) ok = 0;
      sink_is = ok;
    end
  endfunction

  task no_ar_for(input integer cycles, output quiet);
    integer t;
    begin
      quiet = 1;
      for (t = 0; t < cycles; t = t + 1) begin @(negedge aclk); if (m_axi_arvalid) quiet = 0; end
    end
  endtask

  reg ok, quiet;

  initial begin
`ifdef DUMP
    $dumpfile("tb_axi_hp_reader.vcd");
    $dumpvars(0, tb);
`endif

    // --- 1: one burst, shape and bookkeeping ------------------------------------
    reset_dut(32'h1000, BASE + 128, 1);
    accept_ar(ok);
    check(ok, "t1 ARVALID asserted");
    check(ar_addr == BASE && ar_len == 15, "t1 AR at tail, ARLEN 15");
    check(m_axi_arsize == 3 && m_axi_arburst == 1 && m_axi_arcache == 3, "t1 ARSIZE/ARBURST/ARCACHE");
    serve(64'hA000, 0, 0, 15);
    check(n_sink == 16 && sink_is(64'hA000, 0), "t1 16 beats pushed in order");
    check(read_ptr == BASE + 128 && bursts == 1, "t1 read_ptr +128, bursts 1");
    check(rresp_errs == 0 && rlast_errs == 0, "t1 no errors");
    no_ar_for(8, quiet);
    check(quiet, "t1 empty after catching up with head");

    // --- 2: RVALID gaps -------------------------------------------------------------
    @(negedge aclk); head_addr = BASE + 256;
    accept_ar(ok);
    check(ok && ar_addr == BASE + 128, "t2 second AR at +128");
    serve(64'hB000, 1, 0, 15);
    check(n_sink == 32 && sink_is(64'hB000, 16), "t2 gapped beats pushed in order, gaps push nothing");
    check(read_ptr == BASE + 256 && bursts == 2, "t2 read_ptr +256, bursts 2");

    // --- 3: gating ----------------------------------------------------------------------
    // Gated from reset release: enable low, so nothing can issue before the
    // checks start (an early AR would sit waiting for ARREADY and poison them).
    reset_dut(32'h1000, BASE + 128, 0);
    no_ar_for(6, quiet); check(quiet, "t3 no AR while disabled");
    @(negedge aclk); enable = 1; head_addr = BASE + 96;
    no_ar_for(6, quiet); check(quiet, "t3 no AR with < 1 burst readable");
    @(negedge aclk); head_addr = BASE + 128; m_space = 0;
    no_ar_for(6, quiet); check(quiet, "t3 no AR without sink space");
    @(negedge aclk); m_space = 1;
    accept_ar(ok); check(ok, "t3 AR once all three hold");
    serve(64'hC000, 0, 0, 15);

    // --- 4: wrap ------------------------------------------------------------------------
    reset_dut(32'h100, BASE + 128, 1);
    accept_ar(ok); check(ok && ar_addr == BASE, "t4 first AR at base");
    serve(64'hD000, 0, 0, 15);
    @(negedge aclk); head_addr = BASE;              // head wrapped: 128 B readable at +128
    accept_ar(ok); check(ok && ar_addr == BASE + 128, "t4 AR across wrap at +128");
    serve(64'hD100, 0, 0, 15);
    check(read_ptr == BASE && bursts == 2, "t4 tail wrapped to base");
    no_ar_for(6, quiet); check(quiet, "t4 empty when tail == head");

    // --- 5: error counters -------------------------------------------------------------
    reset_dut(32'h1000, BASE + 256, 1);
    accept_ar(ok);
    serve(64'hE000, 0, 2'd2, 15);
    check(rresp_errs == 16 && read_ptr == BASE + 128, "t5 SLVERR counted per beat, tail advances");
    accept_ar(ok);
    serve(64'hF000, 0, 0, 7);
    check(rlast_errs == 2 && bursts == 2, "t5 early RLAST counted twice, own count governs");

    $display("DONE fails=%0d", fails);
    $finish;
  end

  initial begin #200000; $display("FAIL timeout"); $finish; end
endmodule
