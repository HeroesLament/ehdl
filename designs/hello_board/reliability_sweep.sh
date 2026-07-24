#!/bin/zsh
# reliability_sweep.sh — measure ENUMERATION RELIABILITY per pad config.
# Per config: flash, then force N clean re-enumerations ('R' over US1) and
# tabulate how often we reach USB Address state (DEV1/A08), peak DEV, max Q.
# Turns "Address state is rare" into a hard rate. Reuses cached yosys JSON.

cd /Users/mac.w/src/ehdl || exit 1
BUILD=designs/hello_board/build
TOP=hello_board_top
JSON=$BUILD/$TOP.json
CLOCKS=$BUILD/${TOP}_clocks.lpf
PATCH=$BUILD/${TOP}_patch.lpf
BASELPF=lib/hw/boards/ulx3s/ulx3s_v20_nextpnr.lpf
PORT=/dev/cu.usbserial-D01477
RESULTS=$BUILD/reliability_results.txt
TRIALS=5

printf "%-28s  %-10s  %-7s  %-8s  %s\n" CONFIG A08_RATE PEAKDEV MAXQ NOTE > $RESULTS
echo "=== reliability sweep start ==="

# args: bd_drive bd_slew pu_drive pu_slew(NONE=unspecified)
run_cfg () {
  bdD=$1; bdS=$2; puD=$3; puS=$4
  tag="bd${bdD}/${bdS}_pu${puD}/${puS}"
  vlpf=$BUILD/rel_$(echo $tag | tr '/' '-').lpf

  pu_line_dp="IOBUF  PORT \"usb_fpga_pu_dp\" PULLMODE=NONE IO_TYPE=LVCMOS33 DRIVE=${puD}"
  pu_line_dn="IOBUF  PORT \"usb_fpga_pu_dn\" PULLMODE=NONE IO_TYPE=LVCMOS33 DRIVE=${puD}"
  if [ "$puS" != "NONE" ]; then
    pu_line_dp="${pu_line_dp} SLEWRATE=${puS}"; pu_line_dn="${pu_line_dn} SLEWRATE=${puS}"
  fi
  pu_line_dp="${pu_line_dp};"; pu_line_dn="${pu_line_dn};"

  sed -E \
    -e "s|^IOBUF  PORT \"usb_fpga_bd_dp\".*|IOBUF  PORT \"usb_fpga_bd_dp\" PULLMODE=NONE IO_TYPE=LVCMOS33 DRIVE=${bdD} SLEWRATE=${bdS};|" \
    -e "s|^IOBUF  PORT \"usb_fpga_bd_dn\".*|IOBUF  PORT \"usb_fpga_bd_dn\" PULLMODE=NONE IO_TYPE=LVCMOS33 DRIVE=${bdD} SLEWRATE=${bdS};|" \
    -e "s|^IOBUF  PORT \"usb_fpga_pu_dp\".*|${pu_line_dp}|" \
    -e "s|^IOBUF  PORT \"usb_fpga_pu_dn\".*|${pu_line_dn}|" \
    "$BASELPF" > "$vlpf"

  if ! nextpnr-ecp5 --85k --package CABGA381 --json "$JSON" \
        --lpf "$vlpf" --lpf "$CLOCKS" --lpf "$PATCH" \
        --textcfg "$BUILD/$TOP.config" >/dev/null 2>"$BUILD/rel_${tag//\//-}.err"; then
    printf "%-28s  %-10s  %-7s  %-8s  %s\n" "$tag" "-" "-" "-" "NEXTPNR_FAIL" | tee -a "$RESULTS"; return; fi
  ecppack "$BUILD/$TOP.config" "$BUILD/$TOP.bit" >/dev/null 2>&1 || {
    printf "%-28s  %-10s  %-7s  %-8s  %s\n" "$tag" "-" "-" "-" "ECPPACK_FAIL" | tee -a "$RESULTS"; return; }
  fujprog "$BUILD/$TOP.bit" >/dev/null 2>&1 || {
    printf "%-28s  %-10s  %-7s  %-8s  %s\n" "$tag" "-" "-" "-" "FLASH_FAIL" | tee -a "$RESULTS"; return; }

  reaches=0; peakdev=0; maxq=0000
  t=1
  while [ $t -le $TRIALS ]; do
    printf 'R' > "$PORT" 2>/dev/null   # force clean re-enum (drop pullup)
    sleep 7
    stty -f "$PORT" 9600 clocal cread raw 2>/dev/null
    raw=$(head -c 12000 "$PORT" | tr -d '\0')
    d=$(echo "$raw"  | grep -oE "DEV[0-9]" | grep -oE "[0-9]$" | sort -rn | head -1)
    a=$(echo "$raw"  | grep -oE "A[0-9a-f][0-9a-f]" | sort -r | head -1)
    q=$(echo "$raw"  | grep -oE "Q=[0-9a-f]+" | sed 's/Q=//' | sort -r | head -1)
    [ -n "$d" ] && [ "$d" -gt "$peakdev" ] 2>/dev/null && peakdev=$d
    [ "$a" = "A08" ] && reaches=$((reaches+1))
    [ -n "$q" ] && [[ "$q" > "$maxq" ]] && maxq=$q
    t=$((t+1))
  done
  note=""
  [[ "$maxq" > "0005" ]] && note="GETDESC+!"
  printf "%-28s  %-10s  %-7s  %-8s  %s\n" "$tag" "${reaches}/${TRIALS}" "DEV${peakdev}" "${maxq}" "$note" | tee -a "$RESULTS"
}

run_cfg 16 FAST 16 NONE
run_cfg 12 FAST 16 NONE
run_cfg 16 FAST 16 FAST

echo "=== reliability sweep done ==="
echo "--- results ---"; cat "$RESULTS"; echo REL_ALL_DONE
