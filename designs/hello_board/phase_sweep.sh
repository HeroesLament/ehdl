#!/bin/zsh
# phase_sweep.sh — sweep the RX sample phase (which of the 4 oversample slots we
# sample at, relative to the recovered edge). Now that the ported clock recovery
# makes builds DETERMINISTIC (repro test: rock-stable across rebuilds), this
# sweep finally measures the PARAMETER instead of metastability noise. Find the
# phase (bit centre) that maximises control-IN completion.
# TC decode: [3:0]=cnt_adopt [7:4]=cnt_indone [11:8]=cnt_inep0 [15:12]=cnt_nak.

cd /Users/mac.w/src/ehdl || exit 1
PHY=lib/hw/std/usb/fs_phy.ex
BIT=designs/hello_board/build/hello_board_top.bit
PORT=/dev/cu.usbserial-D01477
export LC_ALL=C
RESULTS=designs/hello_board/build/phase_results.txt

printf "%-7s  %-8s  %-10s  %-16s\n" PHASE PEAKDEV QSET TC_MAX > $RESULTS
echo "=== sample-phase sweep start ==="

sweep_phase () {
  P=$1
  sed -i '' -E "s/sample_cnt == [0-9]\)   # SAMPLEPHASE/sample_cnt == ${P})   # SAMPLEPHASE/" "$PHY"
  mix run designs/hello_board/build.exs > /tmp/phb.log 2>&1
  if [ $? -ne 0 ]; then
    printf "%-7s  %-8s  %-10s  %-16s\n" "$P" "BUILDFAIL" "-" "-" | tee -a "$RESULTS"; return; fi
  pkill -9 -f "cat /dev" 2>/dev/null; sleep 1
  fujprog "$BIT" >/dev/null 2>&1
  sleep 11
  ( cat "$PORT" & CP=$!; sleep 9; kill $CP 2>/dev/null ) | tr -cd '[:print:]\n' > /tmp/ph.txt
  pdev=$(grep -oE "DEV[0-9]" /tmp/ph.txt | grep -oE "[0-9]" | sort -rn | head -1)
  qset=$(grep -oE "Q=[0-9a-f]+" /tmp/ph.txt | sort -u | sed 's/Q=//' | tr '\n' '/')
  tcmax=$(grep -oE "TC[0-9a-f]{12}" /tmp/ph.txt | sort -r | head -1)
  printf "%-7s  %-8s  %-10s  %-16s\n" "$P" "DEV${pdev:--}" "${qset:--}" "${tcmax:--}" | tee -a "$RESULTS"
}

for P in 0 1 2 3; do sweep_phase $P; done

# leave phase 2 as default
sed -i '' -E "s/sample_cnt == [0-9]\)   # SAMPLEPHASE/sample_cnt == 2)   # SAMPLEPHASE/" "$PHY"
echo "=== sample-phase sweep done ==="; cat "$RESULTS"; echo PHASE_ALL_DONE
