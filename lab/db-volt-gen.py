#!/usr/bin/env python3
# ФОРМУЛА НАПРЯЖЕНИЯ ПО ПОКОЛЕНИЯМ (30.10): объясняет ли расчёт nouveau (карта напряжений VBIOS 0x10/0x20, режимы 0–3, связи;
# nvkm_volt_map + nvkm_volt_set, класс Г) напряжения, которые ставила NVIDIA, на платах Fermi с ШИМ, Kepler и Maxwell.
# Из записи: метка качества (фьюз 0x3a8 → 0x0214a8, фьюз 0x1cc → 0x0212cc), температура (0x020400), записи ШИМ
# (0x020340 делитель, 0x020344 заполнение) и линий VID (0x00e104/108/280/284). Участники обезличены, пути не выводятся.
#   python3 -I lab/db-volt-gen.py scan ВЫХОД.json [c0 1ff]
#   python3 -I lab/db-volt-gen.py report ВЫХОД.json
import collections, json, os, re, struct, subprocess, sys, importlib.util
from multiprocessing import Pool

HERE = os.path.dirname(os.path.abspath(__file__))
_s = importlib.util.spec_from_file_location('dc', os.path.join(HERE, 'db-core-check.py'))
dc = importlib.util.module_from_spec(_s); _s.loader.exec_module(dc)
tv = dc.tv
GPIO = (0x00e104, 0x00e108, 0x00e280, 0x00e284)

def replay(stream):
    bar, speedo, temps, pwm, vid, div, gp = None, {}, [], [], [], None, {}
    for raw in stream:
        if raw.startswith(b'MAP '):
            f = raw.split()
            if bar is None and len(f) > 5 and int(f[5], 16) == 0x1000000:
                bar = int(f[3], 16)
            continue
        c0 = raw[:2]
        if bar is None or c0 not in (b'W ', b'R '):
            continue
        f = raw.split()
        if len(f) < 6:
            continue
        a = int(f[4], 16) - bar
        if a not in (0x0214a8, 0x0212cc, 0x020400, 0x020340, 0x020344) and a not in GPIO:
            continue
        v, t = int(f[5], 16), float(f[2])
        if c0 == b'R ':
            if a in (0x0214a8, 0x0212cc):
                speedo.setdefault(f'{a:06x}', v)
            elif a == 0x020400 and (not temps or temps[-1][1] != v):
                temps.append((t, v))
            elif a in GPIO:
                gp.setdefault(a, v)
            continue
        if a == 0x020340:
            div = v
        elif a == 0x020344:
            pwm.append((t, div, v))
        elif a in GPIO:
            gp[a] = v
            vid.append((t, dict(gp)))
    return {'speedo': speedo, 'temps': temps[:2000], 'pwm': pwm, 'vid': [(t, {f'{k:06x}': x for k, x in g.items()}) for t, g in vid]}

def scan_one(job):
    chip, who, i, path = job
    out = []
    try:
        for member, st in dc.streams(path):
            r = replay(st)
            r.update(chip=chip, who=who, trace=f'{i}{(" " + member) if member else ""}')
            out.append(r)
    except Exception as e:
        out.append({'chip': chip, 'who': who, 'trace': str(i), 'error': repr(e)[:200]})
    return out

def scan(outp, lo, hi):
    jobs = [(c, w, i, os.path.join(tv.DB, t)) for c, w, trs, vbs in tv.boards(lo, hi) for i, t in enumerate(trs)]
    res = []
    with Pool(4) as pool:
        for part in pool.imap_unordered(scan_one, jobs):
            for r in part:
                print(f"{r['chip']} {r['who']} запись {r['trace']}: speedo {r.get('speedo')}, ШИМ {len(r.get('pwm', []))}, VID {len(r.get('vid', []))}"
                      f"{' ОШИБКА ' + r['error'] if 'error' in r else ''}", flush=True)
                res.append(r)
    json.dump(res, open(outp, 'w'), ensure_ascii=False)
    print('записано', len(res))

# ---------- VBIOS ----------
class V:
    def __init__(self, path):
        b = self.b = open(path, 'rb').read()
        bit = b.find(b'\xff\xb8BIT')
        self.P = None
        if bit >= 0:
            n, esz = b[bit + 10], b[bit + 9]
            for i in range(n):
                e = bit + 12 + i * esz
                if chr(b[e]) == 'P':
                    self.P = (b[e + 1], struct.unpack_from('<H', b, e + 4)[0])
    def r8(self, o): return self.b[o]
    def r16(self, o): return struct.unpack_from('<H', self.b, o)[0]
    def r32(self, o): return struct.unpack_from('<I', self.b, o)[0]
    def s32(self, o): return struct.unpack_from('<i', self.b, o)[0]
    def volt(self):
        if not self.P or self.P[0] != 2:
            return None
        t = self.r32(self.P[1] + 0x0c)
        if not t or t >= len(self.b):
            return None
        ver = self.r8(t)
        if ver == 0x50:
            d = dict(ver=ver, min=self.r32(t + 0x0a), max=self.r32(t + 0x0e), base=self.r32(t + 0x12) & 0xffffff)
            if self.r32(t + 4) & 1:
                d.update(type='PWM', pwm_freq=self.r32(t + 5) // 1000, pwm_range=self.r32(t + 0x16))
            else:
                d.update(type='GPIO', vidmask=self.r8(t + 6), step=self.r16(t + 0x16))
            return d
        if ver == 0x40:
            base, step, vidmask, mx = self.r32(t + 4), struct.unpack_from('<h', self.b, t + 8)[0], self.r8(t + 0x0b), self.r32(t + 0x0e)
            return dict(ver=ver, type='GPIO', base=base, step=step, vidmask=vidmask, max=mx)
        return dict(ver=ver, type='?')
    def vmap(self):
        if not self.P or self.P[0] != 2:
            return None, []
        m = self.r32(self.P[1] + 0x20)
        if not m or m >= len(self.b):
            return None, []
        ver, hdr, ln, cnt = self.r8(m), self.r8(m + 1), self.r8(m + 2), self.r8(m + 3)
        ents = []
        for i in range(cnt):
            e = m + hdr + i * ln
            if ver == 0x10:
                ents.append(dict(mode=0, link=0xff, min=self.r32(e), max=self.r32(e + 4), arg=[self.s32(e + 8), self.s32(e + 12), self.s32(e + 16)]))
            elif ver == 0x20:
                ents.append(dict(mode=self.r8(e), link=self.r8(e + 1), min=self.r32(e + 2), max=self.r32(e + 6),
                                 arg=[self.s32(e + 0x0a + 4 * k) for k in range(6)]))
        return ver, ents

def tdiv(a, b):
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b > 0) else -q

def vmap_uv(ver, ents, idx, s, temp, depth=0):
    """nvkm_volt_map (base.c), с переносом знаков и сдвигов как в C (s64)."""
    if idx >= len(ents) or depth > 4:
        return None
    e = ents[idx]; a = e['arg']
    if ver == 0x10 or (ver == 0x20 and e['mode'] == 0):
        r = tdiv(a[0], 10) + tdiv(a[1] * s, 10) + tdiv(a[2] * s * s, 100000)
    elif e['mode'] == 1:
        r = ((a[0] * 15625) >> 18) + ((a[1] * s * 15625) >> 18) + ((a[2] * temp * 15625) >> 10) \
            + ((a[3] * s * temp * 15625) >> 18) + ((a[4] * s * s * 15625) >> 30) + ((a[5] * temp * temp * 15625) >> 18)
    elif e['mode'] == 3:
        r = (e['min'] + e['max']) // 2
    else:
        r = e['min']
    r = max(e['min'], min(e['max'], r))
    if e['link'] != 0xff:
        l = vmap_uv(ver, ents, e['link'], s, temp, depth + 1)
        if l is None:
            return None
        r += l
    return r

def report(inp):
    res = json.load(open(inp))
    by = collections.defaultdict(list)
    for r in res:
        by[(r['chip'], r['who'])].append(r)
    tot = collections.Counter(); lines = []; notes = []
    for (c, w), rs in sorted(by.items()):
        romp = next((os.path.join(tv.DB, v) for cc, ww, trs, vbs in tv.boards(0x00, 0x1ff) if (cc, ww) == (c, w)
                     for v in vbs if os.path.exists(os.path.join(tv.DB, v))), None)
        if not romp:
            notes.append(f'{c} {w}: образа нет'); continue
        vb = V(romp); vt = vb.volt(); ver, ents = vb.vmap()
        if not vt or not ents:
            notes.append(f'{c} {w}: таблицы напряжений или карты нет (volt {vt and vt.get("ver")}, vmap {ver})'); continue
        for r in rs:
            if 'error' in r:
                notes.append(f'{c} {w} запись {r["trace"]}: ошибка чтения'); continue
            sp = r['speedo'].get('0214a8') if int(c[2:], 16) >= 0xd7 else r['speedo'].get('0212cc')
            sp = sp if sp is not None else (r['speedo'].get('0214a8') or r['speedo'].get('0212cc'))
            temps = r['temps']
            def temp_at(t):
                cur = None
                for tt, v in temps:
                    if tt > t: break
                    cur = v
                return cur if cur is not None else (temps[0][1] if temps else 50)
            nv = collections.OrderedDict()
            if vt['type'] == 'PWM':
                for t, div, duty in r['pwm']:
                    if not div: continue
                    d = duty & 0x7fffffff
                    nv.setdefault((vt['base'] + vt['pwm_range'] * d // div, div, d), temp_at(t))
            else:
                for t, g in r['vid']:
                    pass                                        # GPIO-платы Kepler: в этом проходе не разбираются
            if not nv:
                notes.append(f'{c} {w} запись {r["trace"]}: напряжений NVIDIA не видно (тип {vt["type"]}, ШИМ записей {len(r["pwm"])}, VID {len(r["vid"])})'); continue
            if sp is None:
                notes.append(f'{c} {w} запись {r["trace"]}: метки качества в записи нет'); continue
            nouv_div = 27648000 // vt['pwm_freq'] if vt.get('pwm_freq') else None
            for (uv, div, duty), temp in nv.items():
                hits = []
                for i, e in enumerate(ents):
                    p = vmap_uv(ver, ents, i, sp, temp)
                    if p is None: continue
                    dd = -(-(p - vt['base']) * div // vt['pwm_range']) if p >= vt['base'] else 0   # DIV_ROUND_UP, как nouveau
                    if dd == duty:
                        hits.append(f"#{i}/р{e['mode']}")
                ok = bool(hits)
                tot[ok] += 1
                lines.append(f"{c} {w} запись {r['trace']}: NVIDIA {uv} мкВ (делитель {div}{'' if div == nouv_div else f' ≠ nouveau {nouv_div}'}, заполнение {duty}, "
                             f"t {temp}°C, speedo {sp}) → {'объясняют ' + ' '.join(hits[:6]) if ok else 'НЕ объяснено'}")
    print(f'напряжений NVIDIA (различных на запись): объяснено расчётом nouveau {tot[True]}, не объяснено {tot[False]}')
    for l in lines: print('  ', l)
    print('замечания:'); [print('  ', n) for n in notes]

if __name__ == '__main__':
    a = sys.argv[1:]
    if a and a[0] == 'scan':
        lo, hi = (int(a[2], 16), int(a[3], 16)) if len(a) >= 4 else (0xc0, 0x1ff)
        scan(a[1], lo, hi)
    elif a and a[0] == 'report':
        report(a[1])
    else:
        print(open(__file__).read().split('\nimport')[0]); sys.exit(1)
