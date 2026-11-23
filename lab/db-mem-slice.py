#!/usr/bin/env python3
# ШИРОКИЙ СРЕЗ скриптов памяти (23.11) по scripts.json (lab/db-mem-scripts.py): что общее у ВСЕХ записей, без деления
# заранее. Группа = поколение × тип памяти. Регистры разделов (0x110000–0x12ffff) сворачиваются в «раздел+смещение»
# (P+0xNNN), чтобы разные чипы с разным числом разделов сравнивались по роли. Четыре среза:
#   1) словарь операций скрипта по группам;
#   2) регистры: в какой доле трасс каждой группы встречаются; «сквозные» — во всех группах Fermi…Maxwell;
#   3) биты сквозных регистров: какие не меняются нигде (значение), какие меняются (маска) — по всем и по типам памяти;
#   4) порядок: для пар сквозных регистров — доля скриптов, где A раньше B (первое появление); устойчивый порядок = скелет.
# Только чтение. python3 -I lab/db-mem-slice.py [ОПИСЬ_КАТАЛОГ] > отчёт.md
import sys, os, json, collections, itertools
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser('~/Home/nouveau-archive/mem-survey')
S = json.load(open(os.path.join(OUT, 'scripts.json')))
GENS = ['Tesla2', 'Fermi', 'Kepler', 'Maxwell', 'Pascal']; CORE = ('Fermi', 'Kepler', 'Maxwell')
def fold(r):   # PASCAL_FOLD: у Pascal общий блок FBPA переехал 0x10fxxx -> 0x9a0xxx с теми же смещениями
    if 0x9a0000 <= r < 0x9a1000: r = 0x10f000 | (r & 0xfff)
    if 0x110000 <= r < 0x130000: return f'P+{r & 0xfff:03x}'
    return f'{r:06x}'
grp = lambda d: (d['gen'], d['type'])
traces = {k: d for k, d in S.items() if d['scripts'] and d['type'] in ('DDR2', 'DDR3', 'GDDR3', 'GDDR5', 'GDDR5X')}
groups = collections.defaultdict(list)
for k, d in traces.items(): groups[grp(d)].append(k)
G = sorted(groups, key=lambda g: (GENS.index(g[0]), g[1]))
gname = lambda g: f'{g[0]} {g[1]}'

print('# Широкий срез скриптов памяти\n')
print('Трассы с известным типом памяти и хотя бы одним скриптом памяти:\n')
print('| группа | трасс | чипов | скриптов |'); print('|---|---|---|---|')
for g in G:
    ks = groups[g]; print(f'| {gname(g)} | {len(ks)} | {len({traces[k]["chip"] for k in ks})} | {sum(len(traces[k]["scripts"]) for k in ks)} |')

# 1) операции
print('\n## 1. Словарь операций (доля скриптов группы, где операция есть)\n')
opc = {g: collections.Counter() for g in G}; nsc = collections.Counter()
for g in G:
    for k in groups[g]:
        for s in traces[k]['scripts']:
            nsc[g] += 1
            for op in {o for o, _ in s['ops']}: opc[g][op] += 1
allops = sorted({op for g in G for op in opc[g]})
print('| операция | ' + ' | '.join(gname(g) for g in G) + ' |'); print('|---' * (len(G) + 1) + '|')
for op in allops:
    print(f'| 0x{op:02x} | ' + ' | '.join(f'{100 * opc[g][op] // nsc[g]}' if opc[g][op] else '·' for g in G) + ' |')

# 2) регистры по трассам
regs_tr = {}; vals = collections.defaultdict(lambda: collections.defaultdict(list))
for k, d in traces.items():
    rs = set()
    for s in d['scripts']:
        for op, a in s['ops']:
            if op == 0x21:
                for i in range(0, len(a), 2):
                    f = fold(a[i]); rs.add(f); vals[f][grp(d)].append(a[i + 1])
    regs_tr[k] = rs
share = {}
for g in G:
    c = collections.Counter(r for k in groups[g] for r in regs_tr[k])
    for r, n in c.items(): share[(r, g)] = n / len(groups[g])
allregs = sorted({r for (r, _) in share})
coreG = [g for g in G if g[0] in CORE]
universal = [r for r in allregs if all(share.get((r, g), 0) >= 0.5 for g in coreG)]
everywhere = [r for r in universal if all(share.get((r, g), 0) >= 0.5 for g in G)]
print(f'\n## 2. Регистры\n\nВсего разных регистров (разделы свёрнуты): {len(allregs)}. '
      f'**Сквозных для Fermi–Maxwell** (есть хотя бы в половине трасс КАЖДОЙ группы Fermi/Kepler/Maxwell × DDR3/GDDR5): '
      f'{len(universal)}; из них есть и в GT21x, и в Pascal: {len(everywhere)}.\n')
print('Доля трасс группы, где регистр пишется в скриптах (сквозные):\n')
print('| регистр | ' + ' | '.join(gname(g) for g in G) + ' |'); print('|---' * (len(G) + 1) + '|')
for r in universal:
    print(f'| {r} | ' + ' | '.join(f'{int(100 * share.get((r, g), 0))}' if share.get((r, g)) else '·' for g in G) + ' |')
# по блокам: сколько регистров только у одного типа памяти
only = collections.Counter()
for r in allregs:
    t = {g[1] for g in coreG if share.get((r, g), 0) >= 0.5}
    only['оба типа' if t >= {'DDR3', 'GDDR5'} else ('только ' + '/'.join(sorted(t)) if t else 'редкие (< 50 % везде)')] += 1
print('\nВсе регистры Fermi–Maxwell по типу памяти (≥ 50 % трасс группы): ' + ', '.join(f'{k} {v}' for k, v in only.most_common()) + '\n')

# 3) биты
print('## 3. Биты сквозных регистров\n')
print('«пост.» — биты, одинаковые во ВСЕХ записях всех групп Fermi–Maxwell (значение под маской); «меняются» — маска изменчивых '
      'битов: все / только DDR3 / только GDDR5.\n')
print('| регистр | записей | меняются (все) | DDR3 | GDDR5 | пост. биты = значение |'); print('|---|---|---|---|---|---|')
def var(vs):
    if not vs: return None
    a = 0xffffffff; o = 0
    for v in vs: a &= v; o |= v
    return a ^ o, a
for r in universal:
    allv = [v for g in coreG for v in vals[r][g]]
    m, a = var(allv)
    d3 = var([v for g in coreG if g[1] == 'DDR3' for v in vals[r][g]]); g5 = var([v for g in coreG if g[1] == 'GDDR5' for v in vals[r][g]])
    print(f'| {r} | {len(allv)} | {m:08x} | {d3[0]:08x} | {g5[0]:08x} | маска {~m & 0xffffffff:08x} = {a & ~m & 0xffffffff:08x} |')

# 4) порядок
print('\n## 4. Порядок сквозных регистров (скелет)\n')
pre = collections.Counter(); both = collections.Counter(); ord_g = collections.defaultdict(collections.Counter)
for k, d in traces.items():
    if d['gen'] not in CORE: continue
    for s in d['scripts']:
        first = {}; n = 0
        for op, a in s['ops']:
            if op == 0x21:
                for i in range(0, len(a), 2):
                    f = fold(a[i])
                    if f in universal and f not in first: first[f] = n
                    n += 1
        for x, y in itertools.combinations(sorted(first), 2):
            both[(x, y)] += 1
            if first[x] < first[y]: pre[(x, y)] += 1
pairs = [(x, y, pre[(x, y)] / both[(x, y)], both[(x, y)]) for (x, y) in both if both[(x, y)] >= 20]
steady = [p for p in pairs if p[2] >= 0.95 or p[2] <= 0.05]
print(f'Пар сквозных регистров, встречающихся вместе хотя бы в 20 скриптах: {len(pairs)}; с устойчивым порядком (≥ 95 % в одну '
      f'сторону): {len(steady)} ({100 * len(steady) // max(1, len(pairs))} %).\n')
# порядок по среднему рангу
rank = collections.defaultdict(list)
for k, d in traces.items():
    if d['gen'] not in CORE: continue
    for s in d['scripts']:
        seen = [];
        for op, a in s['ops']:
            if op == 0x21:
                for i in range(0, len(a), 2):
                    f = fold(a[i])
                    if f in universal and f not in seen: seen.append(f)
        for i, f in enumerate(seen): rank[f].append(i / max(1, len(seen) - 1))
print('Средняя относительная позиция первого появления (0 — начало скрипта, 1 — конец):\n')
print('| регистр | позиция | разброс |'); print('|---|---|---|')
for f in sorted(rank, key=lambda f: sum(rank[f]) / len(rank[f])):
    v = rank[f]; m = sum(v) / len(v); sd = (sum((x - m) ** 2 for x in v) / len(v)) ** 0.5
    print(f'| {f} | {m:.2f} | {sd:.2f} |')
unsteady = sorted([p for p in pairs if 0.2 < p[2] < 0.8], key=lambda p: -p[3])[:15]
if unsteady:
    print('\nПары без устойчивого порядка (самые частые):\n'); print('| A | B | A раньше B | скриптов |'); print('|---|---|---|---|')
    for x, y, s, n in unsteady: print(f'| {x} | {y} | {int(100 * s)} % | {n} |')
