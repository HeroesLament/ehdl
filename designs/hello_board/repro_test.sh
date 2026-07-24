#!/bin/zsh
# repro_test.sh — rebuild the SAME source N times (no changes) and measure
# control-IN completion each time. Tests whether the ported clock recovery
# (deterministic mid-bit sampling) REDUCED build-to-build variance. Baseline
# (old recovery) swung 0%..25% across identical builds; if the port clusters
# tight (ideally high), the metastability/sample-phase variance is fixed.
# TC decode: [3:0]=cnt_adopt [7:4]=cnt_indone [11:8]=cnt_inep0 [15:12]=cnt_nak.

cd /Users/mac.w/src/ehdl || exit 1
BIT=designs/hello_board/build/hello_board_top.bit
PORT=/dev/cu.usbserial-D01477
export LC_ALL=C
RESULTS=designs/hello_board/build/repro_results.txt

printf "%-6s  %-8s  %-10s  %-16s\n" BUILD PEAKDEV QSET TC_MAX > $RESULTS
echo "=== repro test start ==="

one_build () {
  I=$1
  mix run designs/hello_board/build.exs > /tmp/reprob.log 2>&1
  if [ $? -ne 0 ]; then
    printf "%-6s  %-8s  %-10s  %-16s\n" "$I" "BUILDFAIL" "-" "-" | tee -a "$RESULTS"; return; fi
  pkill -9 -f "cat /dev" 2>/dev/null; sleep 1
  fujprog "$BIT" >/dev/null 2>&1
  sleep 11
  ( cat "$PORT" & CP=$!; sleep 9; kill $CP 2>/dev/null ) | tr -cd '[:print:]\n' > /tmp/repro.txt
  pdev=$(grep -oE "DEV[0-9]" /tmp/repro.txt | grep -oE "[0-9]" | sort -rn | head -1)
  qset=$(grep -oE "Q=[0-9a-f]+" /tmp/repro.txt | sort -u | sed 's/Q=//' | tr '\n' '/')
  tcmax=$(grep -oE "TC[0-9a-f]{12}" /tmp/repro.txt | sort -r | head -1)
  printf "%-6s  %-8s  %-10s  %-16s\n" "$I" "DEV${pdev:--}" "${qset:--}" "${tcmax:--}" | tee -a "$RESULTS"
}

for I in 1 2 3 4; do one_build $I; done
echo "=== repro test done ==="; cat "$RESULTS"; echo REPRO_ALL_DONE
