#!/usr/bin/env python3
# ПРОВЕРКА ГЕНЕРАТОРА GDDR5 (lab/memgen2.py) НА ВСЕХ ТРАССАХ FERMI GDDR5 БАЗЫ (23.11). Для каждой трассы с образом VBIOS:
# ремешок из трассы -> индекс ramcfg (M0203) -> скрипты A–E генератора по VBIOS этой платы -> сверка с каждым уникальным
# скриптом памяти этой трассы (выравнивание последовательностей регистров, как lab/memgen2-compare.py). Итог по чипу:
# сходство скелета, доля совпавших значений на общих регистрах, и какие метки источника (Ф формула, П база платы, Ч
# константа чипа, PLL, …) расходятся чаще всего. Только чтение; участники обезличены.
#   python3 -I lab/db-memgen-check.py ЛАБ/ramgf100.c ЧИСТЫЙ/ramgf100.c [ОПИСЬ_КАТАЛОГ] [БАЗА] [--detail ЧИП]
import sys, os, json, collections, difflib, importlib.util
HERE = os.path.dirname(os.path.abspath(__file__))
def load(name):
    sp = importlib.util.spec_from_file_location(name.replace('-', '_'), os.path.join(HERE, name + '.py')); m = importlib.util.module_from_spec(sp)
    sp.loader.exec_module(m); return m
mg = load('memgen2'); steps = load('db-mem-steps')
args = [a for a in sys.argv[1:] if not a.startswith('--')]
detail = next((sys.argv[i + 1] for i, a in enumerate(sys.argv) if a == '--detail'), None)
if detail: args.remove(detail)
lab_c, nv_c = args[0], args[1]
OUT = args[2] if len(args) > 2 else os.path.expanduser('~/Home/nouveau-archive/mem-survey')
DB = args[3] if len(args) > 3 else os.path.expanduser('~/Home/nouveau-archive/nouveau_vbios_trace')
S = json.load(open(os.path.join(OUT, 'scripts.json'))); key = json.load(open(os.path.join(OUT, 'inventory-key.json')))
inv = json.load(open(os.path.join(OUT, 'inventory.json')))
BASE = json.load(open(os.path.join(OUT, 'base.json'))) if os.path.exists(os.path.join(OUT, 'base.json')) else {}
TOPO = json.load(open(os.path.join(OUT, 'topo.json'))) if os.path.exists(os.path.join(OUT, 'topo.json')) else {}
arrs, nv = mg.load_arrays(lab_c), mg.load_nv(nv_c)
skel = mg.classify(mg.Vbios(os.path.expanduser('~/Home/nouveau-archive/vbios.rom'), 3), arrs, nv)

def roms(lab):
    d = os.path.dirname(os.path.join(DB, key[lab].split(':')[0]))
    return [os.path.join(d, x) for x in sorted(os.listdir(d)) if not x.endswith('.eml') and (x.lower().endswith(('.rom', '.bin')) or 'vbios' in x.lower())]
def wrs_trace(ops):
    out = []
    for op, a in ops:
        if op == 0x21: out += [('WR', a[i], a[i + 1]) for i in range(0, len(a), 2)]
    return out

per_chip = collections.defaultdict(collections.Counter); diff_tags = collections.defaultdict(collections.Counter)
diff_regs = collections.defaultdict(collections.Counter); only_his = collections.defaultdict(collections.Counter)
only_ours = collections.defaultdict(collections.Counter); rows = []
for lab, d in sorted(S.items()):
    if d['gen'] != 'Fermi' or d['type'] != 'GDDR5' or not d['scripts']: continue
    rs = roms(lab)
    if len(rs) != 1: per_chip[d['chip']]['трасс без однозначного образа'] += 1; continue
    raw = {(int(s, 16) >> 2) & 0xf for s in inv[lab]['strap']}
    if len(raw) != 1: per_chip[d['chip']]['трасс с неясным ремешком'] += 1; continue
    try:
        vb0 = mg.Vbios(rs[0], 0); idx = mg.ramcfg_index(vb0.rom, raw.pop()); vb = mg.Vbios(rs[0], idx); vb.active = TOPO.get(lab, {}).get('active')
        if BASE and '--no-base' not in sys.argv:
            vb.base_ctrl = {int(a, 16): m for a, m in BASE['ctrl_chip'].get(d['chip'], {}).items()}
            vb.base_now = {int(a, 16): v[lab] for a, v in BASE['first'].items() if lab in v}
        gen, notes = mg.generate(vb, skel)
    except Exception as e:
        per_chip[d['chip']]['генератор не собрал: ' + type(e).__name__] += 1; continue
    G = {k: [o for o in (g or []) if o[0] == 'WR'] for k, g in gen.items()}
    if not any(G.values()): per_chip[d['chip']]['скрипты не собраны'] += 1; continue
    tagsG = {k: [it.get('tag') for it, o in zip(skel[k], gen[k] or []) if o[0] == 'WR'] for k in gen}
    c = per_chip[d['chip']]; c['трасс'] += 1; seen = set()
    for s in d['scripts']:
        rw = wrs_trace(s['ops']); sig = tuple(r for _, r, _ in rw)
        if sig in seen: continue
        seen.add(sig); c['уникальных скриптов'] += 1
        best = max(((difflib.SequenceMatcher(None, [x[1] for x in rw], [x[1] for x in g]).ratio(), k) for k, g in G.items() if g), default=None)
        if not best: continue
        ratio, k = best; gw = G[k]; tg = tagsG[k]
        sm = difflib.SequenceMatcher(None, [x[1] for x in rw], [x[1] for x in gw])
        for tag, i1, i2, j1, j2 in sm.get_opcodes():
            if tag == 'equal':
                for a, b in zip(range(i1, i2), range(j1, j2)):
                    c['общих'] += 1
                    if rw[a][2] == gw[b][2]: c['совпали'] += 1
                    else: c['разошлись'] += 1; diff_tags[d['chip']][tg[b] or '?'] += 1; diff_regs[d['chip']][rw[a][1]] += 1
            if tag in ('delete', 'replace'):
                c['только у NVIDIA'] += i2 - i1
                for a in range(i1, i2): only_his[d['chip']][rw[a][1]] += 1
            if tag in ('insert', 'replace'):
                c['только у генератора'] += j2 - j1
                for b in range(j1, j2): only_ours[d['chip']][gw[b][1]] += 1
        c['сходство×100'] += int(ratio * 100)

print('| чип | трасс | уник. скриптов | сходство скелета | общих | совпало значений | только у NVIDIA | только у генератора |')
print('|---|---|---|---|---|---|---|---|')
for ch, c in sorted(per_chip.items()):
    n = max(1, c['уникальных скриптов']); g = max(1, c['общих'])
    print(f"| {ch} | {c['трасс']} | {c['уникальных скриптов']} | {c['сходство×100'] / n:.0f} % | {c['общих']} | {100 * c['совпали'] / g:.0f} % | {c['только у NVIDIA']} | {c['только у генератора']} |")
    extra = {k: v for k, v in c.items() if k.startswith(('трасс ', 'генератор', 'скрипты не'))}
    if extra: print(f'|  ↳ {ch} | {extra} | | | | | | |')
print('\nРасхождения значений по метке источника (Ф формула, Фк формула-кандидат, П база платы, Ч/Ч1 константа чипа, PLL, Н число):\n')
for ch in sorted(diff_tags): print(f"- {ch}: {dict(diff_tags[ch].most_common())}; чаще всего регистры: {', '.join(f'{r:06x}×{n}' for r, n in diff_regs[ch].most_common(8))}")
print('\nТолько у NVIDIA (нет в нашем скелете), частые:\n')
for ch in sorted(only_his): print(f"- {ch}: {', '.join(f'{r:06x}×{n}' for r, n in only_his[ch].most_common(10))}")
print('\nТолько у генератора (есть в нашем скелете, NVIDIA на этом чипе не пишет), частые:\n')
for ch in sorted(only_ours): print(f"- {ch}: {', '.join(f'{r:06x}×{n}' for r, n in only_ours[ch].most_common(10))}")

print('\nПо шагам словаря (docs/2026-11-23/mem-meaning.md): разошлось значений / только у NVIDIA / только у генератора\n')
print('| шаг | ' + ' | '.join(sorted(per_chip)) + ' |'); print('|---' * (len(per_chip) + 1) + '|')
agg = collections.defaultdict(lambda: collections.defaultdict(lambda: [0, 0, 0]))
for ch in per_chip:
    for r, n in diff_regs[ch].items(): agg[steps.step(r, 0)][ch][0] += n
    for r, n in only_his[ch].items(): agg[steps.step(r, 0)][ch][1] += n
    for r, n in only_ours[ch].items(): agg[steps.step(r, 0)][ch][2] += n
for st in sorted(agg, key=lambda st: -sum(sum(v) for v in agg[st].values())):
    print(f'| {st} | ' + ' | '.join('/'.join(str(x) for x in agg[st][ch]) if ch in agg[st] else '·' for ch in sorted(per_chip)) + ' |')
