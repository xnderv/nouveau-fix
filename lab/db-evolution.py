#!/usr/bin/env python3
# ЭВОЛЮЦИЯ СМЕНЫ ЧАСТОТ ДО FERMI (30.10): записи NVIDIA из internal vbios repo (NV3x … GT21x). Сырые данные не выводятся,
# участники обезличены (у1, у2 … по порядку появления). Два режима:
#   python3 -I lab/db-evolution.py scan [БАЗА]   — по каждой записи: сколько записей в такты (0x004000–0x0047ff, 0x00c040,
#       0x680500/504/570 у NV3x), в PTHERM (0x020000–0x0200ff, по адресам), в PMU (0x10a000–0x10afff), пауза FIFO
#       (0x002504), чтения PTIMER (0x009400), загрузки программ HWSQ (окна 0x001400 у G80–G92 и 0x080000 у G94+)
#   python3 -I lab/db-evolution.py hwsq [БАЗА]   — расшифровка программ HWSQ по формату nouveau (nvkm/subdev/bus/hwsq.c):
#       0x00–0x3f выдержка (b&3)·4^(b>>2) мкс; 0x40/0xe0 адрес (16/32 бита); 0x42/0xe2 значение; 0x5f ожидание флага;
#       0x80–0xdf установка флага; 0x7f конец. Неизвестные байты помечаются «?xx».
# Класс Д (чужие записи), формат команд — класс Г (nouveau).
import collections, os, re, subprocess, sys

DB = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser('~/Home/nouveau-archive/nouveau_vbios_trace')

def traces():
    out = subprocess.run(['git', '-C', DB, 'ls-files'], capture_output=True, text=True).stdout.split('\n')
    who = {}
    for p in out:
        p = p.strip().strip('"')
        parts = p.split('/')
        m = re.fullmatch(r'nv([0-9a-f]+)t?', parts[0])
        if not m or int(m.group(1), 16) > 0xaf:
            continue
        b = os.path.basename(p)
        if not re.search(r'mmio|trace|downclock|reclock', b.lower()) or b.endswith('traces.tar.xz') or 'crap' in b:
            continue
        w = parts[1] if len(parts) > 2 else '?'
        who.setdefault(w, 'у%d' % (len(who) + 1))
        yield parts[0], who[w], os.path.join(DB, p), b

def stream(path):
    mg = open(path, 'rb').read(6)
    if path.endswith('.tar.gz'):
        cmd = f"tar -xOzf '{path}'"
    elif path.endswith('.tar.bz2'):
        cmd = f"tar -xOjf '{path}'"
    elif mg.startswith(b'\xfd7zXZ'):
        head = subprocess.run(f"xz -dc '{path}' | head -c 6", shell=True, capture_output=True).stdout
        cmd = f"xz -dc '{path}'" if not head.startswith(b'\xfd7zXZ') else f"xz -dc '{path}' | xz -dc"
    else:
        cmd = f"cat '{path}'"
    p = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return p.stdout

def accesses(path):
    """(op, offset, value, time) для доступов к BAR0 (первое отображение 16 МБ)."""
    bar = None
    for raw in stream(path):
        if raw.startswith(b'MAP '):
            f = raw.split()
            if bar is None and len(f) > 5 and int(f[5], 16) == 0x1000000:
                bar = int(f[3], 16)
            continue
        if bar is None or not (raw.startswith(b'W ') or raw.startswith(b'R ')):
            continue
        f = raw.split()
        if len(f) < 6:
            continue
        a = int(f[4], 16) - bar
        if 0 <= a < 0x1000000:
            yield chr(raw[0]), a, int(f[5], 16), float(f[2])

def scan():
    for chip, who, path, name in traces():
        c = collections.Counter(); therm = collections.Counter(); hw = 0; last = None
        for op, a, v, t in accesses(path):
            if op == 'W':
                c['W'] += 1
                if 0x004000 <= a < 0x004800 or a == 0x00c040 or a in (0x680500, 0x680504, 0x680570):
                    c['такты'] += 1
                if 0x020000 <= a < 0x020100:
                    therm[a] += 1
                if 0x10a000 <= a < 0x10b000:
                    c['PMU'] += 1
                if a == 0x002504:
                    c['FIFO'] += 1
                if a == 0x00130c:
                    hw += 1
            elif a == 0x009400:
                c['PTIMER'] += 1
        th = ' '.join(f'{a:06x}×{n}' for a, n in sorted(therm.items()))
        print(f"{chip:5s} {who:4s} {name[:38]:38s} W {c['W']:7d} | такты {c['такты']:5d} | HWSQ {hw:3d} | FIFO {c['FIFO']:3d}"
              f" | PMU {c['PMU']:6d} | PTIMER {c['PTIMER']:6d} | PTHERM {th or '—'}", flush=True)

def decode(bs):
    out, i = [], 0
    while i < len(bs):
        b = bs[i]
        if b <= 0x3f:
            out.append(f"ждать {(b & 3) << (2 * (b >> 2))} мкс"); i += 1
        elif b in (0x40, 0x42) and i + 2 < len(bs):
            out.append(('адрес' if b == 0x40 else 'знач') + f" …{bs[i+2]:02x}{bs[i+1]:02x}"); i += 3
        elif b in (0xe0, 0xe2) and i + 4 < len(bs):
            v = bs[i+1] | bs[i+2] << 8 | bs[i+3] << 16 | bs[i+4] << 24
            out.append(('адрес' if b == 0xe0 else 'знач') + f" {v:08x}"); i += 5
        elif b == 0x5f and i + 2 < len(bs):
            out.append(f"ждать флаг {bs[i+1]:02x}={bs[i+2]}"); i += 3
        elif b == 0x7f:
            out.append('конец'); break
        elif 0x80 <= b <= 0xdf:
            out.append(f"флаг {(b - 0x80) & 0x1f:02x}:={-1 if b < 0xa0 else 0 if b < 0xc0 else 1}"); i += 1
        else:
            out.append(f"?{b:02x}"); i += 1
    return out

def hwsq():
    for chip, who, path, name in traces():
        progs, cur, t0 = [], {}, None
        for op, a, v, t in accesses(path):
            if op != 'W':
                continue
            if 0x001400 <= a < 0x001800 or 0x080000 <= a < 0x080800:
                base = 0x001400 if a < 0x002000 else 0x080000
                cur[(a - base) // 4] = v
                t0 = t0 or t
            elif a == 0x00130c and cur:
                words = [cur[k] for k in sorted(cur)]
                bs = b''.join(w.to_bytes(4, 'little') for w in words)
                progs.append((t0, decode(bs)))
                cur, t0 = {}, None
        if not progs:
            continue
        uniq = collections.OrderedDict()
        for t, d in progs:
            uniq.setdefault(' ; '.join(d), []).append(t)
        print(f"===== {chip} {who} {name}: программ {len(progs)}, разных {len(uniq)}")
        for d, ts in uniq.items():
            print(f"  ×{len(ts)} (первая {ts[0]:.3f} с): {d}")

def around():
    # python3 -I lab/db-evolution.py around ЧИП АДРЕС [N] — записи хоста вокруг первых N записей в АДРЕС (окно ±0,5 мс,
    # без загрузки данных в PMU 0x10a1c4), время относительно записи в АДРЕС, мкс
    chip, addr, n = sys.argv[2], int(sys.argv[3], 16), int(sys.argv[4]) if len(sys.argv) > 4 else 3
    global DB
    DB = os.path.expanduser('~/Home/nouveau-archive/nouveau_vbios_trace')
    for c, who, path, name in traces():
        if c != chip:
            continue
        ws = [(a, v, t) for op, a, v, t in accesses(path) if op == 'W' and a != 0x10a1c4]
        hits = [i for i, (a, v, t) in enumerate(ws) if a == addr][:n]
        print(f"===== {c} {who} {name}: записей в {addr:06x} — показаны первые {len(hits)}")
        for i in hits:
            t0 = ws[i][2]
            print(f"  --- {t0:.6f} с")
            for a, v, t in ws:
                if abs(t - t0) <= 0.0005:
                    print(f"    {1e6 * (t - t0):+9.1f} мкс  {a:06x} = {v:08x}{'   <==' if a == addr and t == t0 else ''}")

if __name__ == '__main__':
    {'scan': scan, 'hwsq': hwsq, 'around': around}[sys.argv[1] if len(sys.argv) > 1 else 'scan']()
