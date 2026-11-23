#!/usr/bin/env python3
# «БАЗА ДРАЙВЕРА» (23.11): регистры, которые скрипты памяти Fermi пишут полным словом, но значение которых в VBIOS нет
# (драйвер NVIDIA ставит их при загрузке). Вопрос: скрипт пишет «текущее значение + управляющие биты шага» или новое число?
# Проход по трассам Fermi: вся история каждого регистра — чтения и записи хоста (значение известно) и записи внутри
# скриптов памяти (в момент загрузки скрипта). Для каждой записи в скрипте — разность с предыдущим известным значением.
# Итог по регистру: какие биты меняют скрипты (управление шага), какие различаются между платами (база платы), есть ли
# записи, которые не сводятся к «прежнее значение ^ биты управления». Только чтение; участники обезличены.
#   python3 -I lab/db-mem-base.py [ОПИСЬ_КАТАЛОГ] [БАЗА]
import sys, os, json, subprocess, collections
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser('~/Home/nouveau-archive/mem-survey')
DB = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser('~/Home/nouveau-archive/nouveau_vbios_trace')
inv = json.load(open(os.path.join(OUT, 'inventory.json'))); key = json.load(open(os.path.join(OUT, 'inventory-key.json')))
T = json.load(open(os.path.join(OUT, 'types.json')))
REGS = [0x10f808, 0x10f604, 0x10f610, 0x10f614, 0x10f830, 0x10f824, 0x10f800, 0x10f828, 0x10f340, 0x10f200, 0x10f090,
        0x100c00, 0x100b0c, 0x00e108, 0x00e280, 0x1373f8, 0x1373ec, 0x10fe20, 0x10fe24, 0x10f2a0, 0x10f29c]
RS = set(REGS)
def opener(rel):
    f, _, mem = rel.partition(':'); p = os.path.join(DB, f)
    with open(p, 'rb') as h: m = h.read(6)
    if not mem: return ['xz', '-dc', p] if m.startswith(b'\xfd7zXZ') else ['cat', p]
    if m.startswith(b'\xfd7zXZ'): return ['tar', '-xOJf', p, mem]
    if m.startswith(b'BZh'): return ['tar', '-xOjf', p, mem]
    return ['sh', '-c', 'tar -xOzf "$0" "$1" | (xz -dc 2>/dev/null || cat)', p, mem]
def parse(w):
    i, ops = 0, []
    while i < len(w):
        ln, op = w[i] >> 16, w[i] & 0xffff
        if ln == 0 or i + ln > len(w) + 1 or op > 0xff: return None
        a = w[i + 1:i + ln]
        if op == 0x21:
            if len(a) % 2: return None
            ops += [(a[k], a[k + 1]) for k in range(0, len(a), 2)]
        if op == 0x16: return ops
        i += ln
    return None

ctrl = collections.defaultdict(int)                 # биты, которые меняются записями внутри скриптов
first = collections.defaultdict(dict)               # первое известное значение регистра на трассе (база платы)
nscr = collections.Counter(); nhost = collections.Counter(); unknown_prev = collections.Counter()
per_chip_ctrl = collections.defaultdict(lambda: collections.defaultdict(int))
for lab, r in sorted(inv.items()):
    if r['gen'] != 'Fermi' or not r['bar0'] or not r['pmu_scripts']: continue
    bar0 = int(r['bar0'], 16); state = {}; cur = None
    pr = subprocess.Popen(opener(key[lab]), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    def flush():
        ops = parse(cur) if cur else None
        if not ops or not any(0x10f000 <= a < 0x130000 or 0x132000 <= a < 0x133000 for a, _ in ops): return
        for a, v in ops:
            if a not in RS: continue
            nscr[a] += 1
            if a in state:
                d = state[a] ^ v; ctrl[a] |= d; per_chip_ctrl[r['chip']][a] |= d
            else: unknown_prev[a] += 1
            state[a] = v
            first[a].setdefault(lab, v)
    for raw in pr.stdout:
        if raw[:2] not in (b'W ', b'R '): continue
        p = raw.split()
        if len(p) < 6: continue
        try: a = int(p[4], 16) - bar0; v = int(p[5], 16)
        except ValueError: continue
        if raw[0] == 87 and a == 0x10a1c4 and cur is not None: cur.append(v); continue
        if raw[0] == 87 and cur is not None: flush(); cur = None
        if raw[0] == 87 and a == 0x10a1c0: cur = []; continue
        if a in RS:
            if a not in state: first[a].setdefault(lab, v)
            state[a] = v; nhost[a] += 1
    pr.stdout.close(); pr.wait()
    print(f'{lab:9} {T.get(lab, {}).get("type", "?"):5} готово', file=sys.stderr, flush=True)

json.dump(dict(first={f'{a:06x}': d for a, d in first.items()}, ctrl={f'{a:06x}': m for a, m in ctrl.items()},
               ctrl_chip={c: {f'{a:06x}': m for a, m in d.items()} for c, d in per_chip_ctrl.items()}),
          open(os.path.join(OUT, 'base.json'), 'w'), indent=0)
print('| регистр | записей в скриптах | без известного «до» | записей/чтений хоста | биты, которые меняют скрипты | биты, где платы различаются в базе | разных баз |')
print('|---|---|---|---|---|---|---|')
for a in REGS:
    vals = list(first[a].values())
    if not vals: continue
    an = 0xffffffff; o = 0
    for v in vals: an &= v; o |= v
    print(f'| {a:06x} | {nscr[a]} | {unknown_prev[a]} | {nhost[a]} | {ctrl[a]:08x} | {an ^ o:08x} | {len(set(vals))} |')
print('\nБиты управления по чипам (что меняют скрипты на этом чипе):\n')
chips = sorted(per_chip_ctrl)
print('| регистр | ' + ' | '.join(chips) + ' |'); print('|---' * (len(chips) + 1) + '|')
for a in REGS:
    if not any(a in per_chip_ctrl[c] for c in chips): continue
    print(f'| {a:06x} | ' + ' | '.join(f'{per_chip_ctrl[c][a]:08x}' if a in per_chip_ctrl[c] else '·' for c in chips) + ' |')
