#!/usr/bin/env python3
# ПРЕДСКАЗАНИЕ ТАКТОВ ЯДРА ПО VBIOS (30.10): что выставит наш лабораторный драйвер на каждом уровне чужой карты Fermi, и что
# на ней выставляла NVIDIA (по её записи mmiotrace). Перенос логики nouveau + наших ключей из nvkm/subdev/clk/gf100.c (calc_clk,
# calc_src, calc_div, calc_pll, lab_gpc_div, lab_pmu_div, lab_pll_ref при lab_gpc_seq&8), gt215_pll_calc (clk/pllgt215.c) и
# nvbios_pll_parse (bios/pll.c, таблица PLL версий 0x40/0x50) — класс Г. Только чтение файлов.
#   python3 -I lab/core-predict.py predict ОБРАЗ.rom [--vco 1620000] [--ref 405000] [--flag]  — расчёт драйвера по уровням
#       (--flag: путь по флагу таблицы уровней — флаг 1 и свой PLL → PLL; гипотеза 30.10 по записи Q0AL)
#   python3 -I lab/core-predict.py trace ЗАПИСЬ.mmiotrace[.xz]                     — что ставила NVIDIA (различные состояния)
# Ключи драйвера — как в нашей рабочей сессии: lab_gpc_div=1, lab_pmu_div=1, lab_gpc_seq=13 (бит 3: опора PLL узлов 3..7
# через делитель опоры). VCO (SPPLL) и опора PLL берутся из записи, если её дать (--from-trace), иначе 1620 / 405 МГц.
import os, struct, sys, importlib.util

DOM = [(0x00, 'gpc', 3), (0x01, 'rop', 4), (0x02, 'hubk07', 11), (0x07, 'hubk06', 0), (0x08, 'hubk01', 1),
       (0x09, 'copy', 2), (0x0c, 'pmu', 10), (0x0e, 'vdec', 6)]   # idx узла, имя, номер подзаписи в уровне VBIOS

class Rom:
    def __init__(self, path):
        self.b = open(path, 'rb').read()
        b = self.b
        bit = b.find(b'\xff\xb8BIT')
        n, esz = b[bit + 10], b[bit + 9]
        self.ent = {}
        for i in range(n):
            e = bit + 12 + i * esz
            self.ent[chr(b[e])] = (b[e + 1], self.r16(e + 2), self.r16(e + 4))
    def r8(self, o): return self.b[o]
    def r16(self, o): return struct.unpack_from('<H', self.b, o)[0]
    def r32(self, o): return struct.unpack_from('<I', self.b, o)[0]

    def levels(self):
        """{уровень: {номер подзаписи: частота кГц}} из таблицы уровней (BIT P, версия 0x40)."""
        ver, ln, off = self.ent['P']
        p = self.r16(off + 0) if ver == 2 else None
        hdr, rlen, ssz, snr, cnt = self.r8(p + 1), self.r8(p + 2), self.r8(p + 3), self.r8(p + 4), self.r8(p + 5)
        out = {}
        for i in range(cnt):
            e = p + hdr + i * (rlen + ssz * snr)
            lv = self.r8(e)
            if lv == 0xff:
                continue
            sub, flag = {}, {}
            for s in range(snr):
                v = self.r16(e + rlen + s * ssz)
                sub[s] = (v & 0x3fff) * 1000
                flag[s] = v >> 14                                # биты 14–15: 2 на 03/07, 1 на 0f (nouveau отбрасывает)
            out[lv] = {'sub': sub, 'flag': flag, 'volt': self.r8(e + 2)}
        return out

    def pll(self, reg):
        """Пределы PLL по адресу (nvbios_pll_parse): только версии таблицы 0x40 и 0x50."""
        ver_c, ln, off = self.ent['C']
        data = self.r32(off) if ver_c == 2 else self.r16(off + 8)
        ver, hdr, ln, cnt = self.r8(data), self.r8(data + 1), self.r8(data + 2), self.r8(data + 3)
        d = data + hdr
        for _ in range(cnt):
            if self.r32(d + 3) == reg:
                break
            d += ln
        else:
            return None
        if ver == 0x40:
            refclk = self.r16(d + 9) * 1000
            q = self.r16(d + 1)
            return dict(ver=ver, refclk=refclk, min_freq=self.r16(q) * 1000, max_freq=self.r16(q + 2) * 1000,
                        min_in=self.r16(q + 4) * 1000, max_in=self.r16(q + 6) * 1000, min_m=self.r8(q + 8),
                        max_m=self.r8(q + 9), min_n=self.r8(q + 10), max_n=self.r8(q + 11), min_p=self.r8(q + 12),
                        max_p=self.r8(q + 13))
        raise SystemExit(f'таблица PLL версии {ver:#x} не разобрана')

def gt215_pll_calc(lim, refclk, freq, largest_m=False):
    P = lim['max_freq'] // freq
    P = max(min(P, lim['max_p']), lim['min_p'])
    lM = max((refclk + lim['max_in']) // lim['max_in'], lim['min_m'])
    hM = min((refclk + lim['min_in']) // lim['min_in'], lim['max_m'])
    lM = min(lM, hM)
    best = None
    for M in range(lM, hM + 1):
        tmp = freq * P * M
        N, fN = tmp // refclk, tmp % refclk
        if fN >= refclk // 2:
            N += 1
        if N < lim['min_n']:
            continue
        if N > lim['max_n']:
            break
        err = abs(freq - (refclk * N // M // P))
        if best is None or err < best[0] or (largest_m and err == best[0]):   # largest_m: как NVIDIA 304+/390 у GPC
            best = (err, N, M)
    if best is None:
        return 0, None
    _, N, M = best
    return refclk * N // M // P, (P << 16) | (N << 8) | M

def calc_div(ref, freq):
    div = max(min((ref * 2) // freq, 65), 2)
    return (ref * 2) // div, div - 2

def calc(rom, idx, freq, vco, ref, hub06=None, flag=None):
    """(частота, путь, подробности) как calc_clk лабораторного драйвера с ключами рабочей сессии. flag — гипотеза 30.10
    (--flag): узел с флагом 1 в таблице уровней, у которого есть свой PLL (или PLL hubk06 у hubk01), идёт на PLL всегда."""
    if idx == 0x00 and freq <= vco // 2:                       # lab_gpc_div=1
        clk0, d1 = calc_div((vco * 2) // 4, freq)
        return clk0, 'делитель', f'ddiv 80000202 mdiv {0x80000000 | d1 if d1 else 0:08x}'
    if idx == 0x0c:                                              # lab_pmu_div=1
        div = min((vco * 2 + freq // 2) // freq, 65)
        return (vco * 2) // div, 'делитель', f'mdiv {0x80000000 | (div - 2) << 8 | (div - 2):08x}'
    if freq in (27000, 108000, 100000):
        return freq, 'фикс', ''
    clk0, div0 = calc_div(vco, freq)                             # calc_src (idx < 7) или VCO (idx >= 7)
    if idx < 7:
        clk0, d1 = calc_div(clk0, freq)
        info0 = f'ddiv {0x80000000 | div0 << 8 | div0:08x}' + (f' mdiv {0x80000000 | d1:08x}' if d1 else '')
    else:
        clk0, d1 = calc_div(vco, freq)
        info0 = f'mdiv {0x80000000 | d1:08x}' if d1 else ''
    clk1, info1 = 0, ''
    force_pll = flag == 1 and idx in (0x00, 0x01, 0x02, 0x07, 0x08)
    if (clk0 != freq or force_pll) and (0x4387 & (1 << idx)):
        if idx <= 7:
            lim = rom.pll(0x137000 + idx * 0x20 if idx < 7 else 0x1370e0)
            clk1, coef = gt215_pll_calc(lim, ref, freq, largest_m=(flag is not None and idx == 0x00)) if lim else (0, None)
            info1 = f'coef {coef:08x}' if coef else ''
        else:
            clk1 = hub06 or 0
        if clk1:
            clk1, d1p = calc_div(clk1, freq)
            if d1p:
                info1 += f' mdiv {0x80000000 | d1p << 8:08x}'
    if abs(freq - clk0) <= abs(freq - clk1) and not (force_pll and clk1):
        return clk0, 'делитель', info0
    return clk1, 'PLL', info1.strip()

def predict(path, vco=1620000, ref=405000, use_flag=False):
    rom = Rom(path)
    for lv, e in sorted(rom.levels().items()):
        print(f'уровень {lv:02x} (индекс напряжения {e["volt"]}):')
        hub06 = None
        for idx, name, s in DOM:
            f = e['sub'].get(s, 0)
            if not f:
                continue
            if idx == 0x07:
                hub06 = f          # hubk01 берёт PLL hubk06 по его целевой частоте (lab_override(0x07, домен hubk06))
            fl = e['flag'].get(s)
            got, path_, info = calc(rom, idx, f, vco, ref, hub06, fl if use_flag else None)
            print(f'  {name:7s} флаг {fl} хочет {f:8d} кГц → {got:8d} ({path_}{", " + info if info else ""})')

def trace(path):
    """Различные состояния узлов ядра в записи NVIDIA: путь (делитель/PLL), коэффициенты, делители, итоговая частота."""
    spec = importlib.util.spec_from_file_location('tv', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'trace-vbios.py'))
    tv = importlib.util.module_from_spec(spec); spec.loader.exec_module(tv)
    regs = {}
    seen = {}
    bar = None
    order = []
    def st(a):
        return regs.get(a, 0)
    def freq_of(idx, vco, ref):
        sel = st(0x137100) & (1 << idx)
        sctl = st(0x137250 + idx * 4)
        if sel:
            p = 0x137000 + idx * 0x20 if idx < 7 else 0x1370e0
            c = st(p + 4)
            P, N, M = (c >> 16) & 0x3f, (c >> 8) & 0xff, c & 0xff
            src = ref * N // M // P if M and P else 0
            sdiv = ((sctl >> 8) & 0x3f) + 2
            desc = f'PLL coef {c:08x}'
        else:
            dsrc, dctl = st(0x137160 + idx * 4), st(0x1371d0 + idx * 4)
            src = vco if (dsrc & 3) == 3 else (27000 if (dsrc & 3) == 0 else 0)
            if (dsrc & 3) == 3 and idx <= 2 and dctl & 0x80000000:
                src = vco * 2 // (((dctl >> 8 if dsrc & 0x100 else dctl) & 0x3f) + 2)
            sdiv = (sctl & 0x3f) + 2
            desc = f'делитель ddiv {dctl:08x}'
        out = src * 2 // sdiv if sctl & 0x80000000 else src
        return out, desc + (f' mdiv {sctl:08x}' if sctl & 0x80000000 else '')
    for raw in tv.stream(path):
        if raw.startswith(b'MAP '):
            f = raw.split()
            if bar is None and len(f) > 5 and int(f[5], 16) == 0x1000000:
                bar = int(f[3], 16)
            continue
        if bar is None or not (raw.startswith(b'W ') or raw.startswith(b'R ')):
            continue
        f = raw.split()
        a, v = int(f[4], 16) - bar, int(f[5], 16)
        if not (0x137000 <= a < 0x137400 or a in (0x00e800, 0x00e804, 0x00e820, 0x00e824)):
            continue
        if raw[0] == ord('R') and a in regs:
            continue
        regs[a] = v
        if raw[0] != ord('W'):
            continue
        c = st(0x00e804)
        vco = 27000 * ((c >> 8) & 0xff) // (c & 0xff) if c & 0xff else 1620000
        for idx, name, _ in DOM:
            r = st(0x137140 + min(idx, 7) * 4)                   # опора PLL узла: 0x137140 + idx·4 (hubk06 — 0x13715c)
            ref = vco * 2 // ((r & 0x3f) + 2) if r & 0x80000000 else vco
            fr, desc = freq_of(idx, vco, ref)
            k = (name, fr, desc)
            if k not in seen:
                seen[k] = float(f[2]); order.append(k)
    print(f'VCO {vco} кГц, опора PLL {ref} кГц (из записи)')
    for name in [d[1] for d in DOM]:
        print(f'{name}:')
        for k in order:
            if k[0] == name:
                print(f'  {k[1]:8d} кГц  {k[2]}   (впервые {seen[k]:.3f} с)')

if __name__ == '__main__':
    a = sys.argv[1:]
    if a and a[0] == 'predict':
        kw = {}
        if '--vco' in a: kw['vco'] = int(a[a.index('--vco') + 1])
        if '--ref' in a: kw['ref'] = int(a[a.index('--ref') + 1])
        kw['use_flag'] = '--flag' in a
        predict(a[1], **kw)
    elif a and a[0] == 'trace':
        trace(a[1])
    else:
        print(open(__file__).read().split('\nimport')[0]); sys.exit(1)
