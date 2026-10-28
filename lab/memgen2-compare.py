#!/usr/bin/env python3
# Сверка собранных скриптов (memgen2 --emit) со скриптами из чужой записи (trace-memscr.py): по выравниванию последовательностей
# регистров — сколько значений совпало, сколько разошлось (по меткам источника), что есть только у одной стороны.
#   python3 -I lab/memgen2-compare.py СОБРАННЫЕ.json ИЗ_ЗАПИСИ.json [--detail]
import sys, json, difflib, collections
G = json.load(open(sys.argv[1])); R = json.load(open(sys.argv[2])); detail = '--detail' in sys.argv
wrs = lambda ops: [o for o in ops if o[0] == 'WR']
seen = set(); tot = collections.Counter()
for s in R:
    rw = wrs(s['ops']); key = (len(rw), tuple(s['regs'][:3]))
    if key in seen: continue
    seen.add(key); best = None
    for k, g in G.items():
        if not g['ops']: continue
        ratio = difflib.SequenceMatcher(None, [o[1] for o in rw], [o[1] for o in wrs(g['ops'])]).ratio()
        if best is None or ratio > best[0]: best = (ratio, k)
    ratio, k = best; g = G[k]; gw = wrs(g['ops']); tags = [t for t, o in zip(g['tags'], g['ops']) if o[0] == 'WR']
    sm = difflib.SequenceMatcher(None, [o[1] for o in rw], [o[1] for o in gw])
    eq = 0; d = []; oh = []; oo = []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == 'equal':
            for a, b in zip(range(i1, i2), range(j1, j2)):
                if rw[a][2] == gw[b][2]: eq += 1
                else: d.append((rw[a][1], rw[a][2], gw[b][2], tags[b]))
        if tag in ('delete', 'replace'): oh += [rw[a][1] for a in range(i1, i2)]
        if tag in ('insert', 'replace'): oo += [(gw[b][1], tags[b]) for b in range(j1, j2)]
    dt = collections.Counter(t for *_, t in d)
    print(f"его {len(rw)} зап. (t={s['t']:.1f}) ~ наш {k} ({len(gw)}), сходство {ratio:.2f}: общих {eq + len(d)}, совпали {eq}, разошлись {len(d)} {dict(dt)}; только у него {len(oh)}, только у нас {len(oo)}")
    tot['общих'] += eq + len(d); tot['совпали'] += eq; tot['разошлись'] += len(d); tot['только у него'] += len(oh); tot['только у нас'] += len(oo)
    if detail:
        print('   разошлись:', ', '.join(f'{r:06x} {hv:08x}→{gv:08x}[{t}]' for r, hv, gv, t in d))
        print('   только у него:', ' '.join(f'{r:06x}' for r in oh)); print('   только у нас:', ' '.join(f'{r:06x}[{t}]' for r, t in oo))
print('итого по уникальным скриптам:', dict(tot), f"совпало {100 * tot['совпали'] / max(1, tot['общих']):.0f} % общих регистров")
