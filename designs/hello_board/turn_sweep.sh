#!/bin/zsh
# turn_sweep.sh — sweep the device turnaround delay (cycles from request armed to
# TX start) and measure control-IN completion + enumeration progress. USB FS needs
# the device to answer 2-6.5 bit-times (8-26 cyc) after the token EOP; too early
# (N~0) means the host is still in TX->RX turnaround and misses our packet.
# TC decode: [3:0]=cnt_adopt [7:4]=cnt_indone [11:8]=cnt_inep0 [15:12]=cnt_nak.
# Win = QSET reaches 0006 (GET_DESCRIPTOR) and/or indone approaches inep0.

cd /Users/mac.w/src/ehdl || exit 1
SIE=lib/hw/std/usb/sie.ex
BIT=designs/hello_board/build/hello_board_top.bit
PORT=/dev/cu.usbserial-D01477
export LC_ALL=C
RESULTS=designs/hello_board/build/turn_results.txt

printf "%-6s  %-8s  %-16s  %-16s\n" N PEAKDEV QSET TC_MAX > $RESULTS
echo "=== turnaround sweep start ==="

sweep_turn () {
  N=$1
  sed -i '' -E "s/turn_wait >= [0-9]+\)   # TURNSWEEP/turn_wait >= ${N})   # TURNSWEEP/" "$SIE"
  mix run designs/hello_board/build.exs > /tmp/turnb.log 2>&1
  if [ $? -ne 0 ]; then
    printf "%-6s  %-8s  %-16s  %-16s\n" "$N" "BUILDFAIL" "-" "-" | tee -a "$RESULTS"; return; fi
  pkill -9 -f "cat /dev" 2>/dev/null; sleep 1
  fujprog "$BIT" >/dev/null 2>&1
  sleep 10
  ( cat "$PORT" & CP=$!; sleep 8; kill $CP 2>/dev/null ) | tr -cd '[:print:]\n' > /tmp/turn.txt
  pdev=$(grep -oE "DEV[0-9]" /tmp/turn.txt | grep -oE "[0-9]" | sort -rn | head -1)
  qset=$(grep -oE "Q=[0-9a-f]+" /tmp/turn.txt | sort -u | sed 's/Q=//' | tr '\n' '/')
  tcmax=$(grep -oE "TC[0-9a-f]{12}" /tmp/turn.txt | sort -r | head -1)
  printf "%-6s  %-8s  %-16s  %-16s\n" "$N" "DEV${pdev:--}" "${qset:--}" "${tcmax:--}" | tee -a "$RESULTS"
}

for N in 0 4 8 12 16 24 32; do sweep_turn $N; done

# restore baseline
sed -i '' -E "s/turn_wait >= [0-9]+\)   # TURNSWEEP/turn_wait >= 0)   # TURNSWEEP/" "$SIE"
echo "=== turnaround sweep done ==="; cat "$RESULTS"; echo TURN_ALL_DONE
