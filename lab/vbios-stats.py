#!/usr/bin/env python3
# Сводка по survey.json (из lab/vbios-survey.py): смысл флагов частот (биты 14–15) и байтов записи уровня, тайминги и ramcfg.
#   python3 -I lab/vbios-stats.py КАТАЛОГ_С_survey.json
import sys, os, json, collections

d = json.load(open(os.path.join(sys.argv[1], 'survey.json')))
ok = [r for r in d if r.get('perf', {}).get('levels')]
print(f'образов: {len(d)}, с таблицей уровней 0x40: {len(ok)}')
dev = collections.Counter(r.get('pci') for r in d)
print('устройства PCI (первые 25):', ', '.join(f'{k}×{v}' for k, v in dev.most_common(25)))


def grid(f):
    """Достаётся ли частота делителем от 1620 (поле f: 3240/(f+2)), в пределах ±0,5 МГц (таблица хранит целые МГц)."""
    return any(abs(3240 / k - f) <= 0.5 for k in range(2, 130))


# 1. флаг частоты против «на сетке делителя» по узлам и уровням
print('\n== 1. Флаг (биты 14–15) частоты узла: на сетке 1620/n или нет, по уровням')
tab = collections.Counter()
for r in ok:
    for l in r['perf']['levels']:
        for dom, (f, fl) in l['dom'].items():
            tab[(dom, l['id'], 'сетка' if grid(f) else 'вне', fl)] += 1
doms = sorted({k[0] for k in tab})
for dom in doms:
    line = []
    for lv in ('03', '07', '0a', '0f'):
        for g in ('сетка', 'вне'):
            c = {fl: tab[(dom, lv, g, fl)] for fl in range(4) if tab[(dom, lv, g, fl)]}
            if c:
                line.append(f'{lv}/{g}: ' + ' '.join(f'ф{fl}×{n}' for fl, n in sorted(c.items())))
    print(f'  {dom:7s} ' + ' | '.join(line))

# 2. байты записи уровня
print('\n== 2. Байты записи уровня (1, 2, 0x0b, 0x0c) по уровням')
for pos in (1, 2, 0x0b, 0x0c):
    c = collections.Counter()
    for r in ok:
        for l in r['perf']['levels']:
            raw = bytes.fromhex(l['raw'])
            if len(raw) > pos:
                c[(l['id'], raw[pos])] += 1
    print(f'  байт {pos:#04x}: ' + ', '.join(f'{lv}:{v:02x}×{n}' for (lv, v), n in sorted(c.items())))

# 3. связь: байт 1 = 0x40 <-> все флаги узлов != 1 ?
print('\n== 3. Байт 1 записи уровня против флагов узлов уровня')
c = collections.Counter()
for r in ok:
    for l in r['perf']['levels']:
        raw = bytes.fromhex(l['raw'])
        fls = ''.join(sorted({str(fl) for f, fl in l['dom'].values()}))
        c[(f'{raw[1]:02x}', fls)] += 1
for (b1, fls), n in sorted(c.items()):
    print(f'  байт1={b1} флаги уровня {{{fls}}}: {n}')

# 4. тайминги и ramcfg: разброс значений по полям для каждой записи rammap (частотного окна)
print('\n== 4. Тайминги v0x10: разброс по полям (по всем непустым записям)')
names = {0: 'WR', 1: 'WTR', 2: 'CL', 3: 'RC', 5: 'RFC', 7: 'RAS', 9: 'RP', 10: 'RCDRD', 11: 'RCDWR', 12: 'RRD', 13: 't13', 14: 'ODT', 16: 't16', 18: 't18', 19: 'CWL', 20: 't20', 21: 't21', 22: 't22', 24: 't24'}
fv = collections.defaultdict(collections.Counter)
for r in d:
    for e in r.get('timing', {}).get('entries', []):
        b = bytes.fromhex(e)
        if any(b):
            for k in range(len(b)):
                fv[k][b[k]] += 1
for k in sorted(fv):
    vals = fv[k]
    print(f'  байт {k:2d} {names.get(k, ""):6s}: различных {len(vals):3d}; частые: ' + ' '.join(f'{v:02x}×{n}' for v, n in vals.most_common(8)))
