#!/bin/zsh
# sync_sweep.sh — sweep the RX synchronizer DEPTH (2/3/4 flops) and measure
# control-IN completion. Prior art (Fomu/ValentyUSB) traced intermittent,
# per-build FS-USB enumeration failure to metastability in the bus synchronizer,
# fixed by deeper sync. Depths run as 2,3,4,2,3,4 -> TWO builds per depth, so
# same-depth disagreement = build-variance (metastability lottery) while a
# consistent depth trend = real effect.
# TC decode: [3:0]=cnt_adopt [7:4]=cnt_indone [11:8]=cnt_inep0 [15:12]=cnt_nak.

cd /Users/mac.w/src/ehdl || exit 1
PHY=lib/hw/std/usb/fs_phy.ex
BIT=designs/hello_board/build/hello_board_top.bit
PORT=/dev/cu.usbserial-D01477
export LC_ALL=C
RESULTS=designs/hello_board/build/sync_results.txt

printf "%-7s  %-8s  %-10s  %-16s\n" DEPTH PEAKDEV QSET TC_MAX > $RESULTS
echo "=== sync depth sweep start ==="

sweep_depth () {
  DEPTH=$1
  IDX=$((DEPTH - 1))   # depth 2->s1, 3->s2, 4->s3
  sed -i '' -E "s/(_sync = d[pn]_s)[0-9](   # SYNCDEPTH)/\1${IDX}\2/" "$PHY"
  mix run designs/hello_board/build.exs > /tmp/syncb.log 2>&1
  if [ $? -ne 0 ]; then
    printf "%-7s  %-8s  %-10s  %-16s\n" "$DEPTH" "BUILDFAIL" "-" "-" | tee -a "$RESULTS"; return; fi
  pkill -9 -f "cat /dev" 2>/dev/null; sleep 1
  fujprog "$BIT" >/dev/null 2>&1
  sleep 11
  ( cat "$PORT" & CP=$!; sleep 9; kill $CP 2>/dev/null ) | tr -cd '[:print:]\n' > /tmp/sync.txt
  pdev=$(grep -oE "DEV[0-9]" /tmp/sync.txt | grep -oE "[0-9]" | sort -rn | head -1)
  qset=$(grep -oE "Q=[0-9a-f]+" /tmp/sync.txt | sort -u | sed 's/Q=//' | tr '\n' '/')
  tcmax=$(grep -oE "TC[0-9a-f]{12}" /tmp/sync.txt | sort -r | head -1)
  printf "%-7s  %-8s  %-10s  %-16s\n" "$DEPTH" "DEV${pdev:--}" "${qset:--}" "${tcmax:--}" | tee -a "$RESULTS"
}

for D in 2 3 4 2 3 4; do sweep_depth $D; done

# restore baseline depth 2
sed -i '' -E "s/(_sync = d[pn]_s)[0-9](   # SYNCDEPTH)/\11\2/" "$PHY"
echo "=== sync depth sweep done ==="; cat "$RESULTS"; echo SYNC_ALL_DONE
