#!/usr/bin/env python3
# Коды замедления в скобке FSRM по чипам и направлению переключения (трассы NVIDIA): для каждой скобки GPC (запись
# 0x020160 с ненулевым кодом в битах 16–21) — код и что делает следующая запись 0x137100 с битом GPC (0): на PLL (1) или на
# делитель (0); то же для hubk06 (0x020164, бит 7 0x137100). Только чтение; вход — пути трасс (как lab/db-crosscheck.py).
#   python3 -I lab/db-bracket-codes.py МЕТКА:ЧИП:ТРАССА ...   (ТРАССА: .txt/.xz, '!' — xz в xz, путь.tar.gz:член)
import sys, subprocess, collections
def stream(spec):
    if spec.startswith('!'): return subprocess.Popen(f"xz -dc '{spec[1:]}' | xz -dc", shell=True, stdout=subprocess.PIPE).stdout
    if '.tar.gz:' in spec:
        t, m = spec.split('.tar.gz:'); return subprocess.Popen(f"tar -xOzf '{t}.tar.gz' '{m}' | xz -dc", shell=True, stdout=subprocess.PIPE).stdout
    if spec.endswith('.xz'): return subprocess.Popen(['xz', '-dc', spec], stdout=subprocess.PIPE).stdout
    return open(spec, 'rb')
NAMES = {'nvc0': 'GF100', 'nvc1': 'GF108', 'nvc3': 'GF106', 'nvc4': 'GF104', 'nvc8': 'GF110', 'nvce': 'GF114', 'nvcf': 'GF116', 'nvd7': 'GF117', 'nvd9': 'GF119'}
res = collections.defaultdict(collections.Counter)
for arg in sys.argv[1:]:
    label, chip, spec = arg.split(':', 2)
    bar0 = None; pend = {}; mux = 0
    for raw in stream(spec):
        if bar0 is None:
            if raw.startswith(b'MAP '):
                p = raw.split()
                if len(p) >= 6 and p[5] == b'0x1000000': bar0 = int(p[3], 16)
            continue
        if raw[:2] not in (b'W ', b'R '): continue
        p = raw.split()
        if len(p) < 6: continue
        try: a = int(p[4], 16) - bar0; v = int(p[5], 16)
        except ValueError: continue
        if raw[0] == 82:
            if a == 0x137100: mux = v
            continue
        if a in (0x020160, 0x020164):
            code = (v >> 16) & 0x3f
            if code: pend[0 if a == 0x020160 else 7] = code
        elif a == 0x137100:
            for idx, code in list(pend.items()):
                bit = 1 << idx
                if (mux ^ v) & bit:
                    res[(chip, 'GPC' if idx == 0 else 'hub')][(code, 'на PLL' if v & bit else 'на делитель')] += 1
                    del pend[idx]
            mux = v
    print(f'{label}: BAR0 {hex(bar0) if bar0 else "?"}', flush=True)
print()
for (chip, dom), c in sorted(res.items()):
    print(f"{NAMES.get(chip, chip)} {dom}: " + '; '.join(f"код {code:#x} (/{(code + 2) / 2:g}) {d} ×{n}" for (code, d), n in sorted(c.items())))
