// Hw.LdpcDec co-simulation bench: the emitted RTL under iverilog. stim.txt:
// "<ncases>", then per case "<max_iter>" and 24 lines "<block word hex>"
// (27 x 6-bit LLR lanes, lane r = bits 6r+5..6r). out.txt per case: 12 lines
// "W <blk> <word hex>" (hard information bits), then "D <ok> <iters>".
`timescale 1ns/1ps
module tb;
  reg clk = 0, enable = 0, ld_valid = 0, start = 0;
  reg [4:0] ld_blk = 0;
  reg [161:0] ld_word = 0;
  reg [3:0] max_iter = 0;
  wire busy, done, ok, out_valid;
  wire [3:0] iters, out_blk;
  wire [26:0] out_word;

  ldpc_dec dut (.clk(clk), .enable(enable), .ld_valid(ld_valid), .ld_blk(ld_blk), .ld_word(ld_word),
    .start(start), .max_iter(max_iter), .busy(busy), .done(done), .ok(ok), .iters(iters),
    .out_valid(out_valid), .out_blk(out_blk), .out_word(out_word));

  integer fi, fo, nc, c, b, rc, mi, guard;
  reg [161:0] w;

  task tick; begin #5 clk = 1; #5 clk = 0; end endtask
  task seen;
    begin
      if (out_valid) $fdisplay(fo, "W %0d %h", out_blk, out_word);
      if (done) $fdisplay(fo, "D %0d %0d", ok, iters);
    end
  endtask

  initial begin
    fi = $fopen("stim.txt", "r");
    fo = $fopen("out.txt", "w");
    rc = $fscanf(fi, "%d\n", nc);
    tick; tick;
    enable = 1;
    for (c = 0; c < nc; c = c + 1) begin
      rc = $fscanf(fi, "%d\n", mi);
      for (b = 0; b < 24; b = b + 1) begin
        rc = $fscanf(fi, "%h\n", w);
        ld_blk = b; ld_word = w; ld_valid = 1;
        tick; seen;
      end
      ld_valid = 0;
      max_iter = mi; start = 1;
      tick; seen;
      start = 0;
      guard = 0;
      while (busy && guard < 20000) begin tick; seen; guard = guard + 1; end
      $fdisplay(fo, "N %0d", guard);
      tick; seen; tick; seen;
    end
    $fclose(fo);
    $finish;
  end
endmodule
