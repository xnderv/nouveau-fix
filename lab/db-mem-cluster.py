#!/usr/bin/env python3
# СВОЯ КЛАСТЕРИЗАЦИЯ скриптов памяти (23.11) по scripts.json, БЕЗ подсказок чипа и типа памяти: признаки скрипта —
# набор операций, набор регистров (разделы свёрнуты), упорядоченные пары соседних разных регистров (скелет). Расстояние —
# Жаккар по признакам; одинаковые наборы склеиваются; кластеризация — средняя связь (UPGMA), разрез по порогу.
# Только ПОСЛЕ разреза к кластерам прикладываются метки (поколение, тип памяти, чип, направление, полнота) — объяснение.
# Направление: tRFC (поле 0x10f290 биты 8–15, в тактах памяти) растёт с частотой — сравнение со скриптом-предшественником
# той же трассы; «частичный» — скрипт без таймингов 0x10f290. Только чтение.
#   python3 -I lab/db-mem-cluster.py [ПОРОГ=0.5] [ОПИСЬ_КАТАЛОГ]
import sys, os, json, collections
TH = float(sys.argv[1]) if len(sys.argv) > 1 else 0.5
OUT = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser('~/Home/nouveau-archive/mem-survey')
S = json.load(open(os.path.join(OUT, 'scripts.json')))
def fold(r):   # PASCAL_FOLD: у Pascal общий блок FBPA переехал 0x10fxxx -> 0x9a0xxx с теми же смещениями
    if 0x9a0000 <= r < 0x9a1000: r = 0x10f000 | (r & 0xfff)
    return f'P+{r & 0xfff:03x}' if 0x110000 <= r < 0x130000 else f'{r:06x}'
items = []
for k, d in S.items():
    if d['type'] not in ('DDR2', 'DDR3', 'GDDR3', 'GDDR5', 'GDDR5X'): continue
    prev_rfc = None
    for n, s in enumerate(d['scripts']):
        seq = []; ops = set(); w = {}
        for op, a in s['ops']:
            ops.add(op)
            if op == 0x21:
                for i in range(0, len(a), 2):
                    f = fold(a[i]); w[a[i]] = a[i + 1]
                    if not seq or seq[-1] != f: seq.append(f)
            else: seq.append(f'op{op:02x}')
        feat = frozenset({f'o{o:02x}' for o in ops} | {f'r{r}' for r in seq if not r.startswith('op')} |
                         {f'{a}>{b}' for a, b in zip(seq, seq[1:])})
        rfc = (w[0x10f290] >> 8) & 0xff if 0x10f290 in w else None
        if rfc is None: dr = 'частичный'
        elif prev_rfc is None: dr = 'первый'
        else: dr = 'подъём' if rfc > prev_rfc else ('спуск' if rfc < prev_rfc else 'та же')
        if rfc is not None: prev_rfc = rfc
        items.append(dict(trace=k, n=n, chip=d['chip'], gen=d['gen'], type=d['type'], dir=dr, feat=feat, seq=seq,
                          clk=('PLL' if 0x132004 in w else '') + ('+137320' if 0x137320 in w else '')))
# склеить одинаковые
uniq = collections.OrderedDict()
for i, it in enumerate(items): uniq.setdefault(it['feat'], []).append(i)
U = list(uniq); n = len(U)
def jd(a, b): return 1 - len(a & b) / len(a | b)
D = [[0.0] * n for _ in range(n)]
for i in range(n):
    for j in range(i + 1, n): D[i][j] = D[j][i] = jd(U[i], U[j])
# UPGMA
cl = {i: [i] for i in range(n)}; w = {i: len(uniq[U[i]]) for i in range(n)}
dist = {(i, j): D[i][j] for i in range(n) for j in range(i + 1, n)}
while len(cl) > 1:
    (a, b), m = min(dist.items(), key=lambda x: x[1])
    if m > TH: break
    na, nb = w[a], w[b]
    for c in list(cl):
        if c in (a, b): continue
        da = dist.pop((min(a, c), max(a, c))); db = dist.pop((min(b, c), max(b, c)))
        dist[(min(a, c), max(a, c))] = (da * na + db * nb) / (na + nb)
    dist.pop((a, b)); cl[a] += cl.pop(b); w[a] = na + nb
clusters = sorted(cl.values(), key=lambda c: -sum(len(uniq[U[u]]) for u in c))
print(f'# Кластеры скриптов памяти (порог {TH}): {len(items)} скриптов, {n} разных наборов признаков, {len(clusters)} кластеров\n')
fmt = lambda c: ', '.join(f'{k} {v}' for k, v in c.most_common(6))
for ci, c in enumerate(clusters):
    idx = [i for u in c for i in uniq[U[u]]]
    if len(idx) < 3: continue
    its = [items[i] for i in idx]
    g = collections.Counter(f"{x['gen']} {x['type']}" for x in its); ch = collections.Counter(x['chip'] for x in its)
    dr = collections.Counter(x['dir'] for x in its); ck = collections.Counter(x['clk'] or '—' for x in its)
    regs = collections.Counter(r for x in its for r in set(x['seq']) if not r.startswith('op'))
    core = [r for r, v in regs.items() if v >= 0.9 * len(its)]
    L = sorted(len(x['seq']) for x in its)
    print(f'## К{ci + 1}: {len(its)} скриптов, {len({x["trace"] for x in its})} трасс, длина (токенов) {L[0]}–{L[-1]}, медиана {L[len(L) // 2]}')
    print(f'- группы: {fmt(g)}\n- чипы: {fmt(ch)}\n- направление: {fmt(dr)}\n- такт в скрипте: {fmt(ck)}')
    print(f'- регистры в ≥ 90 % скриптов кластера ({len(core)}): {" ".join(sorted(core)[:40])}{" …" if len(core) > 40 else ""}\n')
json.dump([[dict((k, v) for k, v in items[i].items() if k not in ('feat', 'seq')) for u in c for i in uniq[U[u]]] for c in clusters],
          open(os.path.join(OUT, f'clusters-{TH}.json'), 'w'), ensure_ascii=False)
