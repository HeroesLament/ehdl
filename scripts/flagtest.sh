# Which synth_xilinx invocation reproduces the flop mapping of the netlist that
# actually routed?  The routed top4.json has CE=0 SR=0 on all 383 flops; a naive
# re-synth of the same source gives CE=180 SR=275, and nextpnr then dies at
# CEUSEDMUX_OUT on every seed.
cd ~/src/ehdl
for v in "-flatten -nocarry -abc9 -nowidelut" "-flatten -nocarry -nowidelut" "-flatten -nocarry -abc9 -nosrl -nowidelut" "-flatten -nocarry -nowidelut -nodsp"; do
  yosys -p "read_verilog -sv _emit/top4.v; synth_xilinx $v -family xc7 -top top; write_json _emit/f.json" >/dev/null 2>&1 || { echo "ERR  [$v]"; continue; }
  V="$v" python3 -c "
import json,os
d=json.load(open('_emit/f.json')); c=d['modules']['top']['cells']
ce=sr=n=0
for x in c.values():
    if not x['type'].startswith('FD'): continue
    n+=1
    if (x['connections'].get('CE') or [None])[0] not in (0,1,'0','1'): ce+=1
    if (x['connections'].get('R') or x['connections'].get('S') or [None])[0] not in (0,1,'0','1'): sr+=1
inv=sum(1 for x in c.values() if x['type']=='INV')
print(f'FF={n:4} CE={ce:4} SR={sr:4} INV={inv:4}  [{os.environ[\"V\"]}]')
"
done
