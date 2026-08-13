#!/bin/bash
# Parallel nextpnr seed sweep.  usage: scripts/pnr_sweep.sh START END [JOBS]
#
# Routing this design is a coin flip: on the previous revision exactly one seed
# in 377 produced a routed result. At ~37s per attempt that is two hours of
# wall clock on one core for a 200-seed range, which is why this runs them in
# parallel and stops the moment any seed lands.
#
# Requires: . scripts/openxc7-env.sh  (for nextpnr-xilinx and XC7_CHIPDB)
set -u

START=${1:?start seed}
END=${2:?end seed}
JOBS=${3:-6}

DIR=designs/libresdr_radio/build
JSON=$DIR/libresdr_radio.json
XDC=designs/libresdr_radio/libresdr.xdc
CHIPDB=$XC7_CHIPDB/xc7z020.bin
SENT=$DIR/.routed

[ -f "$JSON" ] || { echo "no $JSON -- run build.exs once to synthesize"; exit 1; }
rm -f "$SENT"
mkdir -p "$DIR"

one() {
  local seed=$1
  # Cheap check, not a lock: a few extra attempts after a win cost seconds and
  # a real lock costs a portability argument.
  [ -f "$SENT" ] && return 0

  local fasm="$DIR/s${seed}.fasm"
  local log="$DIR/pnr_s${seed}.log"

  if nextpnr-xilinx --chipdb "$CHIPDB" --xdc "$XDC" --json "$JSON" \
       --fasm "$fasm" --freq 50 --seed "$seed" > "$log" 2>&1; then
    echo "$seed" > "$SENT"
    echo "*** ROUTED: seed $seed -> $fasm"
  else
    rm -f "$fasm"
    echo "    seed $seed failed"
  fi
}
export -f one
export DIR JSON XDC CHIPDB SENT

echo "sweeping seeds $START..$END across $JOBS jobs"
seq "$START" "$END" | xargs -P "$JOBS" -I{} bash -c 'one {}'

if [ -f "$SENT" ]; then
  echo
  echo "WINNER: seed $(cat "$SENT")"
else
  echo
  echo "no seed routed in $START..$END"
fi
