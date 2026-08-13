#!/usr/bin/env bash
#
# nextpnr-xilinx regression harness.
#
# Every fix in the Tier 1 / Tier 2 plan touches code the radio design also
# goes through, so a fix for one defect can silently break another. This
# asserts a known verdict for each reproducer, INCLUDING the ones that are
# currently expected to FAIL: an expected-failure flipping to pass is how we
# detect a fix landing, and an expected-pass flipping to fail is how we detect
# a fix regressing something else.
#
#   scripts/regress.sh          fast tier (~1 min)
#   scripts/regress.sh --slow   adds the full radio build
#
# NOT covered here, and it matters: the hardware acceptance test. No change to
# nextpnr is finished until the radio still decodes on the board at
# deg_per_sample 11.25 / mag_cv 3.4e-4. See the footer this prints.
set -u
cd "$(dirname "$0")/.."
source scripts/openxc7-env.sh >/dev/null 2>&1

PROBE=designs/iserdes_probe
PART=xc7z020clg400-1
pass=0; fail=0; unexpected=()

# Two seeds, never one. Seed 6 of the IDELAYCTRL build routed, loaded, showed
# correct magic + heartbeat + RDY, and returned garbage over SPI. A single seed
# cannot distinguish a broken design from a broken seed.
SEEDS="1 7"

# stage: synth -> pnr -> fasm2frames. Echoes the furthest stage reached.
stage() {
  # Separate `local` statements on purpose: bash expands every word of a
  # `local` command BEFORE performing any of its assignments, so
  # `local seed=$3 base=..._$seed` expands $seed while it is still unset --
  # which under `set -u` aborts the function and made every reproducer report
  # an empty verdict. The harness's first run found a bug in the harness.
  local src=$1
  local xdc=$2
  local seed=$3
  local base=/tmp/regress_$(basename "${src%.v}")_$seed
  yosys -p "read_verilog -sv $PROBE/$src; synth_xilinx -flatten -nocarry -abc9 -family xc7 -top top; write_json $base.json" \
      > $base.yos.log 2>&1 || { echo "synth"; return; }
  nextpnr-xilinx --chipdb "$XC7_CHIPDB/xc7z020.bin" --xdc "$PROBE/$xdc" --json $base.json \
      --fasm $base.fasm --freq 32 --seed "$seed" > $base.pnr.log 2>&1 || { echo "pnr"; return; }
  fasm2frames --part $PART --db-root "$PRJXRAY_DB/zynq7" $base.fasm > $base.frames 2> $base.f2f.log \
      || { echo "frames"; return; }
  echo "ok"
}

# check <name> <src> <xdc> <expected furthest stage> <why>
check() {
  local name=$1 src=$2 xdc=$3 want=$4 why=$5
  local got seen=""
  for s in $SEEDS; do
    got=$(stage "$src" "$xdc" "$s")
    seen="$seen $s:$got"
  done
  # A verdict counts only if EVERY seed agrees. Disagreement is itself a result.
  local uniq
  # grep -v '^$' matters: $seen starts with a space, so the split yields an
  # empty leading field that otherwise counts as a second distinct verdict and
  # reports every reproducer as seed-dependent.
  uniq=$(echo "$seen" | tr ' ' '\n' | grep -v '^$' | sed 's/.*://' | sort -u | tr '\n' ',' | sed 's/,$//')
  if [ "$uniq" = "$want" ]; then
    printf '  PASS  %-24s %s\n' "$name" "($want as expected)"
    pass=$((pass+1))
  elif [ "$(echo "$uniq" | tr ',' '\n' | wc -l)" -gt 1 ]; then
    printf '  SEED  %-24s seeds disagree:%s  -- not a verdict\n' "$name" "$seen"
    unexpected+=("$name: seed-dependent$seen")
    fail=$((fail+1))
  else
    printf '  ****  %-24s got %s, expected %s  -- %s\n' "$name" "$uniq" "$want" "$why"
    unexpected+=("$name: $uniq (expected $want)")
    fail=$((fail+1))
  fi
}

# NOTE: run this from work/tier1, not from an individual fix branch. A fix
# branch is based on stable-backports and therefore does NOT contain the other
# fixes, so their reproducers will correctly report as still-broken. That is the
# harness working, not a regression -- but it is confusing at 2am.
echo "nextpnr regression -- $(cd "$OXC7/nextpnr-xilinx" 2>/dev/null && git branch --show-current) @ $(cd "$OXC7/nextpnr-xilinx" 2>/dev/null && git rev-parse --short HEAD)"
echo

echo "control -- must never break:"
check plain        t3_plain.v          t1.xdc ok     "the fabric-flop path the radio actually uses"
check iddr         t2_iddr.v           t1.xdc ok     "ILOGICE3_IFF must keep building"

echo
echo "expected failures -- these FLIP when their fix lands:"
check idelay_no_ctrl t6_idelay_no_ctrl.v t1.xdc pnr    "IDELAYE2 with no IDELAYCTRL must be REFUSED, not built into a dead bitstream"

echo
echo "expected passes:"
check iserdes_direct t1_iserdes.v      t1.xdc ok     "defect #3 FIXED: reserve_wires_for_arc compared pips, not distinct predecessor wires"
check iserdes_ifd    t5_no_ofb.v       t1.xdc ok     "ISERDESE2 via IDELAY with OFB/OCLK unconnected"
check iserdes_ofb    t4_iserdes_idelay.v t1.xdc ok     "defect #4 FIXED -- same design as iserdes_ifd but with OFB/OCLK/OCLKB tied to 0; must now behave identically"

if [ "${1:-}" = "--slow" ]; then
  echo
  echo "slow tier:"
  if IDELAY_TAP=0 mix run designs/libresdr_radio/build.exs --sweep 0..40 >/tmp/regress_radio.log 2>&1; then
    printf '  PASS  %-24s (routed, seed %s)\n' radio "$(cat designs/libresdr_radio/build/winning_seed.txt 2>/dev/null)"
    pass=$((pass+1))
  else
    printf '  ****  %-24s no seed routed in 0..40\n' radio
    unexpected+=("radio: no seed routed"); fail=$((fail+1))
  fi
fi

echo
echo "  $pass passed, $fail unexpected"
[ ${#unexpected[@]} -gt 0 ] && printf '    %s\n' "${unexpected[@]}"
cat <<'FOOT'

  NOT TESTED HERE: the board. No nextpnr change is finished until the radio
  still decodes on hardware. On the target:

      Nervezynq.PL.reload("/root/<new>.bin")
      # bring up, capture, then:
      Nervezynq.MIMO.validate(words)
      #=> deg_per_sample 11.25, mag_cv 3.4e-4   <- the acceptance criterion
FOOT
exit $fail
