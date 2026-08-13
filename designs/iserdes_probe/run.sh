#!/usr/bin/env bash
# Run one probe design through yosys -> nextpnr and report exactly where it stops.
set -u
src="$1"; xdc="${2:-t1.xdc}"; seed="${3:-1}"
base="${src%.v}"
cd "$(dirname "$0")"
source ~/src/ehdl/scripts/openxc7-env.sh >/dev/null 2>&1
yosys -p "read_verilog -sv $src; synth_xilinx -flatten -nocarry -abc9 -family xc7 -top top; write_json ${base}.json" > ${base}_yosys.log 2>&1
ys=$?
if [ $ys -ne 0 ]; then echo "$base: YOSYS FAIL"; grep -i error ${base}_yosys.log | head -3; exit 1; fi
nextpnr-xilinx --chipdb $XC7_CHIPDB/xc7z020.bin --xdc "$xdc" --json ${base}.json \
  --fasm ${base}.fasm --freq 32 --seed $seed > ${base}_pnr.log 2>&1
ps=$?
if [ $ps -ne 0 ]; then
  echo "$base (seed $seed): PNR FAIL"
  grep -iE "^ERROR|Failed to route" ${base}_pnr.log | head -3
  exit 2
fi
echo "$base (seed $seed): ROUTED, fasm $(wc -l < ${base}.fasm) lines"
