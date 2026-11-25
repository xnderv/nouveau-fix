#!/usr/bin/env python3
# DDR3 ПО ПОКОЛЕНИЯМ: скрипты подъёма памяти в записях NVIDIA от GT21x до Maxwell — что в них общего и как менялись
# ожидания. Для каждой записи DDR3 (обзор lab/db-mem-*.py: scripts.json, types.json) берётся скрипт с наибольшей задержкой
# чтения в MR0 (подъём на верхнюю частоту) и печатается: сколько записей, сбросы DLL, ожидание от последнего сброса DLL до
# возврата доступа, строб 0x13d8x4 и ожидания после него, паузы по местам. Только чтение. Метки «чип#номер», пути не печатаются.
#   python3 -I lab/db-ddr3-vertical.py [КАТАЛОГ_ОБЗОРА] [--profile МЕТКА ...] [--extra МЕТКА=СКРИПТЫ.json ...]
# --extra: записи тестировщиков вне базы (JSON от lab/trace-memscr.py).
import sys, os, json, collections
args = sys.argv[1:]
prof = []; extra = {}
while '--profile' in args:
    i = args.index('--profile'); prof.append(args[i + 1]); del args[i:i + 2]
while '--extra' in args:
    i = args.index('--extra'); k, v = args[i + 1].split('=', 1); extra[k] = v; del args[i:i + 2]
OUT = args[0] if args else os.path.expanduser('~/Home/nouveau-archive/mem-survey')
S = json.load(open(os.path.join(OUT, 'scripts.json')))

CL = {2: 5, 4: 6, 6: 7, 8: 8, 10: 9, 12: 10, 14: 11, 1: 12, 3: 13, 5: 14}      # код A6 A5 A4 A2 -> тактов


def words_to_ops(w):
    out = []; i = 0
    while i < len(w):
        h = w[i]; n = h >> 16
        if n == 0: break
        out.append([h & 0xffff, w[i + 1:i + n]]); i += n
    return out


def mr0_reg(gen): return 0x1002c0 if gen == 'Tesla2' else 0x10f300


def analyse(ops, gen):
    """признаки одного скрипта"""
    mr0 = mr0_reg(gen); wr = 0; dllr = 0; cl = None; strobe = 0; swaits = []; unit = None
    waits = []; last = None; since_dll = None; dll_to_resume = None; refresh_off_at = None
    for op, a in ops:
        if op == 0x21:
            for r, v in zip(a[0::2], a[1::2]):
                wr += 1; last = (r, v)
                if r == mr0:
                    if v & 0x100: dllr += 1; since_dll = 0
                    c = ((v >> 3) & 0xe) | ((v >> 2) & 1); cl = CL.get(c, cl)
                if (r & 0xfff80f) == 0x13d804 and v == 0: strobe += 1
        elif op in (0x2e, 0x13):
            ns = a[0]; waits.append((ns, last))
            if since_dll is not None: since_dll += ns
            if op == 0x13 and last and (last[0] & 0xfff80f) == 0x13d804: swaits.append(ns)
        elif op == 0x39: unit = a[0]
        elif op == 0x3a:
            swaits.append((a[0], unit))
            if since_dll is not None and unit: since_dll += a[0] * unit
        elif op == 0x20 and a and a[0] == 0:
            if since_dll is not None and dll_to_resume is None: dll_to_resume = since_dll
        elif op == 0x16: break
    return dict(wr=wr, dllr=dllr, cl=cl, strobe=strobe, swaits=swaits, waits=waits, dll_to_resume=dll_to_resume)


def name(gen, r):
    t2 = {0x1002d0: 'REFRESH', 0x1002d4: 'PRECHARGE', 0x100210: 'автообновление', 0x1002dc: 'самообновление?', 0x1002c0: 'MR0', 0x1002c4: 'MR1',
          0x1002e0: 'MR2', 0x100264: 'ZQ?', 0x100700: 'сброс тракта', 0x004000: 'PLL', 0x004018: 'PLL', 0x611200: 'дисплей'}
    f = {0x10f310: 'REFRESH', 0x10f314: 'PRECHARGE', 0x10f210: 'автообновление', 0x10f300: 'MR0', 0x10f304: 'MR1', 0x10f320: 'MR2', 0x10f330: 'MR1',
         0x10f334: 'MR2', 0x10f090: 'интерфейс', 0x10f830: 'сброс тракта', 0x10f808: 'режим контроллера', 0x10f824: 'режим линий',
         0x10f200: 'контроллер', 0x10f318: 'NOP?', 0x611200: 'дисплей', 0x62c000: 'дисплей', 0x10f870: 'линии', 0x132040: 'PLL', 0x1373f4: 'источник такта'}
    if (r & 0xfff80f) == 0x13d804: return 'строб'
    return (t2 if gen == 'Tesla2' else f).get(r, '%06x' % r)


rows = []
items = [(lab, d['chip'], d['gen'], d['type'], [s['ops'] for s in d['scripts']]) for lab, d in S.items()]
for lab, path in extra.items():
    J = json.load(open(path)); items.append((lab, 'nvc1', 'Fermi', 'DDR3', [words_to_ops(s['words']) for s in J]))
for lab, chip, gen, typ, scripts in items:
    if typ != 'DDR3': continue
    best = None
    for ops in scripts:
        a = analyse(ops, gen)
        if a['cl'] is None or a['wr'] < 25: continue
        if best is None or (a['cl'], a['wr']) > (best['cl'], best['wr']): best = a
    if best: rows.append((gen, chip, lab, len(scripts), best))
G = {'Tesla2': 0, 'Fermi': 1, 'Kepler': 2, 'Maxwell': 3}
rows.sort(key=lambda r: (G.get(r[0], 9), r[1], r[2]))
print('| поколение | запись | скриптов | записей в подъёме | CL | сбросов DLL | от последнего сброса DLL до возврата доступа, нс | строб, раз | ожидания после строба | пауз всего, сумма нс |')
print('|---|---|---|---|---|---|---|---|---|---|')
for gen, chip, lab, n, a in rows:
    sw = a['swaits']
    if sw and isinstance(sw[0], tuple): swt = 'оп 0x3a: ' + ' '.join(str(x[0]) for x in sw) + (f' × {sw[0][1]} нс' if sw[0][1] else ' × единица по умолчанию')
    elif sw: swt = 'оп 0x13: ' + ' '.join(str(x) for x in sw) + ' нс'
    else: swt = '—'
    print(f'| {gen} | {lab} | {n} | {a["wr"]} | {a["cl"]} | {a["dllr"]} | {a["dll_to_resume"] if a["dll_to_resume"] is not None else "—"} | {a["strobe"]} | {swt} | {len(a["waits"])}, {sum(w[0] for w in a["waits"])} |')
for lab in prof:
    r = next((x for x in rows if x[2] == lab), None)
    if not r: print(f'\n{lab}: нет'); continue
    gen, chip, _, n, a = r
    print(f'\n### {lab} ({gen}): паузы скрипта подъёма по местам (после какой записи стоит пауза)')
    print(', '.join(f'{name(gen, w[1][0]) if w[1] else "начало"} → {w[0]} нс' for w in a['waits']))
