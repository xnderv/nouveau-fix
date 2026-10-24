#!/usr/bin/env python3
# Разбор скриптов памяти PMU NVIDIA (массивы lab_nv_* в ramgf100.c лабораторного дерева) в список операций (JSON).
# python3 lab/nv-memscr-decode.py ПУТЬ/ramgf100.c ВЫХОД.json
import re, sys, json
src = open(sys.argv[1]).read()
arrs = {}
for m in re.finditer(r'static const u32 (lab_nv_\w+)\[\] = \{(.*?)\};', src, re.S):
    arrs[m.group(1)] = [int(x, 16) for x in re.findall(r'0x[0-9a-fA-F]+', m.group(2))]
def decode(w):
    i, ops = 0, []
    while i < len(w):
        h = w[i]; ln, op = h >> 16, h & 0xffff
        args = w[i + 1:i + ln]
        if op == 0x21:
            for k in range(0, len(args), 2): ops.append(('WR', args[k], args[k + 1]))
        elif op == 0x2e: ops.append(('DELAY_ns', args[0]))
        elif op == 0x01: ops.append(('WAIT_ADDR', args[0]))
        elif op == 0x00: ops.append(('WAIT_VAL', args[0]))
        elif op == 0x15: ops.append(('WAIT_MASK_TO', args[0], args[1]))
        elif op == 0x14: ops.append(('VBLANK', *args))
        elif op == 0x20: ops.append(('BLOCK' if args[0] else 'UNBLOCK',))
        elif op == 0x16: ops.append(('END',)); break
        else: ops.append((f'OP{op:02x}', *args))
        i += ln
    return ops
out = {}
for name, w in arrs.items():
    if 'scr' in name: out[name] = decode(w)
    else: out[name] = [('WR', w[k], w[k + 1]) for k in range(0, len(w), 2)]
json.dump(out, open(sys.argv[2], 'w'))
for name, ops in out.items():
    print(f'== {name}: {len(ops)} операций, записей {sum(1 for o in ops if o[0]=="WR")}')
