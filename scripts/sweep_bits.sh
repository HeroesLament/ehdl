#!/usr/bin/env bash
# sweep_bits.sh -- turn every routed .fasm from seed_sweep.sh into a loadable
# bitstream, so the SECOND failure mode can be measured.
#
# Routing is only half the lottery. Historically ~50% of bitstreams that route
# are functionally dead on the board, and the only oracle for that has been
# loading them. This produces the full set so the hardware verdict can be
# attached to every routed seed, which is what makes a build-time predictor
# findable.
set -u
cd "$(dirname "$0")/.."
source scripts/openxc7-env.sh >/dev/null 2>&1
B=designs/libresdr_radio/build
PART=xc7z020clg400-1
n=0
for f in $B/sw_*.fasm; do
  s=$(basename "$f" .fasm | sed 's/sw_//')
  fasm2frames --part $PART --db-root "$PRJXRAY_DB/zynq7" "$f" > $B/sw_$s.frames 2>/dev/null || { echo "seed $s f2f FAILED"; continue; }
  xc7frames2bit --part_file "$PRJXRAY_DB/zynq7/$PART/part.yaml" --part_name $PART \
    --frm_file $B/sw_$s.frames --output_file $B/sw_$s.bit >/dev/null 2>&1 || { echo "seed $s bit FAILED"; continue; }
  mix run -e "Hw.Xilinx.Bit2Bin.convert!(\"$B/sw_$s.bit\", \"$B/sw_$s.bin\")" >/dev/null 2>&1
  gzip -cf $B/sw_$s.bin > designs/libresdr_radio/taps/serve/sw_$s.bin.gz
  rm -f $B/sw_$s.frames $B/sw_$s.bit $B/sw_$s.bin
  n=$((n+1)); printf 'sw_%s ' "$s"
done
echo; echo "staged $n bitstreams"
