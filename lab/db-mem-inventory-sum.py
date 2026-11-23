#!/usr/bin/env python3
# Сводка описи (lab/db-mem-inventory.py) по поколениям и чипам: трасс, с разбираемыми скриптами PMU, скриптов, ремешков,
# какие блоки памяти пишутся внутри скриптов. Только чтение JSON. python3 -I lab/db-mem-inventory-sum.py [inventory.json]
import sys, os, json, collections
P = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser('~/Home/nouveau-archive/mem-survey/inventory.json')
d = json.load(open(P))
order = ['NV3x', 'NV4x', 'Tesla', 'Tesla2', 'Fermi', 'Kepler', 'Maxwell', 'Pascal', 'Volta+', '?']
by = collections.defaultdict(list)
for k, r in d.items(): by[(r['gen'], r['chip'])].append(r)
print('| поколение | чип | трасс | со скриптами PMU | скриптов | ремешков | блоки в скриптах (записей) | прямых записей FBPA+MPLL |')
print('|---|---|---|---|---|---|---|---|')
for g in order:
    for (gg, c), rs in sorted(by.items()):
        if gg != g: continue
        ws = sum(1 for r in rs if r['pmu_scripts']); ns = sum(r['pmu_scripts'] for r in rs)
        st = len({s for r in rs for s in r['strap']})
        bl = collections.Counter()
        for r in rs: bl.update(r['scr_writes'])
        hb = sum(r['host'].get(b, 0) for r in rs for b in ('FBPA общий 10fxxx', 'FBPA разделы 110-12f', 'MPLL 132xxx', 'такты Tesla 004xxx'))
        bls = ', '.join(f'{b.split()[0]} {n}' for b, n in bl.most_common())
        print(f'| {g} | {c} | {len(rs)} | {ws} | {ns} | {st} | {bls or "—"} | {hb} |')
