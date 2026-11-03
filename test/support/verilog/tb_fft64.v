// Hw.Fft64 co-simulation bench: the emitted RTL under iverilog, one sample
// per 4 cycles. stim.txt: "<n>" then n lines "<i hex> <q hex>" (18-bit).
// out.txt: per `out_valid` "<pos> <bin> <re hex> <im hex>" (26-bit).
`timescale 1ns/1ps
module tb;
  reg clk = 0, enable = 0, in_valid = 0;
  reg [17:0] in_i = 0, in_q = 0;
  reg [11:0] in_tag = 0;
  wire [11:0] out_tag;
  wire out_valid;
  wire [25:0] out_i, out_q;
  wire [5:0] out_pos, out_bin;

  fft64 dut (.clk(clk), .enable(enable), .in_valid(in_valid), .in_i(in_i), .in_q(in_q), .in_tag(in_tag),
    .out_valid(out_valid), .out_i(out_i), .out_q(out_q), .out_pos(out_pos), .out_bin(out_bin), .out_tag(out_tag));

  integer fi, fo, n, t, k, rc;
  reg [17:0] a, b;

  task tick; begin #5 clk = 1; #5 clk = 0; end endtask
  task seen;
    if (out_valid) $fdisplay(fo, "%0d %0d %h %h %0d", out_pos, out_bin, out_i, out_q, out_tag);
  endtask

  initial begin
    fi = $fopen("stim.txt", "r");
    fo = $fopen("out.txt", "w");
    rc = $fscanf(fi, "%d\n", n);
    tick; tick;
    enable = 1;
    for (t = 0; t < n; t = t + 1) begin
      rc = $fscanf(fi, "%h %h\n", a, b);
      in_i = a; in_q = b; in_tag = t / 64; in_valid = 1;
      tick; seen;
      in_valid = 0;
      for (k = 0; k < 3; k = k + 1) begin tick; seen; end
    end
    for (k = 0; k < 16; k = k + 1) begin tick; seen; end
    $fclose(fo);
    $finish;
  end
endmodule
