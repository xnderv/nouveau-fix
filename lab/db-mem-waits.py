#!/usr/bin/env python3
# ОЖИДАНИЯ ПОСЛЕ СТРОБА 0x13d8x4 В СКРИПТАХ ПАМЯТИ FERMI (24.11). По scripts.json (lab/db-mem-scripts.py), все трассы Fermi:
#   1) что стоит сразу после каждой записи 0x13d8x4 = 0: в старых драйверах NVIDIA — оп 0x13 (ожидание, нс) с аргументом
#      N × единица, в новых — оп 0x3a (N), а единицу задаёт оп 0x39;
#   2) единицы оп 0x39 в новых драйверах и проверка: каждый аргумент оп 0x13 старых драйверов = N × единица, N = 1…10,
#      единица из набора оп 0x39 (≈ 25 периодов такта памяти в нс) или 250 нс (DDR3, где оп 0x39 нет);
#   3) связь с числом контроллеров памяти: пара «строб + ожидание» есть только там, где контроллеров FBPA два и больше.
# Источник смысла остальных операций — документация envytools (docs/nvrm/pmu/seq.rst, 2013): 0x13 и 0x2e — ожидание в нс,
# 0x34 — отметка времени в выходной буфер. Оп 0x39 и 0x3a в ней нет (появились позже) — их смысл выведен здесь из записей.
# Только чтение; участники обезличены.   python3 -I lab/db-mem-waits.py [ОПИСЬ_КАТАЛОГ]
import sys, os, json, collections
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser('~/Home/nouveau-archive/mem-survey')
S = json.load(open(os.path.join(OUT, 'scripts.json')))
topo = json.load(open(os.path.join(OUT, 'topo.json'))) if os.path.exists(os.path.join(OUT, 'topo.json')) else {}
strobe = lambda a: len(a) >= 2 and 0x13d800 <= a[-2] < 0x13da00
units = collections.Counter(); rows = []; old_args = collections.Counter(); bad_follow = 0; total = 0
for k, d in sorted(S.items()):
    if d['gen'] != 'Fermi' or not d['scripts']: continue
    nxt = collections.Counter(); u = collections.Counter(); nstrobe = 0
    for s in d['scripts']:
        ops = s['ops']
        for i, (op, a) in enumerate(ops):
            if op == 0x39: u[a[0]] += 1; units[a[0]] += 1
            if op == 0x21 and strobe(a):
                nstrobe += 1; total += 1
                o2, a2 = ops[i + 1] if i + 1 < len(ops) else (None, [])
                if o2 not in (0x13, 0x3a): bad_follow += 1
                nxt[(o2, a2[0] if a2 else None)] += 1
                if o2 == 0x13: old_args[(d['type'], a2[0])] += 1
    t = topo.get(k, {})
    era = 'новый (оп 0x3a)' if any(o == 0x3a for o, _ in nxt) else 'старый (оп 0x13)' if nxt else '—'
    rows.append((k, d['type'], t.get('fbp'), t.get('fbpa'), nstrobe, era, sorted(u), sorted(v for (o, v), _ in nxt.items())))
print('| трасса | память | разделов | контроллеров (если читались) | стробов 0x13d8x4 | драйвер | единицы оп 0x39 | аргументы ожидания |')
print('|---|---|---|---|---|---|---|---|')
for r in rows: print('| ' + ' | '.join('—' if x is None else (' '.join(map(str, x)) if isinstance(x, list) else str(x)) for x in r) + ' |')
print(f'\nВсего стробов: {total}; за стробом идёт НЕ ожидание (оп 0x13 / 0x3a): {bad_follow}.')
U = sorted(units)
print('Единицы оп 0x39 в новых драйверах (нс: сколько раз): ' + ', '.join(f'{u}: {n}' for u, n in sorted(units.items())))
ok = collections.Counter()
for (typ, a), n in old_args.items():
    cand = [250] if typ == 'DDR3' else U + [u + d for u in U for d in (-1, 1)]     # ±1 нс — округление единицы у разных плат
    hit = any(a % u == 0 and 1 <= a // u <= 10 for u in cand if u > 0)
    ok[(typ, hit)] += n
for typ in sorted({t for t, _ in ok}):
    print(f'Старые драйверы, {typ}: аргумент оп 0x13 = N × единица (N = 1…10) в {ok[(typ, True)]} случаях из {ok[(typ, True)] + ok[(typ, False)]}')
