import sys, lzma, io
# выдержка NVIDIA в скобке: от записи FSRM_4 (0x0201a0 GPC / 0x0201a4 hub) до следующей записи 0x137100:
# число чтений таймера 0x009400 и его показания (нс) — настоящая длительность ожидания, не искажённая записью
path, bar0 = sys.argv[1], int(sys.argv[2], 16)
op = (lambda p: io.TextIOWrapper(lzma.open(p), encoding='utf-8', errors='replace')) if path.endswith('.xz') else (lambda p: open(p, errors='replace'))
pend = None
rows = []
for p in op(path):
    s = p.split()
    if len(s) < 6 or s[0] not in ('R', 'W'): continue
    a = int(s[4], 16)
    if not bar0 <= a < bar0 + 0x1000000: continue
    o = a - bar0; t = float(s[2]); v = int(s[5], 16)
    if s[0] == 'W' and o in (0x0201a0, 0x0201a4):
        pend = {'dom': 'GPC' if o == 0x0201a0 else 'hub', 't0': t, 'timer': [], 'n': 0}
        continue
    if pend is None: continue
    pend['n'] += 1
    if s[0] == 'R' and o == 0x009400: pend['timer'].append(v)
    if s[0] == 'W' and o == 0x137100:
        tm = pend['timer']
        rows.append((pend['dom'], pend['t0'], pend['n'], len(tm), (tm[-1] - tm[0]) if len(tm) > 1 else 0, (t - pend['t0']) * 1e6))
        pend = None
    elif pend['n'] > 60:
        pend = None
import collections
by = collections.defaultdict(list)
for r in rows: by[r[0]].append(r)
for dom in ('GPC', 'hub'):
    rs = by[dom]
    print('%s: скобок %d' % (dom, len(rs)))
    for r in rs[:14]:
        print('   %9.3f с  обращений до переключателя %2d, чтений таймера %d, по таймеру %5d нс (по записи %6.1f мкс)' % (r[1], r[2], r[3], r[4], r[5]))
    tm = [r[4] for r in rs if r[3] > 1]
    if tm: print('   по таймеру: мин %d, макс %d нс (между первым и последним чтением; истинная выдержка ≥ последнего чтения)' % (min(tm), max(tm)))
