#!/usr/bin/env bash
#
# seed_sweep.sh -- characterise the seed lottery, one row per seed.
#
#   scripts/seed_sweep.sh 0 79            sweep seeds 0..79
#
# Writes designs/libresdr_radio/build/sweep.tsv:
#
#   seed  verdict  secs  net  from  to
#
# ## Why this is only now worth running
#
# Elaboration used to name generated signals from a node-global counter that
# never reset, so the netlist changed between runs and "seed N routes" was not
# a property of seed N. Every earlier sweep in this project -- 377 seeds, 755
# seeds -- was measuring seed variance and name variance together. With
# elaboration deterministic (see Hw.Compile.Elaborate.Gensym) a seed is finally
# a reproducible experiment.
#
# It also makes synthesis a one-off: the netlist no longer depends on the seed,
# so yosys runs once and each seed is just a nextpnr invocation. That is what
# makes sweeping 80 seeds affordable rather than an afternoon.
#
# ## What is recorded and why
#
# Not just pass/fail. nextpnr names the arc it gave up on:
#
#   ERROR: Failed to route arc 65 of net 'data_clk',
#          from SITEWIRE/BUFGCTRL_X0Y17/O to SITEWIRE/SLICE_X34Y90/CLKINV_OUT
#
# If those endpoints cluster -- always a clock net, always into a SLICE clock
# inverter -- the failure has an address and is a specific defect. If they are
# scattered, it is congestion. Those are different problems with different
# fixes, and pass/fail alone cannot distinguish them.
set -u
cd "$(dirname "$0")/.."
source scripts/openxc7-env.sh >/dev/null 2>&1

B=designs/libresdr_radio/build
CHIPDB="$XC7_CHIPDB/xc7z020.bin"
XDC=designs/libresdr_radio/libresdr.xdc
JSON=$B/libresdr_radio.json
LO=${1:-0}; HI=${2:-39}
OUT=$B/sweep.tsv

# Synthesise once. Deterministic elaboration is what makes this legitimate:
# every seed below sees the identical netlist, so the only variable is the seed.
if [ ! -f "$JSON" ] || [ "${FORCE_SYNTH:-0}" = 1 ]; then
  echo "synthesising once..."
  mix run designs/libresdr_radio/build.exs --seed "$LO" >/dev/null 2>&1 || true
fi
echo "netlist md5 $(md5 -q "$JSON")"

printf 'seed\tverdict\tsecs\tnet\tfrom\tto\n' > "$OUT"

for s in $(seq "$LO" "$HI"); do
  log=$B/sw_$s.log
  fasm=$B/sw_$s.fasm
  t0=$(date +%s)
  nextpnr-xilinx --chipdb "$CHIPDB" --xdc "$XDC" --json "$JSON" \
      --fasm "$fasm" --freq 50 --seed "$s" --verbose > "$log" 2>&1
  rc=$?
  t1=$(date +%s)

  if [ $rc -eq 0 ]; then
    printf '%s\trouted\t%s\t-\t-\t-\n' "$s" "$((t1-t0))" >> "$OUT"
    printf 'seed %-4s routed   %ss\n' "$s" "$((t1-t0))"
  else
    # "Failed to route arc N of net 'X', from A to B."
    line=$(grep -m1 'Failed to route arc' "$log" || true)
    net=$(sed -n "s/.*of net '\([^']*\)'.*/\1/p" <<<"$line")
    frm=$(sed -n 's/.*from \([^ ]*\) to .*/\1/p' <<<"$line")
    to=$(sed -n 's/.* to \([^ ]*\)\.*$/\1/p' <<<"$line")
    printf '%s\tfailed\t%s\t%s\t%s\t%s\n' "$s" "$((t1-t0))" "${net:--}" "${frm:--}" "${to:--}" >> "$OUT"
    printf 'seed %-4s FAILED   %ss  net=%s\n' "$s" "$((t1-t0))" "${net:--}"
    rm -f "$fasm"
  fi
done

echo
echo "--- verdicts"
awk -F'\t' 'NR>1{v[$2]++} END{for(k in v) printf "  %-8s %d\n", k, v[k]}' "$OUT"
echo "--- failing nets"
awk -F'\t' 'NR>1 && $2=="failed"{n[$4]++} END{for(k in n) printf "  %-24s %d\n", k, n[k]}' "$OUT" | sort -k2 -rn
echo "--- failing destinations (the address, if there is one)"
awk -F'\t' 'NR>1 && $2=="failed"{gsub(/_X[0-9]+Y[0-9]+/,"_*",$6); d[$6]++} END{for(k in d) printf "  %-40s %d\n", k, d[k]}' "$OUT" | sort -k2 -rn
echo
echo "wrote $OUT"
