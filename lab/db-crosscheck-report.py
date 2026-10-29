#!/usr/bin/env python3
# Отчёт по сверке модели с трассами других карт Fermi (вход — JSON lab/db-crosscheck.py). Для каждого регистра модели:
# набор значений, которые NVIDIA пишет у нас (наша трасса 390), и по чипам на чужих трассах; вердикт для «констант»
# (семейство/чип/драйвер/неизвестно): одинаково везде / одинаково внутри чипа / меняется от платы / на других не пишется.
#   python3 -I lab/db-crosscheck-report.py СВЕРКА.json [--detail]
import sys, json, collections, os
KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
J = json.load(open(sys.argv[1])); detail = '--detail' in sys.argv
NAMES = {'nvc0': 'GF100', 'nvc1': 'GF108', 'nvc3': 'GF106', 'nvc4': 'GF104', 'nvc8': 'GF110', 'nvce': 'GF114', 'nvcf': 'GF116',
         'nvd7': 'GF117', 'nvd9': 'GF119'}
reg = {}
for l in open(os.path.join(KIT, 'docs/model/registers.tsv'), encoding='utf-8'):
    if l.startswith('#') or not l.strip(): continue
    c = l.rstrip('\n').split('\t'); reg[c[0][2:].lower().zfill(6)] = dict(name=c[1], what=c[2], why=c[3], src=c[4], val=c[6])
OURS = 'наша-gf114-390-t1'
def vals(t, r):
    d = J[t]; s = set(d['host'].get(r, {})) | set(d['pmu'].get(r, {}))
    return s
traces = [t for t in J if t != OURS and (J[t]['host'] or J[t]['pmu'])]
rows = []; verdicts = collections.Counter(); byclass = collections.defaultdict(collections.Counter)
for r, info in sorted(reg.items()):
    if info['what'] == 'вне': continue
    ours = vals(OURS, r)
    per = collections.defaultdict(list)
    for t in traces:
        v = vals(t, r)
        if v: per[J[t]['chip']].append(frozenset(v))
    nchips = len(per); ntr = sum(len(x) for x in per.values())
    # сравнение по «все значения трассы входят в наши» (трассы снимают разные сценарии и уровни, поэтому равенство наборов
    # слишком строго): у нас набор значений по всем переходам 390; чужая трасса «как у нас», если её значения ⊆ наших
    O = frozenset(ours)
    sub = lambda st: bool(O) and st <= O
    if not ntr: verd = 'на других не пишется'
    elif not O: verd = 'у нас не пишется'
    else:
        gf114 = per.get('nvce', []); others = [st for c, x in per.items() if c != 'nvce' for st in x]
        if all(sub(st) for st in gf114 + others): verd = 'как у нас на всех чипах'
        elif all(sub(st) for st in gf114) and gf114: verd = 'как у нас на GF114, иначе на других чипах'
        elif all(sub(st) for st in others) and others: verd = 'как у нас на других чипах, но иначе на других GF114'
        else: verd = 'иначе и на других GF114 (плата/версия/уровень)'
    verdicts[verd] += 1; byclass[info['val']][verd] += 1
    rows.append((r, info, ours, per, verd, nchips, ntr))
print(f'трасс других карт с записями модели: {len(traces)}; регистров модели (без служебных): {len(rows)}')
print('\n## Вердикты по всем регистрам'); [print(f'  {v}: {c}') for v, c in verdicts.most_common()]
print('\n## По классу «откуда значение» (registers.tsv) → вердикт по чужим трассам')
for k, cnt in sorted(byclass.items(), key=lambda x: -sum(x[1].values())):
    print(f'  {k} ({sum(cnt.values())}): ' + '; '.join(f'{v} {c}' for v, c in cnt.most_common()))
if detail:
    print('\n## Подробно (регистр, имя, класс, вердикт; значения по чипам)')
    for r, info, ours, per, verd, nchips, ntr in rows:
        o = ','.join(sorted(ours))[:60] or '—'
        chips = '; '.join(f"{NAMES.get(c, c)}×{len(x)}: {','.join(sorted(set().union(*x)))[:50]}" for c, x in sorted(per.items()))
        print(f"  {r} {info['name'][:28]:28} [{info['val']}] {verd} | наше {o} | {chips[:200]}")
