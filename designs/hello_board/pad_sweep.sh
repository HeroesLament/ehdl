#!/bin/zsh
# pad_sweep.sh — sweep USB bd_dp/dn pad configs, record enumeration progress.
# Reuses cached yosys JSON + clocks/patch LPFs; only re-runs nextpnr/pack/flash.
# Non-destructive: all configs are electrically safe on the USB line.

cd /Users/mac.w/src/ehdl || exit 1
BUILD=designs/hello_board/build
TOP=hello_board_top
JSON=$BUILD/$TOP.json
CLOCKS=$BUILD/${TOP}_clocks.lpf
PATCH=$BUILD/${TOP}_patch.lpf
BASELPF=lib/hw/boards/ulx3s/ulx3s_v20_nextpnr.lpf
PORT=/dev/cu.usbserial-D01477
RESULTS=$BUILD/pad_sweep_results.txt

printf "%-18s  %-5s  %-5s  %-8s  %-4s  %s\n" TAG DEV ADDR Q RC NOTE > $RESULTS
echo "=== pad sweep start ==="

sweep_one () {
  drive=$1; slew=$2; pull=$3
  tag="D${drive}_S${slew}_P${pull}"
  vlpf=$BUILD/sweep_${tag}.lpf
  sed -E \
    -e "s|^IOBUF  PORT \"usb_fpga_bd_dp\".*|IOBUF  PORT \"usb_fpga_bd_dp\" PULLMODE=${pull} IO_TYPE=LVCMOS33 DRIVE=${drive} SLEWRATE=${slew};|" \
    -e "s|^IOBUF  PORT \"usb_fpga_bd_dn\".*|IOBUF  PORT \"usb_fpga_bd_dn\" PULLMODE=${pull} IO_TYPE=LVCMOS33 DRIVE=${drive} SLEWRATE=${slew};|" \
    "$BASELPF" > "$vlpf"

  if ! nextpnr-ecp5 --85k --package CABGA381 --json "$JSON" \
        --lpf "$vlpf" --lpf "$CLOCKS" --lpf "$PATCH" \
        --textcfg "$BUILD/$TOP.config" >/dev/null 2>"$BUILD/sweep_${tag}.err"; then
    printf "%-18s  %-5s  %-5s  %-8s  %-4s  %s\n" "$tag" "-" "-" "-" "-" "NEXTPNR_FAIL" | tee -a "$RESULTS"
    return
  fi
  ecppack "$BUILD/$TOP.config" "$BUILD/$TOP.bit" >/dev/null 2>&1 || {
    printf "%-18s  %-5s  %-5s  %-8s  %-4s  %s\n" "$tag" "-" "-" "-" "-" "ECPPACK_FAIL" | tee -a "$RESULTS"; return; }
  fujprog "$BUILD/$TOP.bit" >/dev/null 2>&1 || {
    printf "%-18s  %-5s  %-5s  %-8s  %-4s  %s\n" "$tag" "-" "-" "-" "-" "FLASH_FAIL" | tee -a "$RESULTS"; return; }

  # Let macOS debounce connect + reset + run enumeration, then observe a wide
  # window and record PEAK progress (a brief Address-state visit or a single
  # GET_DESCRIPTOR must not be missed by an early snapshot).
  sleep 6
  stty -f "$PORT" 9600 clocal cread raw 2>/dev/null
  raw=$(head -c 8000 "$PORT" | tr -d '\0')
  dev=$(echo "$raw"  | grep -oE "DEV[0-9]" | grep -oE "[0-9]$" | sort -rn | head -1)
  addr=$(echo "$raw" | grep -oE "A[0-9a-f][0-9a-f]" | sort -r | head -1)
  qset=$(echo "$raw" | grep -oE "Q=[0-9a-f]+" | sort -u | sed 's/Q=//' | tr '\n' '/')
  rc=$(echo "$raw"   | grep -oE "RC[0-9]" | tail -1)
  note=""
  [ -z "$dev" ] && note="NO_DASH"
  echo "$qset" | grep -q 0006 && note="${note} GETDESC!"
  printf "%-18s  %-5s  %-5s  %-8s  %-4s  %s\n" "$tag" "DEV${dev:--}" "${addr:--}" "${qset:--}" "${rc:--}" "$note" | tee -a "$RESULTS"
}

# Order: known-good drive (16) first. PULLMODE fixed NONE (KEEPER unbuildable on
# these pads and wrong for USB data anyway). SLEW is the key untested axis.
for slew in SLOW FAST; do
  for drive in 16 12 8; do
    sweep_one $drive $slew NONE
  done
done

echo "=== pad sweep done ==="
echo "--- results ---"
cat "$RESULTS"
echo SWEEP_ALL_DONE
