#!/usr/bin/env python3
# Напряжение верхнего уровня в записях NVIDIA базы против двух полей записи уровня VBIOS: байт 2 (его берёт nouveau) и байт 14
# (второе поле; рядом байт 16 — похоже на порог температуры). Для каждой записи Fermi, рядом с которой лежит образ VBIOS:
# напряжение по каждому полю так, как его считает nouveau (nvkm_volt_map: карта напряжений с числом «спидо» из предохранителя
# 0x1cc, иначе число × 10 мВ; затем ближайшая ступень VID не ниже), какое напряжение NVIDIA держит в момент перевода GPC2CLK на
# PLL (верхний уровень: напряжение она поднимает до тактов) и что показывал датчик 0x020400 перед подъёмом.
# Только чтение. Пути базы не печатаются — метки «чип#номер».
#   python3 -I lab/db-volt-levels.py [чипы через запятую | -] [КАТАЛОГ_ОБЗОРА] [КАТАЛОГ_БАЗЫ]
#   python3 -I lab/db-volt-levels.py --one МЕТКА ОБРАЗ.rom ЗАПИСЬ[.xz]      — запись тестировщика вне базы
import sys, os, json, glob, struct, subprocess, collections
NAME = {'nvc0': 'GF100', 'nvc4': 'GF104', 'nvc3': 'GF106', 'nvc1': 'GF108', 'nvc8': 'GF110', 'nvce': 'GF114', 'nvcf': 'GF116', 'nvd7': 'GF117', 'nvd9': 'GF119'}
GPIO = [0xe104, 0xe108, 0xe280, 0xe284]
VIDF = {0x04: 0, 0x05: 1, 0x06: 2, 0x1a: 3, 0x73: 4, 0x74: 5, 0x75: 6, 0x76: 7}


def rom_info(b):
    r8 = lambda o: b[o]; r16 = lambda o: struct.unpack_from('<H', b, o)[0]; r32 = lambda o: struct.unpack_from('<I', b, o)[0]
    s32 = lambda o: struct.unpack_from('<i', b, o)[0]
    bit = b.find(b'\xff\xb8BIT'); n, esz = r8(bit + 10), r8(bit + 9); ent = {}
    for i in range(n):
        e = bit + 12 + i * esz; ent[chr(b[e])] = (b[e + 1], r16(e + 2), r16(e + 4))
    pver, pln, poff = ent['P']
    volt = r16(poff + 0x0c); vids = {}; vidmask = 0
    v = r8(volt) if volt else 0
    if v in (0x20, 0x30):
        hdr, rl, cnt = r8(volt + 1), r8(volt + 2), r8(volt + 3); vidmask = r8(volt + 5) if v == 0x20 else r8(volt + 4)
        for i in range(cnt):
            e = volt + hdr + i * rl; vids[r8(e + 1) >> 2] = r8(e) * 10000
    elif v == 0x40:
        base, step, vidmask = r32(volt + 4), struct.unpack_from('<h', b, volt + 8)[0], r8(volt + 0x0b)
        for k in range(vidmask + 1): vids[k] = base + step * k
    vm = []
    vmap = r16(poff + 0x20) if pln > 0x21 else 0
    if vmap and r8(vmap) == 0x10:
        mh, ml, mc = r8(vmap + 1), r8(vmap + 2), r8(vmap + 3)
        for i in range(mc):
            e = vmap + mh + i * ml; vm.append((r32(e), r32(e + 4), s32(e + 8), s32(e + 12), s32(e + 16)))
    perf = r16(poff); ph, prl, pss, psn, pcnt = r8(perf + 1), r8(perf + 2), r8(perf + 3), r8(perf + 4), r8(perf + 5)
    lv = []
    for i in range(pcnt):
        e = perf + ph + i * (prl + pss * psn)
        if r8(e) == 0xff or prl < 17: continue
        lv.append((r8(e), r8(e + 2), r8(e + 14), r8(e + 16)))
    dcb = r16(0x36); gp = r16(dcb + 0x0a); gver, ghdr, gcnt, glen = r8(gp), r8(gp + 1), r8(gp + 2), r8(gp + 3); lines = {}
    for e in range(gcnt):
        d = gp + ghdr + e * glen
        if gver < 0x41:
            info = r32(d); line, func, log1 = info & 0x1f, (info >> 8) & 0xff, (info >> 29) & 3
        else:
            info, info1 = r32(d), r8(d + 4); line, func, log1 = info & 0x3f, (info >> 8) & 0xff, (info1 >> 6) & 3
        if func in VIDF: lines[VIDF[func]] = (line, log1)
    return dict(vver=v, vids=vids, vidmask=vidmask, vm=vm, lv=lv, lines=lines)


def field_uv(ri, x, speedo):
    """поле записи уровня → мкВ, как nvkm_volt_map: запись карты напряжений (формула от «спидо») или число × 10 мВ"""
    vm = ri['vm']
    if x < len(vm) and (vm[x][0] or vm[x][1]):
        mn, mx, a0, a1, a2 = vm[x]
        if not (a0 or a1 or a2): return mn
        if speedo is None: return None
        return min(max(a0 // 10 + (a1 * speedo) // 10 + (a2 * speedo * speedo) // 100000, mn), mx)
    return x * 10000


def step_up(ri, uv):
    c = sorted(u for u in ri['vids'].values() if u >= uv) if uv is not None else []
    return c[0] if c else None


def analyse(ri, cmd, bar0, gf119):
    regs = [0xd610 + l * 4 for l, _ in ri['lines'].values()] if gf119 else GPIO
    want = {'0x%x' % (bar0 + r): r for r in regs + [0x137100, 0x20400, 0x0212cc]}
    prog = 'BEGIN{' + ''.join('A["%s"]=1;' % a for a in want) + '} ($1=="W" || $1=="R") && NF>=6 && ($5 in A) {print $1,$3,$5,$6}'
    p1 = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    out = subprocess.run(['mawk', prog], stdin=p1.stdout, capture_output=True, text=True).stdout; p1.wait()
    st = {}; vid = None; mux = 0; temp = None; speedo = None; ups = collections.Counter(); temps = []
    for ln in out.splitlines():
        try: k, t, a, v = ln.split(); r = want[a]; v = int(v, 16)
        except (ValueError, KeyError): continue
        if r == 0x20400:
            if k == 'R' and v < 150: temp = v
        elif r == 0x0212cc:
            if k == 'R' and speedo is None and v: speedo = v
        elif r == 0x137100:
            if k == 'W':
                if (v & 1) and not (mux & 1):
                    if vid is not None: ups[vid] += 1
                    if temp is not None: temps.append(temp)
                mux = v
        else:
            if k == 'R' and r in st: continue
            st[r] = v
            if k != 'W': continue
            x = 0; ok = True
            for bn, (line, log1) in ri['lines'].items():
                if not (ri['vidmask'] >> bn) & 1: continue
                reg = 0xd610 + line * 4 if gf119 else GPIO[line >> 3]
                if reg not in st: ok = False; break
                bit = (st[reg] >> 12) & 1 if gf119 else (st[reg] >> ((line & 7) << 2)) & 1
                if bit == (log1 & 1): x |= 1 << bn
            vid = x if ok else None
    return ups, temps, speedo


def row(label, ri, ups, temps, speedo):
    top = ri['lv'][-1]
    u2 = step_up(ri, field_uv(ri, top[1], speedo))
    has14 = top[2] not in (0, 0x0f)
    u14 = step_up(ri, field_uv(ri, top[2], speedo)) if has14 else None
    nv = sorted(ups.items(), key=lambda x: -x[1])
    nvuv = ri['vids'].get(nv[0][0]) if nv else None
    f = lambda u: f'{u/1e6:.4f}' if u else '—'
    if nvuv is None: verdict = 'нет данных'
    elif nvuv == u2 and nvuv == u14: verdict = 'оба поля дают одно'
    elif nvuv == u2: verdict = 'байт 2'
    elif nvuv == u14: verdict = '**байт 14**'
    else: verdict = 'ни то, ни другое'
    tt = f'{min(temps)}–{max(temps)}' if temps else '—'
    return f'| {label} | {f(u2)} | {f(u14)} | {top[3] if has14 or top[3] else "—"} | {f(nvuv)}{" ×" + str(nv[0][1]) if nv else ""} | {tt} | {verdict} |', verdict, has14


HEAD = ('| запись | по байту 2, В | по байту 14, В | байт 16 (порог?) | NVIDIA наверху, В × подъёмов | датчик перед подъёмами, °C | NVIDIA берёт |\n'
        '|---|---|---|---|---|---|---|')

if len(sys.argv) > 1 and sys.argv[1] == '--one':
    label, rom, trace = sys.argv[2:5]
    ri = rom_info(open(rom, 'rb').read())
    cat = ['xz', '-dc', trace] if trace.endswith('.xz') else ['cat', trace]
    bar0 = None
    p = subprocess.Popen(cat, stdout=subprocess.PIPE)
    for raw in p.stdout:
        if raw.startswith(b'MAP '):
            f = raw.split()
            if int(f[5], 16) == 0x1000000: bar0 = int(f[3], 16); break
    p.kill()
    print(HEAD); print(row(label, ri, *analyse(ri, cat, bar0, False))[0]); sys.exit()

CH = (sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] != '-' else ','.join(NAME)).split(',')
OUT = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser('~/Home/nouveau-archive/mem-survey')
DB = sys.argv[3] if len(sys.argv) > 3 else os.path.expanduser('~/Home/nouveau-archive/nouveau_vbios_trace')
inv = json.load(open(os.path.join(OUT, 'inventory.json'))); key = json.load(open(os.path.join(OUT, 'inventory-key.json')))


def opener(rel):
    f, _, mem = rel.partition(':'); p = os.path.join(DB, f)
    with open(p, 'rb') as h: m = h.read(6)
    if not mem: return ['xz', '-dc', p] if m.startswith(b'\xfd7zXZ') else ['cat', p]
    if m.startswith(b'\xfd7zXZ'): return ['tar', '-xOJf', p, mem]
    if m.startswith(b'BZh'): return ['tar', '-xOjf', p, mem]
    return ['sh', '-c', 'tar -xOzf "$0" "$1" | (xz -dc 2>/dev/null || cat)', p, mem]


labs = sorted((l for l in inv if l.split('#')[0] in CH), key=lambda s: (s.split('#')[0], int(s.split('#')[1])))
print(HEAD)
tally = collections.Counter()
for lab in labs:
    d = os.path.dirname(os.path.join(DB, key[lab].partition(':')[0]))
    roms = sorted(glob.glob(os.path.join(d, '*.rom')))
    if not roms: continue
    try: ri = rom_info(open(roms[0], 'rb').read())
    except Exception: continue
    if not ri['lines'] or not ri['vids'] or not ri['lv']: continue
    ups, temps, speedo = analyse(ri, opener(key[lab]), int(inv[lab]['bar0'], 16), lab.startswith('nvd'))
    line, verdict, has14 = row(f'{NAME.get(lab.split("#")[0], "?")} {lab}', ri, ups, temps, speedo)
    print(line); tally[(verdict, 'второе поле есть' if has14 else 'второго поля нет')] += 1
print()
for (v, h), n in sorted(tally.items()): print(f'{h}; NVIDIA берёт: {v} — {n}')
