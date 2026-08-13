#!/usr/bin/env bash
# One bitstream per PLLE2 CLKFBOUT_MULT.
set -u
cd ~/src/ehdl
source scripts/openxc7-env.sh >/dev/null 2>&1
out=designs/libresdr_radio/pll
mkdir -p $out
for m in "$@"; do
  [ -f $out/mult${m}.bin ] && { echo "mult $m: cached"; continue; }
  PLL_MULT=$m mix run designs/libresdr_radio/build.exs --sweep 0..200 > $out/mult${m}.log 2>&1
  if [ $? -ne 0 ]; then echo "mult $m: NO SEED ROUTED"; continue; fi
  cp designs/libresdr_radio/build/libresdr_radio.bin $out/mult${m}.bin
  gzip -c $out/mult${m}.bin > designs/libresdr_radio/taps/serve/mult${m}.bin.gz
  echo "mult $m: built (seed $(cat designs/libresdr_radio/build/winning_seed.txt))"
done
