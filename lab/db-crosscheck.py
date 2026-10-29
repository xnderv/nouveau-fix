#!/usr/bin/env python3
# Сверка модели с трассами NVIDIA других карт Fermi (частная база nouveau_vbios_trace и наши записи): для каждого регистра
# модели (docs/model/registers.tsv) — какие значения NVIDIA пишет на каждой карте, прямыми записями хоста и внутри скриптов
# памяти PMU (загрузки через 0x10a1c0/0x10a1c4, разбор как lab/trace-memscr.py). Плюс ремешок 0x101000 (чтение) и 0x020130.
# Выход — JSON по трассам (в частный каталог, участники обезличены). Только чтение.
#   python3 -I lab/db-crosscheck.py ВЫХОД.json ТРАССА:МЕТКА:ЧИП ...   (ТРАССА — .txt / .xz / tar.gz:член; '!' перед путём
#   — xz внутри xz). BAR0 находится сам (первое отображение 16 МБ).
import sys, json, subprocess, collections, re, os
KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
regs = {}
for l in open(os.path.join(KIT, 'docs/model/registers.tsv'), encoding='utf-8'):
    if l.startswith('#') or not l.strip(): continue
    c = l.rstrip('\n').split('\t'); regs[int(c[0], 16)] = c[6]
def stream(spec):
    if spec.startswith('!'): return subprocess.Popen(f"xz -dc '{spec[1:]}' | xz -dc", shell=True, stdout=subprocess.PIPE).stdout
    if '.tar.gz:' in spec:
        t, m = spec.split('.tar.gz:'); return subprocess.Popen(f"tar -xOzf '{t}.tar.gz' '{m}' | xz -dc", shell=True, stdout=subprocess.PIPE).stdout
    if spec.endswith('.xz'): return subprocess.Popen(['xz', '-dc', spec], stdout=subprocess.PIPE).stdout
    return open(spec, 'rb')
def decode(w):
    i, ops = 0, []
    while i < len(w):
        ln, op = w[i] >> 16, w[i] & 0xffff
        if ln == 0 or i + ln > len(w) + 1: return None
        a = w[i + 1:i + ln]
        if op == 0x21:
            if len(a) % 2: return None
            ops += [(a[k], a[k + 1]) for k in range(0, len(a), 2)]
        elif op == 0x16: return ops
        i += ln
    return None
out = {}
for arg in sys.argv[2:]:
    spec, label, chip = arg.rsplit(':', 2)
    bar0 = None; host = collections.defaultdict(collections.Counter); pmu = collections.defaultdict(collections.Counter)
    strap = collections.Counter(); cfg2 = collections.Counter(); nscr = 0; cur = None
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
        if not 0 <= a < 0x1000000: continue
        if raw[0] == 82:   # 'R'
            if a == 0x101000: strap[v] += 1
            elif a == 0x020130: cfg2[v] += 1
            continue
        if a == 0x10a1c4 and cur is not None: cur.append(v); continue
        if cur is not None:   # загрузка закончилась (любая другая запись, в т. ч. новый адрес 0x10a1c0) — разобрать
            ops = decode(cur)
            if ops and len(ops) >= 5:
                nscr += 1
                for r, x in ops:
                    if r in regs: pmu[r][x] += 1
            cur = None
        if a == 0x10a1c0: cur = []; continue
        if a in regs: host[a][v] += 1
    out[label] = dict(chip=chip, bar0=hex(bar0) if bar0 else None, scripts=nscr,
                      strap={f'{k:08x}': c for k, c in strap.items()}, cfg2={f'{k:08x}': c for k, c in cfg2.items()},
                      host={f'{r:06x}': {f'{k:08x}': c for k, c in vs.items()} for r, vs in host.items()},
                      pmu={f'{r:06x}': {f'{k:08x}': c for k, c in vs.items()} for r, vs in pmu.items()})
    print(f'{label} ({chip}): BAR0 {out[label]["bar0"]}, скриптов памяти {nscr}, регистров модели: прямых {len(host)}, в скриптах {len(pmu)}', flush=True)
json.dump(out, open(sys.argv[1], 'w'), indent=0)
