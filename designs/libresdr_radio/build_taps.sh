#!/usr/bin/env bash
# One bitstream per IDELAYE2 tap -- and SEVERAL SEEDS per tap.
#
# IDELAY_TYPE is FIXED, so the tap is a bitstream constant and an eye scan is
# literally N bitstreams. Each must independently win the routing lottery.
#
# Why more than one seed per tap: seed 6 of this very design routed, loaded,
# and reported correct magic + heartbeat + IDELAYCTRL RDY while returning
# garbage over SPI. A single bad seed is indistinguishable from a closed eye.
# With >=2 seeds per tap, a tap is only CLOSED if every seed fails.
set -u
cd ~/src/ehdl
source scripts/openxc7-env.sh >/dev/null 2>&1
out=designs/libresdr_radio/taps
serve=designs/libresdr_radio/taps/serve
mkdir -p $out $serve
want=${SEEDS_PER_TAP:-2}
for tap in "$@"; do
  have=$(ls $out/tap${tap}_s*.bin 2>/dev/null | wc -l | tr -d ' ')
  [ "$have" -ge "$want" ] && { echo "tap $tap: cached ($have seeds)"; continue; }
  # Synthesise ONCE per tap, then reuse the netlist across seeds. --skip-synth
  # must NOT span taps: @idelay_tap is a module attribute baked in at
  # elaboration, so reusing the JSON would silently emit the previous tap's
  # delay value under a new filename -- eight identical bitstreams and a
  # perfectly flat, perfectly wrong eye.
  synthed=0
  found=$have
  for seed in $(seq 0 60); do
    [ "$found" -ge "$want" ] && break
    [ -f $out/tap${tap}_s${seed}.bin ] && continue
    if [ "$synthed" = "0" ]; then
      IDELAY_TAP=$tap mix run designs/libresdr_radio/build.exs --seed $seed > /dev/null 2>&1
      rc=$?
      synthed=1
    else
      IDELAY_TAP=$tap mix run designs/libresdr_radio/build.exs --seed $seed --skip-synth > /dev/null 2>&1
      rc=$?
    fi
    [ $rc -ne 0 ] && continue
    cp designs/libresdr_radio/build/libresdr_radio.bin $out/tap${tap}_s${seed}.bin
    gzip -cf $out/tap${tap}_s${seed}.bin > $serve/tap${tap}_s${seed}.bin.gz
    found=$((found+1))
    echo "tap $tap: seed $seed routed ($found/$want)"
  done
  [ "$found" -lt "$want" ] && echo "tap $tap: ONLY $found seeds routed"
done
