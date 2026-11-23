#!/usr/bin/env python3
# ОПИСЬ БАЗЫ ЗАПИСЕЙ ДЛЯ ГЕНЕРАТОРА ПАМЯТИ (23.11): один проход по всем трассам mmiotrace частной базы (все поколения).
# Для каждой трассы: чип (каталог), BAR0, загрузки в память PMU (порт 0x10a1c0/0x10a1c4) и сколько из них разбираются как
# скрипт NVIDIA (заголовок «длина<<16 | операция», 0x21 — записи, 0x16 — конец), загрузки программ HWSQ (окна 0x001400 и
# 0x080000), записи хоста по блокам памяти, разные значения ремешка 0x101000 (чтения), и сколько записей регистров памяти
# внутри скриптов PMU. Письма (.eml) не читаются; участники обезличены (чип#номер), соответствие — только в частном
# каталоге. Только чтение.
#   python3 -I lab/db-mem-inventory.py [БАЗА] [ВЫХОД_КАТАЛОГ]
import sys, os, json, subprocess, collections
DB = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser('~/Home/nouveau-archive/nouveau_vbios_trace')
OUT = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser('~/Home/nouveau-archive/mem-survey')
os.makedirs(OUT, exist_ok=True)

GEN = [('NV3x', range(0x30, 0x40)), ('NV4x', range(0x40, 0x50)), ('NV4x', range(0x60, 0x70)),
       ('Tesla', range(0x50, 0x51)), ('Tesla', range(0x84, 0xa0)), ('Tesla2', range(0xa0, 0xb0)),
       ('Fermi', range(0xc0, 0xe0)), ('Kepler', range(0xe0, 0x100)), ('Kepler', range(0x106, 0x110)),
       ('Maxwell', range(0x110, 0x130)), ('Pascal', range(0x130, 0x140)), ('Volta+', range(0x140, 0x200))]
def gen(chip):
    try: n = int(chip[2:], 16) if chip.startswith('nv') else (0x126 if chip == 'gm206' else -1)
    except ValueError: return '?'
    for g, r in GEN:
        if n in r: return g
    return '?'

BLOCKS = [('PFB 100xxx', 0x100000, 0x101000), ('FBPA общий 10fxxx', 0x10f000, 0x110000),
          ('FBPA разделы 110-12f', 0x110000, 0x130000), ('MPLL 132xxx', 0x132000, 0x133000),
          ('такты 137xxx', 0x137000, 0x138000), ('такты Tesla 004xxx', 0x004000, 0x004800),
          ('PMU 10axxx', 0x10a000, 0x10b000)]
def block(a):
    for n, lo, hi in BLOCKS:
        if lo <= a < hi: return n
    return None

def magic(p):
    with open(p, 'rb') as h: return h.read(6)
def candidates():
    for r, ds, fs in os.walk(DB):
        ds[:] = [d for d in ds if d not in ('.git', 'scripts', 'stats')]
        for f in fs:
            if f.endswith('.eml'): continue
            p = os.path.join(r, f); rel = os.path.relpath(p, DB); chip = rel.split(os.sep)[0]
            if chip == rel: continue
            m = magic(p)
            low = f.lower()
            if m.startswith(b'\xfd7zXZ'):
                if '.tar' in low:
                    for mem in subprocess.run(['tar', '-tJf', p], capture_output=True, text=True).stdout.split('\n'):
                        if mem and not mem.endswith('/'): yield chip, rel + ':' + mem, ['tar', '-xOJf', p, mem]
                else: yield chip, rel, ['xz', '-dc', p]
            elif m.startswith(b'\x1f\x8b') and '.tar' in low:
                for mem in subprocess.run(['tar', '-tzf', p], capture_output=True, text=True).stdout.split('\n'):
                    if mem and not mem.endswith('/'): yield chip, rel + ':' + mem, ['sh', '-c', f"tar -xOzf \"$0\" \"$1\" | (xz -dc 2>/dev/null || cat)", p, mem]
            elif m.startswith(b'BZh') and '.tar' in low:
                for mem in subprocess.run(['tar', '-tjf', p], capture_output=True, text=True).stdout.split('\n'):
                    if mem and not mem.endswith('/'): yield chip, rel + ':' + mem, ['tar', '-xOjf', p, mem]
            elif m[:4] in (b'VERS', b'MARK', b'MAP ', b'R 4 ', b'W 4 ', b'PCID'):
                yield chip, rel, ['cat', p]

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

def scan(cmd):
    pr = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    bar0 = None; first = True; mmio = False
    host = collections.Counter(); hostregs = collections.defaultdict(set); strap = collections.Counter()
    up = 0; scr = 0; scrw = collections.Counter(); scrregs = collections.defaultdict(set); hwsq = 0; cur = None
    lines = 0
    for raw in pr.stdout:
        if first:
            first = False
            if not raw[:4] in (b'VERS', b'MARK', b'MAP ', b'R 4 ', b'W 4 ', b'PCID', b'R 1 ', b'W 1 '): break
            mmio = True
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
        lines += 1
        if raw[0] == 82:
            if a == 0x101000: strap[v] += 1
            continue
        if a == 0x10a1c4 and cur is not None: cur.append(v); continue
        if cur is not None:
            ops = decode(cur)
            if ops and len(ops) >= 5:
                scr += 1
                for r, x in ops:
                    b = block(r)
                    if b: scrw[b] += 1; scrregs[b].add(r)
            cur = None
        if a == 0x10a1c0: up += 1; cur = []; continue
        if 0x001400 <= a < 0x001800 or 0x080000 <= a < 0x081000: hwsq += 1
        b = block(a)
        if b: host[b] += 1; hostregs[b].add(a)
    pr.stdout.close(); pr.wait()
    if not mmio or bar0 is None: return None
    return dict(bar0=hex(bar0), lines=lines, pmu_uploads=up, pmu_scripts=scr, hwsq_writes=hwsq,
                strap=sorted(f'{k:08x}' for k in strap), host=dict(host), host_regs={k: len(v) for k, v in hostregs.items()},
                scr_writes=dict(scrw), scr_regs={k: len(v) for k, v in scrregs.items()})

res = {}; key = {}; nchip = collections.Counter()
for chip, rel, cmd in candidates():
    r = scan(cmd)
    if r is None: continue
    nchip[chip] += 1; lab = f'{chip}#{nchip[chip]}'
    key[lab] = rel; r['chip'] = chip; r['gen'] = gen(chip); res[lab] = r
    print(f"{lab:10} {r['gen']:7} строк {r['lines']:>9}  PMU загрузок {r['pmu_uploads']:>5} скриптов {r['pmu_scripts']:>3}  "
          f"HWSQ {r['hwsq_writes']:>6}  ремешок {','.join(r['strap']) or '-'}", flush=True)
json.dump(res, open(os.path.join(OUT, 'inventory.json'), 'w'), indent=1, ensure_ascii=False)
json.dump(key, open(os.path.join(OUT, 'inventory-key.json'), 'w'), indent=1, ensure_ascii=False)
print('готово:', len(res), 'трасс')
