#!/usr/bin/env python3
# ИСТОЧНИК ПОЛЕЙ «ЦЕЛЕВОГО УРОВНЯ» (класс 3, mem-meaning.md §12), 23.11. Для каждого скрипта памяти Fermi GDDR5 с записью
# таймингов 0x10f290 целевой уровень определяется ТОЧНО: 0x10f290 = T9<<24 | T7<<17 | T5<<8 | T3 из записи таймингов уровня
# (формула, проверенная до бита). Для найденного уровня берутся байты VBIOS: M (rammap), R (ramcfg ремешка), T (тайминги).
# Затем для каждого поля класса 3 ищется байт/бит/тетрада M, R или T, который однозначно предсказывает значение — по всем
# платам сразу (одно правило) и отдельно по чипу. Только чтение; участники обезличены.
#   python3 -I lab/db-mem-levelfields.py [ОПИСЬ_КАТАЛОГ] [БАЗА]
import sys, os, json, collections, importlib.util
HERE = os.path.dirname(os.path.abspath(__file__))
sp = importlib.util.spec_from_file_location('memgen2', os.path.join(HERE, 'memgen2.py')); mg = importlib.util.module_from_spec(sp); sp.loader.exec_module(mg)
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser('~/Home/nouveau-archive/mem-survey')
DB = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser('~/Home/nouveau-archive/nouveau_vbios_trace')
S = json.load(open(os.path.join(OUT, 'scripts.json'))); key = json.load(open(os.path.join(OUT, 'inventory-key.json')))
inv = json.load(open(os.path.join(OUT, 'inventory.json')))
FIELDS = {0x10f610: [(28, 4), (8, 1)], 0x10f614: [(28, 4), (8, 1)], 0x10f604: [(8, 2), (24, 1), (5, 1), (28, 4)],
          0x10f824: [(7, 1), (0, 2), (9, 2), (5, 1), (13, 2)], 0x1373ec: [(17, 1), (0, 4), (8, 4)],
          0x10f808: [(21, 1), (23, 1), (25, 1), (28, 3), (19, 1)], 0x10f830: [(21, 1), (30, 1)], 0x10f340: [(7, 1), (9, 1)]}
def roms(lab):
    d = os.path.dirname(os.path.join(DB, key[lab].split(':')[0]))
    return [os.path.join(d, x) for x in sorted(os.listdir(d)) if not x.endswith('.eml') and (x.lower().endswith(('.rom', '.bin')) or 'vbios' in x.lower())]
obs = collections.defaultdict(list)    # (рег, сдвиг, ширина, «последняя/первая запись») -> [(чип, трасса, значение, M, R, T)]
stat = collections.Counter()
for lab, d in sorted(S.items()):
    if d['gen'] != 'Fermi' or d['type'] != 'GDDR5' or not d['scripts']: continue
    rs = roms(lab); raw = {(int(s, 16) >> 2) & 0xf for s in inv[lab]['strap']}
    if len(rs) != 1 or len(raw) != 1: stat['трасса пропущена (образ/ремешок)'] += 1; continue
    try:
        vb0 = mg.Vbios(rs[0], 0); vb = mg.Vbios(rs[0], mg.ramcfg_index(vb0.rom, raw.pop()))
    except Exception: stat['VBIOS не разобран'] += 1; continue
    lv = {}
    for l, f in vb.mem.items():
        try: T, R, M = vb.tables(f)
        except ValueError: continue
        lv[T[9] << 24 | T[7] << 17 | T[5] << 8 | T[3]] = (l, f, bytes(T), bytes(R), bytes(M))
    for s in d['scripts']:
        w = [(a[i], a[i + 1]) for op, a in s['ops'] if op == 0x21 for i in range(0, len(a), 2)]
        t290 = [v for r, v in w if r == 0x10f290]
        if not t290: continue
        tgt = lv.get(t290[-1])
        if not tgt: stat['уровень не найден по 0x10f290'] += 1; continue
        stat['скрипт с найденным уровнем'] += 1
        l, f, T, R, M = tgt
        for reg, fl in FIELDS.items():
            vs = [v for r, v in w if r == reg]
            if not vs: continue
            for which, v in (('посл', vs[-1]), ('перв', vs[0])):
                for sh, wd in fl:
                    obs[(reg, sh, wd, which)].append((d['chip'], lab, (v >> sh) & ((1 << wd) - 1), M, R, T, f))
def feats(M, R, T, f):
    o = {f'f>={t}': int(f >= t) for t in (200, 300, 400, 500, 600, 700, 800, 1000, 1500)}
    for nm, bb in (('M', M), ('R', R), ('T', T)):
        for i, b in enumerate(bb):
            o[f'{nm}{i:02x}'] = b; o[f'{nm}{i:02x}.lo'] = b & 15; o[f'{nm}{i:02x}.hi'] = b >> 4
            for k in range(8): o[f'{nm}{i:02x}.b{k}'] = (b >> k) & 1
            for k in range(7): o[f'{nm}{i:02x}.b{k}{k + 1}'] = (b >> k) & 3
    return o
def search(rows):
    F = [feats(M, R, T, f) for _, _, _, M, R, T, f in rows]
    names = set.intersection(*[set(x) for x in F]); good = []
    for n in sorted(names):
        m = {}; ok = True
        for (_, _, v, *_), x in zip(rows, F):
            if m.setdefault(x[n], v) != v: ok = False; break
        if ok and len(set(m.values())) > 1 and not (n[0] == 'M' and n[1:3] in ('00', '01', '02', '03')): good.append((n, m))   # M00–M03 — границы частот записи, не поле
    good.sort(key=lambda g: (0 if g[0].startswith('f>=') else (1 if g[0][0] in 'RT' else 2), len(g[1])))   # частота, потом ramcfg/тайминги, потом rammap
    return good
print('Скрипты:', dict(stat), '\n')
print('| поле | значений | наблюдений (плат) | одно правило на все платы | по чипам |'); print('|---|---|---|---|---|')
for k in sorted(obs):
    rows = obs[k]; vals = sorted({v for _, _, v, *_ in rows})
    if len(vals) < 2: continue
    reg, sh, wd, which = k
    g = search(rows); boards = len({t for _, t, *_ in rows})
    allr = '; '.join(f"{n} → {dict(sorted(m.items()))}" for n, m in g[:2]) or '—'
    per = []
    for ch in sorted({c for c, *_ in rows}):
        rr = [x for x in rows if x[0] == ch]
        if len({x[2] for x in rr}) < 2: per.append(f'{ch}: всегда {rr[0][2]}'); continue
        gg = search(rr); per.append(f"{ch}: {gg[0][0] if gg else '—'}")
    print(f'| {reg:06x} биты {sh}+{wd} ({which}) | {vals} | {len(rows)} ({boards}) | {allr} | {"; ".join(per)} |')
