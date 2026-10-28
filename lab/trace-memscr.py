#!/usr/bin/env python3
# Скрипты памяти PMU из записи mmiotrace драйвера NVIDIA: хост загружает их словами через порт 0x10a1c0 (адрес в памяти
# данных PMU, бит 24 — автоинкремент) и 0x10a1c4 (данные). Собираем каждую загрузку (адрес, время, слова), пробуем разобрать
# как скрипт (заголовки «длина<<16 | операция», операция 0x21 — записи регистров, 0x16 — конец) и выдаём JSON.
# Только чтение. python3 -I lab/trace-memscr.py ЗАПИСЬ.txt BAR0 ВЫХОД.json  (BAR0, например, 0xf4000000)
import sys, json, re, collections
path, bar0, out = sys.argv[1], int(sys.argv[2], 16), sys.argv[3]
A0, D0 = bar0 + 0x10a1c0, bar0 + 0x10a1c4
bursts = []; cur = None
with open(path, errors='replace') as f:
    for l in f:
        if l[0] != 'W': continue
        p = l.split()
        if len(p) < 6: continue
        addr = int(p[4], 16)
        if addr == A0:
            v = int(p[5], 16); cur = dict(t=float(p[2]), dmem=v & 0xffff, flags=v >> 16, words=[]); bursts.append(cur)
        elif addr == D0 and cur is not None:
            cur['words'].append(int(p[5], 16))
        else:
            cur = None   # другая запись прервала загрузку
def decode(w):
    i, ops = 0, []
    while i < len(w):
        ln, op = w[i] >> 16, w[i] & 0xffff
        if ln == 0 or i + ln > len(w) + 1: return None
        a = w[i + 1:i + ln]
        if op == 0x21:
            if len(a) % 2: return None
            ops += [('WR', a[k], a[k + 1]) for k in range(0, len(a), 2)]
        elif op == 0x16: ops.append(('END',)); return ops
        else: ops.append((f'OP{op:02x}', *a))
        i += ln
    return None
scripts = []
for b in bursts:
    ops = decode(b['words'])
    if ops and sum(1 for o in ops if o[0] == 'WR') >= 5:
        scripts.append(dict(t=b['t'], dmem=b['dmem'], nwords=len(b['words']), words=b['words'], ops=[list(o) for o in ops],
                            regs=[o[1] for o in ops if o[0] == 'WR']))
print(f'загрузок в PMU: {len(bursts)}, из них похожих на скрипт памяти: {len(scripts)}')
for s in scripts:
    wr = [o for o in s['ops'] if o[0] == 'WR']
    # частота цели по записи делителя памяти 0x137310 / MPLL 0x132004, если есть
    print(f"  t={s['t']:.3f} dmem={s['dmem']:#06x} слов {s['nwords']} записей {len(wr)} первые регистры: " + ' '.join(f'{r:06x}' for r in s['regs'][:6]))
json.dump(scripts, open(out, 'w'))
