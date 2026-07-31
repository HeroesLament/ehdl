# source this: . scripts/openxc7-env.sh
#
# The openXC7 toolchain is not installed to a prefix -- it is four separate
# build trees under ~/src/openxc7. Locating them by hand is how the last radio
# bitstream ended up unreproducible, so they are pinned here.
OXC7="${OXC7:-$HOME/src/openxc7}"

# openXC7's prjxray-db fork. f4pga/prjxray-db has been frozen since 2021-12 and
# lacks the Zynq work this depends on.
#
# NOT $OXC7/prjxray/database -- that is the submodule mount point and it is
# EMPTY here (zynq7/ contains only settings.sh). Pointing at it gets you
# "Mapping file .../zynq7/mapping/devices.yaml does not exist" from fasm2frames.
# The populated db is the separately-cloned prjxray-db repo.
export PRJXRAY_DB="$OXC7/prjxray-db"
export XC7_CHIPDB="$OXC7/chipdb"

export PATH="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/bin:$OXC7/nextpnr-xilinx/build:$OXC7/prjxray/build/tools:$PATH"

# fasm2frames is a Python entry point and needs the venv interpreter; the shim
# in scripts/bin supplies it, so the venv does not have to be active.
export OXC7_PYTHON="$OXC7/venv/bin/python"
export OXC7_ROOT="$OXC7"

echo "openXC7 env:"
echo "  PRJXRAY_DB = $PRJXRAY_DB"
echo "  XC7_CHIPDB = $XC7_CHIPDB"
for t in yosys nextpnr-xilinx fasm2frames xc7frames2bit; do
  printf "  %-16s %s\n" "$t" "$(command -v $t || echo MISSING)"
done

# WHICH nextpnr. The binary is $OXC7/nextpnr-xilinx/build/nextpnr-xilinx, whose
# contents depend entirely on the branch checked out in that tree -- so a
# bitstream's provenance is invisible unless it is printed. The header of this
# file already records that locating the toolchain by hand is how the last
# radio bitstream became unreproducible; the branch is the other half of that.
#
# `ourfork` is the integration branch (all fixes applied), rebuilt from the
# topic branches by scripts/rebuild-ourfork.sh. Anything else means you are
# building against a subset of the fixes, which is legitimate when bisecting
# and a trap otherwise.
if [ -d "$OXC7/nextpnr-xilinx/.git" ]; then
  _b=$(git -C "$OXC7/nextpnr-xilinx" rev-parse --abbrev-ref HEAD 2>/dev/null)
  _c=$(git -C "$OXC7/nextpnr-xilinx" rev-parse --short HEAD 2>/dev/null)
  _dirty=$(git -C "$OXC7/nextpnr-xilinx" status --porcelain 2>/dev/null | head -1)
  printf "  %-16s %s @ %s%s\n" "nextpnr branch" "$_b" "$_c" \
    "${_dirty:+  *** UNCOMMITTED CHANGES ***}"
  [ "$_b" = "ourfork" ] || echo "  NOTE: not on 'ourfork' -- building against a SUBSET of the fixes"
  unset _b _c _dirty
fi
