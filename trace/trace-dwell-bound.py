#!/usr/bin/env python3
# Порог ожидания NVIDIA в скобке FSRM по показаниям таймера: для каждой скобки (запись 0x0201a0 GPC / 0x0201a4 hub ...
# запись 0x137100) берём ПЕРВУЮ непрерывную серию чтений PTIMER (0x009400, у GF106 ещё 0x009410 вокруг) — цикл ожидания;
# он вышел на последнем чтении серии, значит порог T лежит в (предпоследнее − первое, последнее − первое].
# По всем скобкам: T > max(предпоследних), T <= min(последних). Дальнейшие чтения таймера (ожидания PLL и т. п.) не берём.
# Попутно: что драйвер читал/писал в скобке (адреса), значение 0x020130. Только чтение записи.
#   python3 -I trace/trace-dwell-bound.py ЗАПИСЬ(.txt|.xz) BAR0 [--show N]  (N — показать N первых скобок целиком)
import sys, lzma, io, collections
path, bar0 = sys.argv[1], int(sys.argv[2], 16)
show = int(sys.argv[sys.argv.index('--show') + 1]) if '--show' in sys.argv else 0
op = (lambda p: io.TextIOWrapper(lzma.open(p), encoding='utf-8', errors='replace')) if path.endswith('.xz') else (lambda p: open(p, errors='replace'))
pend, rows, shown, cfg2 = None, [], 0, collections.Counter()
for line in op(path):
    s = line.split()
    if len(s) < 6 or s[0] not in ('R', 'W'): continue
    try: a = int(s[4], 16)
    except ValueError: continue
    if not bar0 <= a < bar0 + 0x1000000: continue
    o = a - bar0; t = float(s[2]); v = int(s[5], 16)
    if s[0] == 'R' and o == 0x020130: cfg2[v] += 1
    if s[0] == 'W' and o in (0x0201a0, 0x0201a4):
        pend = {'dom': 'GPC' if o == 0x0201a0 else 'hub', 't0': t, 'acc': [], 'timer': []}
        continue
    if pend is None: continue
    pend['acc'].append((s[0], o, v, t))
    if s[0] == 'R' and o == 0x009400 and not pend.get('run_done'): pend['timer'].append((v, t))
    elif pend['timer'] and not (s[0] == 'R' and o in (0x009400, 0x009410)): pend['run_done'] = True
    if s[0] == 'W' and o == 0x137100:
        tm = pend['timer']
        if len(tm) >= 2:
            d = [(x[0] - tm[0][0]) & 0xffffffff for x in tm]
            rows.append((pend['dom'], pend['t0'], len(tm), d[-2], d[-1], (tm[1][1] - tm[0][1]) * 1e6 if len(tm) > 1 else 0))
        if shown < show:
            shown += 1
            print(f"--- скобка {pend['dom']} t={pend['t0']:.6f}:")
            for (k, oo, vv, tt) in pend['acc']:
                print(f"   {k} {oo:06x} {vv:08x}  +{(tt - pend['t0']) * 1e6:7.1f} мкс")
        pend = None
    elif len(pend['acc']) > 200:
        pend = None
print('0x020130 в чтениях:', {f'{k:08x}': c for k, c in cfg2.items()})
for dom in ('GPC', 'hub'):
    r = [x for x in rows if x[0] == dom]
    if not r: continue
    lo = max(x[3] for x in r); hi = min(x[4] for x in r)
    it = sorted(x[5] for x in r)
    print(f"{dom}: скобок {len(r)}, чтений таймера в цикле {min(x[2] for x in r)}–{max(x[2] for x in r)}; "
          f"порог T: больше {lo} нс, не больше {hi} нс; последнее−первое {min(x[4] for x in r)}–{max(x[4] for x in r)} нс; "
          f"шаг цикла по записи (медиана) {it[len(it)//2]:.1f} мкс")
