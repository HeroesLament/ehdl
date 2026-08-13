#!/usr/bin/env bash
# Add candidate MMCM RESERVED-field values to an already-routed FASM and rebuild
# the bitstream. No place & route: only the CMT's reserved bits change, so the
# routed design is reused verbatim and each candidate costs seconds rather than
# its own seed lottery.
#
#   patch_mmcm.sh <name> <LOCKREG1_RESERVED decimal> <LOCKREG2 0|1> <FILTREG2 decimal>
set -eu
cd ~/src/ehdl/designs/libresdr_radio
source ~/src/ehdl/scripts/openxc7-env.sh >/dev/null 2>&1
name=$1; l1=$2; l2=$3; f2=$4
src=build/libresdr_radio_s0.fasm
site=$(grep -oE 'CMT_TOP_L_LOWER_B_X[0-9]+Y[0-9]+' $src | head -1)
out=build/mmcm_$name
cp $src $out.fasm
b6=$(printf '%06d' $(echo "obase=2;$l1" | bc))
b10=$(printf '%010d' $(echo "obase=2;$f2" | bc))
{
  echo "$site.MMCME2_ADV.LOCKREG1_RESERVED[5:0] = 6'b$b6"
  echo "$site.MMCME2_ADV.FILTREG2_RESERVED[9:0] = 10'b$b10"
  [ "$l2" = "1" ] && echo "$site.MMCME2_ADV.LOCKREG2_RESERVED[0]"
} >> $out.fasm
fasm2frames --part xc7z020clg400-1 --db-root $PRJXRAY_DB/zynq7 $out.fasm > $out.frames 2>$out.err
xc7frames2bit --part_file $PRJXRAY_DB/zynq7/xc7z020clg400-1/part.yaml --part_name xc7z020clg400-1 \
  --frm_file $out.frames --output_file $out.bit >/dev/null 2>&1
cd ~/src/ehdl
mix run -e "Hw.Xilinx.Bit2Bin.convert!(\"designs/libresdr_radio/$out.bit\", \"designs/libresdr_radio/$out.bin\")" >/dev/null 2>&1
gzip -cf designs/libresdr_radio/$out.bin > designs/libresdr_radio/taps/serve/mmcm_$name.bin.gz
echo "$name: L1=$l1 L2=$l2 F2=$f2 -> $(stat -f%z designs/libresdr_radio/$out.bin) bytes"
