#!/usr/bin/env python3
# ТОПОЛОГИЯ ПАМЯТИ по трассам базы, все поколения (23.11): первые чтения 0x022438 (разделов FBP), 0x02243c (контроллеров
# FBPA), 0x022554 (маска выключенных), 0x17e8dc[31:28] (подразделов L2 на раздел) — те же регистры, что читает nouveau
# (fb/ramgf100.c, ramgf108.c, ltc/gf100.c, gm107.c). Плюс по скриптам памяти: адрес 0x13d8x4 и номера разделов в записях
# 0x110000+0x1000·i. Выход: topo.json в частном каталоге описи и таблица. Только чтение.
#   python3 -I lab/db-mem-topo.py [ОПИСЬ_КАТАЛОГ] [БАЗА]
import sys, os, json, subprocess, collections
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser('~/Home/nouveau-archive/mem-survey')
DB = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser('~/Home/nouveau-archive/nouveau_vbios_trace')
inv = json.load(open(os.path.join(OUT, 'inventory.json'))); key = json.load(open(os.path.join(OUT, 'inventory-key.json')))
S = json.load(open(os.path.join(OUT, 'scripts.json'))); T = json.load(open(os.path.join(OUT, 'types.json')))
REGS = (0x022438, 0x02243c, 0x022554, 0x17e8dc)
def opener(rel):
    f, _, mem = rel.partition(':'); p = os.path.join(DB, f)
    with open(p, 'rb') as h: m = h.read(6)
    if not mem: return ['xz', '-dc', p] if m.startswith(b'\xfd7zXZ') else ['cat', p]
    if m.startswith(b'\xfd7zXZ'): return ['tar', '-xOJf', p, mem]
    if m.startswith(b'BZh'): return ['tar', '-xOjf', p, mem]
    return ['sh', '-c', 'tar -xOzf "$0" "$1" | (xz -dc 2>/dev/null || cat)', p, mem]
res = {}
for lab, r in inv.items():
    if r['gen'] not in ('Fermi', 'Kepler', 'Maxwell', 'Pascal') or not r['bar0']: continue
    bar0 = int(r['bar0'], 16); got = {}
    pr = subprocess.Popen(opener(key[lab]), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    for raw in pr.stdout:
        if raw[:2] != b'R ': continue
        p = raw.split()
        try: a = int(p[4], 16) - bar0
        except ValueError: continue
        if a in REGS and a not in got:
            got[a] = int(p[5], 16)
            if len(got) == len(REGS): break
    pr.kill(); pr.wait()
    fbp, fbpa, mask, l2 = (got.get(x) for x in REGS)
    act = None if fbp is None or mask is None or fbp > 32 else fbp - bin(mask & ((1 << fbp) - 1)).count('1')
    parts = set(); addr = set()
    for s in S.get(lab, {}).get('scripts', []):
        for op, a in s['ops']:
            if op == 0x21:
                for i in range(0, len(a), 2):
                    if 0x110000 <= a[i] < 0x130000: parts.add((a[i] - 0x110000) >> 12)
                    if 0x13d800 <= a[i] < 0x13da00: addr.add(a[i])
    res[lab] = dict(chip=r['chip'], gen=r['gen'], type=T.get(lab, {}).get('type', '?'), fbp=fbp, fbpa=fbpa, mask=mask,
                    slices=None if l2 is None else l2 >> 28, active=act, parts=sorted(parts), addr=sorted(addr))
json.dump(res, open(os.path.join(OUT, 'topo.json'), 'w'), indent=0)
c = collections.Counter()
for v in res.values():
    c[(v['gen'], v['chip'], v['type'], v['fbp'], v['fbpa'], None if v['mask'] is None else hex(v['mask']), v['active'], v['slices'],
       tuple(v['parts']), tuple(hex(x) for x in v['addr']))] += 1
order = ['Fermi', 'Kepler', 'Maxwell', 'Pascal']
print('| поколение | чип | память | FBP | FBPA | маска | активных | подразд. | разделы в скриптах | 0x13d8x4 | трасс |')
print('|---|---|---|---|---|---|---|---|---|---|---|')
for k, n in sorted(c.items(), key=lambda x: (order.index(x[0][0]), x[0][1], str(x[0][2:]))):
    print('| ' + ' | '.join('—' if x is None else (','.join(map(str, x)) if isinstance(x, tuple) else str(x)) for x in k) + f' | {n} |')
