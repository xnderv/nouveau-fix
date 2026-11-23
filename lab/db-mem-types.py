#!/usr/bin/env python3
# Тип памяти каждой трассы (23.11): ремешок из трассы (чтения 0x101000, биты 2–5) + таблица M0203 из BIT M образа VBIOS,
# лежащего в той же папке базы (как nvbios_M0203Em в nouveau: запись с тем же ремешком; тип — младшая тетрада байта 0).
# Если образов в папке несколько — берётся тот, где ремешок находится; разногласие отмечается. Только чтение.
#   python3 -I lab/db-mem-types.py [ОПИСЬ_КАТАЛОГ] [БАЗА]
import sys, os, json, struct, collections, subprocess
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser('~/Home/nouveau-archive/mem-survey')
DB = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser('~/Home/nouveau-archive/nouveau_vbios_trace')
TYPES = {0: 'DDR2', 1: 'DDR3', 2: 'GDDR3', 3: 'GDDR5', 6: 'HBM2', 8: 'GDDR5X'}
inv = json.load(open(os.path.join(OUT, 'inventory.json'))); key = json.load(open(os.path.join(OUT, 'inventory-key.json')))

def rom_bytes(p):
    b = open(p, 'rb').read()
    if b[:6] == b'\xfd7zXZ\x00': b = subprocess.run(['xz', '-dc', p], capture_output=True).stdout
    i = b.find(b'\x55\xaa')
    return b[i:] if i >= 0 else None
def m0203(b):
    bit = b.find(b'\xff\xb8BIT')
    if bit < 0: return None
    r8 = lambda o: b[o]; r16 = lambda o: struct.unpack_from('<H', b, o)[0]
    n, esz = r8(bit + 10), r8(bit + 9); ent = {}
    for i in range(n):
        e = bit + 12 + i * esz; ent[chr(r8(e))] = (r8(e + 1), r16(e + 2), r16(e + 4))
    if 'M' not in ent: return None
    ver, ln, off = ent['M']
    if ver != 2 or ln < 5: return None
    t = r16(off + 3)
    if not t or t + 5 > len(b) or r8(t) != 0x10: return None
    hdr, el, cnt = r8(t + 1), r8(t + 2), r8(t + 3)
    m = {}
    for i in range(cnt):   # первая запись с этим ремешком (как nvbios_M0203Em); 0xf — «пропуск»
        e = r8(t + hdr + i * el); m.setdefault(e >> 4, e & 0x0f)
    return m
res = {}
for lab, r in inv.items():
    if r['gen'] not in ('Tesla2', 'Fermi', 'Kepler', 'Maxwell', 'Pascal'): continue
    d = os.path.dirname(os.path.join(DB, key[lab].split(':')[0]))
    roms = [os.path.join(d, x) for x in sorted(os.listdir(d)) if not x.endswith('.eml') and (x.lower().endswith(('.rom', '.bin')) or 'vbios' in x.lower())]
    straps = {(int(s, 16) >> 2) & 0xf for s in r['strap']}
    found = set(); note = ''
    for p in roms:
        b = rom_bytes(p); t = m0203(b) if b else None
        if not t: continue
        for s in straps:
            if s in t: found.add(TYPES.get(t[s], f'код {t[s]}'))
    if not roms: note = 'нет образа'
    elif not found: note = 'ремешок не найден в M0203'
    elif len(found) > 1: note = 'образы расходятся'
    res[lab] = dict(chip=r['chip'], gen=r['gen'], type='/'.join(sorted(found)) or '?', note=note, scripts=r['pmu_scripts'])
json.dump(res, open(os.path.join(OUT, 'types.json'), 'w'), indent=1, ensure_ascii=False)
by = collections.defaultdict(collections.Counter); sc = collections.defaultdict(collections.Counter)
for v in res.values(): by[(v['gen'], v['chip'])][v['type'] + (f" ({v['note']})" if v['note'] and v['type'] == '?' else '')] += 1; sc[(v['gen'], v['chip'])][v['type']] += v['scripts']
order = ['Tesla2', 'Fermi', 'Kepler', 'Maxwell', 'Pascal']
print('| поколение | чип | трассы по типу памяти | скриптов по типу |'); print('|---|---|---|---|')
for k in sorted(by, key=lambda k: (order.index(k[0]), k[1])):
    print(f"| {k[0]} | {k[1]} | {', '.join(f'{t} {n}' for t, n in by[k].most_common())} | {', '.join(f'{t} {n}' for t, n in sc[k].most_common())} |")
tot = collections.Counter(); tsc = collections.Counter()
for v in res.values(): tot[(v['gen'], v['type'])] += 1; tsc[(v['gen'], v['type'])] += v['scripts']
print(); print('итого:', ', '.join(f'{g} {t}: {n} трасс / {tsc[(g, t)]} скриптов' for (g, t), n in sorted(tot.items(), key=lambda x: (order.index(x[0][0]), x[0][1]))))
