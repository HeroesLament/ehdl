#!/bin/zsh
# thresh_sweep.sh — sweep the USB bus-reset SE0 threshold (usb_reset = turn_cnt >= N)
# and measure enumeration progress per threshold. Too-low N false-fires on short SE0
# and clears dev_addr mid-enum (never reaches A08); too-high N never detects the host
# reset (addr-8 deadlock returns). Find the window that reaches A08 AND advances Q.

cd /Users/mac.w/src/ehdl || exit 1
TOP=designs/hello_board/top.ex
BIT=designs/hello_board/build/hello_board_top.bit
PORT=/dev/cu.usbserial-D01477
RESULTS=designs/hello_board/build/thresh_results.txt
export LC_ALL=C

printf "%-8s  %-9s  %-7s  %-14s\n" THRESH A08_RATE PEAKDEV QSET > $RESULTS
echo "=== thresh sweep start ==="

read_peak () {  # -> sets globals PDEV PA QS ; arg: trials index (for tmp file)
  ( cat $PORT & CP=$!; sleep 6; kill $CP 2>/dev/null ) | tr -cd '[:print:]\n' > /tmp/ts.txt
  PDEV=$(grep -oE "DEV[0-9]" /tmp/ts.txt | grep -oE "[0-9]" | sort -rn | head -1)
  PA=$(grep -oE "EP[0-9] A[0-9a-f][0-9a-f]" /tmp/ts.txt | grep -oE "A[0-9a-f][0-9a-f]" | sort -r | head -1)
  QS=$(grep -oE "Q=[0-9a-f]+" /tmp/ts.txt | sort -u | sed 's/Q=//' | tr '\n' '/')
}

sweep_thresh () {
  N=$1
  sed -i '' -E "s/turn_cnt >= [0-9]+ *# SWEEP_THRESH/turn_cnt >= ${N}   # SWEEP_THRESH/" "$TOP"

  mix run designs/hello_board/build.exs > /tmp/tb.log 2>&1
  if [ $? -ne 0 ]; then
    printf "%-8s  %-9s  %-7s  %-14s\n" "$N" "BUILDFAIL" "-" "-" | tee -a "$RESULTS"; return; fi
  pkill -9 -f "cat /dev" 2>/dev/null; sleep 1
  fujprog "$BIT" > /tmp/tf.log 2>&1
  sleep 2

  reaches=0; peakdev=0; qall=""
  for tr in 1 2 3; do
    printf 'R' > $PORT 2>/dev/null
    sleep 9
    read_peak
    [ -n "$PDEV" ] && [ "$PDEV" -gt "$peakdev" ] 2>/dev/null && peakdev=$PDEV
    [ "$PA" = "A08" ] && reaches=$((reaches+1))
    qall="${qall}${QS}"
  done
  qset=$(echo "$qall" | tr '/' '\n' | grep -vE '^$' | sort -u | tr '\n' '/')
  printf "%-8s  %-9s  %-7s  %-14s\n" "$N" "${reaches}/3" "DEV${peakdev}" "${qset}" | tee -a "$RESULTS"
}

for N in 64 512 4096 12000; do
  sweep_thresh $N
done

# leave a sane default in the file
sed -i '' -E "s/turn_cnt >= [0-9]+ *# SWEEP_THRESH/turn_cnt >= 512   # SWEEP_THRESH/" "$TOP"
echo "=== thresh sweep done ==="; cat "$RESULTS"; echo THRESH_ALL_DONE
