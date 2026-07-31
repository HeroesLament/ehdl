#!/usr/bin/env bash
# zinv_test.sh -- test the CMT ZINV_RST/ZINV_PWRDWN polarity fix with NO p&r.
#
# The fix is a two-bit change to an already-routed design, so the routed
# .fasm is reused verbatim and the only difference between the control and
# the candidate is those two bits. That removes the seed lottery, the router,
# and the placer from the experiment entirely -- which matters, because
# ~50% of routed bitstreams in this project are functionally broken for
# unrelated reasons and would otherwise be indistinguishable from a failed
# hypothesis.
#
#   ctl  = build/mmcm_b.fasm as routed          -> LOCKED expected 0 (known)
#   fix  = same + ZINV_RST + ZINV_PWRDWN        -> LOCKED expected 1
set -eu
cd ~/src/ehdl/designs/libresdr_radio
source ~/src/ehdl/scripts/openxc7-env.sh >/dev/null 2>&1

src=build/mmcm_b.fasm
site=$(grep -oE 'CMT_TOP_L_LOWER_B_X[0-9]+Y[0-9]+' $src | head -1)
out=build/mmcm_zinv
cp $src $out.fasm
{
  echo "$site.MMCME2_ADV.ZINV_RST"
  echo "$site.MMCME2_ADV.ZINV_PWRDWN"
} >> $out.fasm

fasm2frames --part xc7z020clg400-1 --db-root $PRJXRAY_DB/zynq7 $out.fasm > $out.frames 2>$out.err
xc7frames2bit --part_file $PRJXRAY_DB/zynq7/xc7z020clg400-1/part.yaml --part_name xc7z020clg400-1 \
  --frm_file $out.frames --output_file $out.bit >/dev/null 2>&1
cd ~/src/ehdl
mix run -e "Hw.Xilinx.Bit2Bin.convert!(\"designs/libresdr_radio/$out.bit\", \"designs/libresdr_radio/$out.bin\")" >/dev/null 2>&1
gzip -cf designs/libresdr_radio/$out.bin > designs/libresdr_radio/taps/serve/mmcm_zinv.bin.gz
ls -l designs/libresdr_radio/taps/serve/mmcm_zinv.bin.gz

# the two bits, so the change is auditable
echo "--- frames delta vs control"
fasm2frames --part xc7z020clg400-1 --db-root $PRJXRAY_DB/zynq7 designs/libresdr_radio/$src \
  > /tmp/ctl.frames 2>/dev/null
elixir scripts/frames_diff.exs /tmp/ctl.frames designs/libresdr_radio/$out.frames || true
