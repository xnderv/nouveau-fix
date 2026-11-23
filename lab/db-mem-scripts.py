#!/usr/bin/env python3
# Скрипты памяти целиком из трасс базы (23.11), GT21x … Pascal: каждая загрузка в память PMU (порт 0x10a1c0/0x10a1c4),
# разобранная форматом NVIDIA (заголовок «длина<<16 | операция»; 0x21 — пары адрес/значение, 0x16 — конец), со ВСЕМИ
# операциями по порядку: [операция, [аргументы]]. Скрипт памяти — если пишет в PFB 0x100xxx, FBPA 0x10f000–0x12ffff или
# MPLL 0x132xxx. Плюс время загрузки (с начала трассы). Выход — scripts.json в частном каталоге описи. Только чтение.
#   python3 -I lab/db-mem-scripts.py [ОПИСЬ_КАТАЛОГ] [БАЗА]
import sys, os, json, subprocess
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser('~/Home/nouveau-archive/mem-survey')
DB = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser('~/Home/nouveau-archive/nouveau_vbios_trace')
inv = json.load(open(os.path.join(OUT, 'inventory.json'))); key = json.load(open(os.path.join(OUT, 'inventory-key.json')))
types = json.load(open(os.path.join(OUT, 'types.json')))

def opener(rel):
    f, _, mem = rel.partition(':'); p = os.path.join(DB, f)
    with open(p, 'rb') as h: m = h.read(6)
    if not mem: return ['xz', '-dc', p] if m.startswith(b'\xfd7zXZ') else ['cat', p]
    if m.startswith(b'\xfd7zXZ'): return ['tar', '-xOJf', p, mem]
    if m.startswith(b'BZh'): return ['tar', '-xOjf', p, mem]
    return ['sh', '-c', 'tar -xOzf "$0" "$1" | (xz -dc 2>/dev/null || cat)', p, mem]

def parse(w):
    i, ops, nw = 0, [], 0
    while i < len(w):
        ln, op = w[i] >> 16, w[i] & 0xffff
        if ln == 0 or i + ln > len(w) + 1 or op > 0xff: return None
        a = w[i + 1:i + ln]
        if op == 0x21 and len(a) % 2: return None
        ops.append([op, a]); nw += len(a) // 2 if op == 0x21 else 0
        if op == 0x16: return ops if nw >= 5 else None
        i += ln
    return None
def is_mem(ops):
    for op, a in ops:
        if op == 0x21:
            for k in range(0, len(a), 2):
                r = a[k]
                if 0x100000 <= r < 0x101000 or 0x10f000 <= r < 0x130000 or 0x132000 <= r < 0x133000: return True
    return False

res = {}
for lab, r in inv.items():
    if r['gen'] not in ('Tesla2', 'Fermi', 'Kepler', 'Maxwell', 'Pascal') or not r['pmu_scripts']: continue
    bar0 = int(r['bar0'], 16); pr = subprocess.Popen(opener(key[lab]), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    cur = None; t0 = None; tcur = 0; out = []; other = 0
    for raw in pr.stdout:
        if raw[:2] != b'W ': continue
        p = raw.split()
        if len(p) < 6: continue
        try: a = int(p[4], 16) - bar0; v = int(p[5], 16); t = float(p[2])
        except ValueError: continue
        if t0 is None: t0 = t
        if a == 0x10a1c4 and cur is not None: cur.append(v); continue
        if cur is not None:
            ops = parse(cur)
            if ops:
                if is_mem(ops): out.append(dict(t=round(tcur - t0, 6), ops=ops))
                else: other += 1
            cur = None
        if a == 0x10a1c0: cur = []; tcur = t
    pr.stdout.close(); pr.wait()
    res[lab] = dict(chip=r['chip'], gen=r['gen'], type=types.get(lab, {}).get('type', '?'), scripts=out, other=other)
    print(f"{lab:10} {r['gen']:7} {res[lab]['type']:6} скриптов памяти {len(out):>3}, прочих того же формата {other}", flush=True)
json.dump(res, open(os.path.join(OUT, 'scripts.json'), 'w'))
print('готово')
