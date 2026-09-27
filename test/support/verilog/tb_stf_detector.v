// Hw.StfDetector co-simulation bench: the emitted RTL under iverilog, driven
// exactly as test/stf_detector_test.exs drives the EHDL simulator (valid for
// one cycle, then three idle cycles per sample; outputs read after each
// edge). stim.txt: "<n> <emin>" then n lines of "<i hex> <q hex>".
// out.txt: one line per detect pulse "<owner> <pr> <pi> <r>" (hex), then
// "C <det_count>".
`timescale 1ns/1ps
module tb;
  reg clk = 0, valid = 0, enable = 0;
  reg [11:0] i = 0, q = 0;
  reg [31:0] emin = 0;
  wire detect, pass;
  wire [31:0] det_pr, det_pi, det_r;
  wire [15:0] det_count;

  stf_detector dut (.clk(clk), .emin(emin), .valid(valid), .enable(enable),
    .i(i), .q(q), .det_pr(det_pr), .det_pi(det_pi), .det_r(det_r),
    .det_count(det_count), .detect(detect), .pass(pass));

  integer fi, fo, n, t, k, rc;
  reg [31:0] e;
  reg [11:0] a, b;

  task tick; begin #5 clk = 1; #5 clk = 0; end endtask
  task seen(input integer owner);
    if (detect) $fdisplay(fo, "%0d %h %h %h", owner, det_pr, det_pi, det_r);
  endtask

  initial begin
    fi = $fopen("stim.txt", "r");
    fo = $fopen("out.txt", "w");
    rc = $fscanf(fi, "%d %d\n", n, e);
    emin = e;
    tick; tick;
    enable = 1;
    for (t = 0; t < n; t = t + 1) begin
      rc = $fscanf(fi, "%h %h\n", a, b);
      i = a; q = b; valid = 1;
      tick; seen(t - 1);
      valid = 0;
      for (k = 0; k < 3; k = k + 1) begin tick; seen(t); end
    end
    for (k = 0; k < 6; k = k + 1) begin tick; seen(n - 1); end
    $fdisplay(fo, "C %0d", det_count);
    $fclose(fo);
    $finish;
  end
endmodule
