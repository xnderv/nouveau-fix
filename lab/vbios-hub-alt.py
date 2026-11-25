#!/usr/bin/env python3
# HUB2CLK по образам VBIOS Fermi: где правило драйвера «флаг → делитель → PLL» (±2 %) в число VBIOS не попадает и что даёт
# обходной путь «HUB2CLK от PLL XBAR2CLK» (источник: код 2, подвыбор 7) в трёх вариантах условия:
#   А — как в драйвере сейчас: только если VBIOS при загрузке сам поставил подвыбор 7 и число хаба = числу XBAR2CLK;
#   Б — без условия загрузки (правка тестировщика, GT 630M): число хаба = числу XBAR2CLK, XBAR2CLK на своей PLL;
#   В — шире: PLL XBAR2CLK ÷ пост-делитель (1; 1,5; 2; …), если так попадаем в ±2 %.
# Расчёт повторяет lab_calc_vbios (nvkm/subdev/clk/gf100.c лабораторного драйвера): SPPLL 1620 МГц, пост-делитель с шагом 0,5,
# запрет «выше VBIOS + 2 %». Подвыбор при загрузке — из init-скрипта образа (lab/vbios-devinit.py). Только чтение файлов.
#   python3 -I lab/vbios-hub-alt.py КАТАЛОГ_ИЛИ_ОБРАЗ [...] [--db КАТАЛОГ_БАЗЫ_ЗАПИСЕЙ] [--list]
# Образы базы записей печатаются метками «чип#номер», пути не выводятся.
import sys, os, struct, glob, hashlib, collections, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
VCO = 1620000
CHIP = {'nvc0': 'GF100', 'nvc4': 'GF104', 'nvc3': 'GF106', 'nvc1': 'GF108', 'nvc8': 'GF110', 'nvce': 'GF114', 'nvcf': 'GF116',
        'nvd7': 'GF117', 'nvd9': 'GF119'}
SUB = {'sys': 0, 'hub': 1, 'xbar': 11}


def hit(want, got):
    return bool(got) and got + want // 50 >= want and got <= want + want // 50


def in_window(want, got):
    d = want - got
    return -2000 <= d < 3000


def calc_div(ref, freq):
    div = max(min((ref * 2) // freq, 65), 2)
    return (ref * 2) // div, div - 2


def below(pre, freq, d):
    """запрет «выше VBIOS + 2 %»: ближайший делитель снизу"""
    while d < 63 and (pre * 2) // (d + 2) > freq + freq // 50:
        d += 1
    return (pre * 2) // (d + 2)


def div_path(idx, freq):
    if freq in (27000, 108000, 100000):
        return freq
    pre = VCO
    if idx < 7:
        pre, _ = calc_div(VCO, freq)
    clk0, d = calc_div(pre, freq)
    if clk0 > freq + freq // 50:
        clk0 = below(pre, freq, d)
    return clk0


def choose(flag, freq, clk0, clk1):
    """(частота, на PLL?) по правилу драйвера: путь по флагу; мимо ±2 % — другой путь, если он попадает"""
    if flag == 1:
        use_pll = clk1 != 0
    elif flag == 2:
        use_pll = False
    else:
        use_pll = bool(clk1) and not in_window(freq, clk0)
    got = clk1 if use_pll else clk0
    if not hit(freq, got):
        if use_pll and hit(freq, clk0):
            use_pll, got = False, clk0
        elif not use_pll and hit(freq, clk1):
            use_pll, got = True, clk1
    return got, use_pll


class Rom:
    def __init__(self, b):
        self.b = b
        bit = b.find(b'\xff\xb8BIT')
        if bit < 0:
            raise ValueError('нет BIT')
        n, esz = b[bit + 10], b[bit + 9]
        self.ent = {}
        for i in range(n):
            e = bit + 12 + i * esz
            self.ent[chr(b[e])] = (b[e + 1], self.r16(e + 2), self.r16(e + 4))

    def r8(self, o): return self.b[o]
    def r16(self, o): return struct.unpack_from('<H', self.b, o)[0]

    def version(self):
        _, _, off = self.ent['i']
        return '%02x.%02x.%02x.%02x.%02x' % (self.b[off + 3], self.b[off + 2], self.b[off + 1], self.b[off + 0], self.b[off + 4])

    def levels(self):
        ver, ln, off = self.ent['P']
        p = self.r16(off)
        if not p or self.r8(p) != 0x40:
            raise ValueError('таблица уровней не 0x40')
        hdr, rlen, ssz, snr, cnt = self.r8(p + 1), self.r8(p + 2), self.r8(p + 3), self.r8(p + 4), self.r8(p + 5)
        out = {}
        for i in range(cnt):
            e = p + hdr + i * (rlen + ssz * snr)
            lv = self.r8(e)
            if lv == 0xff:
                continue
            d = {}
            for name, s in SUB.items():
                if s < snr:
                    v = self.r16(e + rlen + s * ssz)
                    d[name] = ((v & 0x3fff) * 1000, v >> 14)
            out[lv] = d
        return out


def boot_sub(path):
    """подвыбор источника HUB2CLK (биты 24–26 регистра 0x137180) после init-скрипта VBIOS; None — скрипт регистр не пишет"""
    r = subprocess.run([sys.executable, '-I', os.path.join(HERE, 'vbios-devinit.py'), '--text', path, '--range', '0x137180-0x137184'],
                       capture_output=True, text=True).stdout
    val = None
    for ln in r.splitlines():
        if '137180 =' in ln:
            f = ln.split('137180 =')[1].split()
            v = int(f[0], 16)
            mask = int(f[2], 16) if len(f) > 2 and f[1] == 'mask' else 0
            val = ((val or 0) & mask) | v
    return None if val is None else (val >> 24) & 7


def evaluate(lv):
    """по одному уровню: (число хаба, флаг, результат без обходного пути, XBAR на PLL?, число XBAR, результат варианта В)"""
    fh, flh = lv['hub']
    fs, fls = lv.get('sys', (0, 0))
    fx, flx = lv.get('xbar', (0, 0))
    # SYS2CLK на PLL на этом уровне (lab_hub06_pll)
    sys_pll = fls == 1 or (fls == 0 and fs and not in_window(fs, calc_div(VCO, fs)[0]))
    clk0 = div_path(8, fh)
    clk1 = calc_div(fs, fh)[0] if (sys_pll and fs) else 0
    got, _ = choose(flh, fh, clk0, clk1)
    # XBAR2CLK: свой PLL (считаем, что PLL в число попадает), делитель в две ступени
    xgot, xpll = (0, False)
    if fx:
        xgot, xpll = choose(flx, fx, div_path(2, fx), fx)
    alt = 0
    if fx and xpll:
        a = 0
        while a < 63 and (fx * 2) // (a + 2) > fh + fh // 50:
            a += 1
        alt = (fx * 2) // (a + 2)
    return fh, flh, got, xpll, fx, alt, fs, fls


def main():
    args = sys.argv[1:]
    show = '--list' in args
    if show: args.remove('--list')
    db = None
    if '--db' in args:
        i = args.index('--db'); db = args[i + 1]; del args[i:i + 2]
    files = []
    for a in args:
        if os.path.isdir(a):
            for p in sorted(glob.glob(os.path.join(a, '**', '*.rom'), recursive=True)):
                files.append((os.path.basename(p), p, None))
        else:
            files.append((os.path.basename(a), a, None))
    if db:
        for c, chip in CHIP.items():
            for k, p in enumerate(sorted(glob.glob(os.path.join(db, c, '**', '*.rom'), recursive=True)), 1):
                files.append((f'{chip}#{k}', p, chip))
    seen, roms = set(), []
    for label, p, chip in files:
        b = open(p, 'rb').read()
        h = hashlib.sha256(b).hexdigest()
        if h in seen:
            continue
        seen.add(h)
        try:
            r = Rom(b); lv = r.levels(); ver = r.version()
        except Exception as e:
            continue
        roms.append(dict(label=label, path=p, chip=chip, ver=ver, lv=lv))
    # чип по второму байту версии VBIOS: таблица из образов базы (каталог = чип) и известных кодов
    vmap = {'00': 'GF100', '04': 'GF104', '06': 'GF106', '08': 'GF108', '10': 'GF110', '24': 'GF114', '26': 'GF116',
            '17': 'GF117', '19': 'GF119'}
    for r in roms:
        if r['chip']:
            vmap.setdefault(r['ver'][3:5], r['chip'])
    for r in roms:
        r['chip'] = r['chip'] or vmap.get(r['ver'][3:5], 'чип ' + r['ver'][:5])
    print(f'образов Fermi с таблицей уровней: {len(roms)}; по чипам: ' +
          ', '.join(f'{c} {n}' for c, n in sorted(collections.Counter(r["chip"] for r in roms).items())))
    rows = []
    for r in roms:
        need = False
        for lvl, d in sorted(r['lv'].items()):
            if 'hub' not in d or not d['hub'][0]:
                continue
            fh, flh, got, xpll, fx, alt, fs, fls = evaluate(d)
            rows.append(dict(r=r, lvl=lvl, fh=fh, flh=flh, got=got, xpll=xpll, fx=fx, alt=alt, fs=fs, fls=fls))
            need = need or not hit(fh, got)
        r['need'] = need
    # подвыбор при загрузке — считаем для всех образов (нужен и как статистика по чипам)
    for r in roms:
        r['sub'] = boot_sub(r['path'])
    print('\nподвыбор источника HUB2CLK после init-скрипта VBIOS (7 = провод к PLL XBAR2CLK), образов по чипам:')
    by = collections.defaultdict(collections.Counter)
    for r in roms:
        by[r['chip']][r['sub']] += 1
    for c in sorted(by):
        print(f'  {c}: ' + ', '.join(f'подвыбор {k if k is not None else "не пишется"} — {n}' for k, n in sorted(by[c].items(), key=lambda x: str(x[0]))))

    def result(row, mode):
        fh, got = row['fh'], row['got']
        if hit(fh, got) or not mode:
            return got
        ok_boot = row['r']['sub'] == 7
        if mode == 'А' and ok_boot and row['xpll'] and hit(fh, row['fx']): return row['fx']
        if mode == 'Б' and row['xpll'] and hit(fh, row['fx']): return row['fx']
        if mode == 'В' and row['alt'] and hit(fh, row['alt']): return row['alt']
        return got

    def err(row, got):
        return (got - row['fh']) * 100.0 / row['fh']

    print(f'\nпар «образ, уровень» с числом HUB2CLK: {len(rows)}')
    bins = [(0.1, '≤ 0,1 %'), (0.5, '≤ 0,5 %'), (1, '≤ 1 %'), (2, '≤ 2 %'), (5, '2–5 %'), (10, '5–10 %'), (20, '10–20 %'), (1e9, '> 20 %')]
    print('\nошибка относительно числа VBIOS | без обходного пути | А (сейчас) | Б (без условия загрузки) | В (с пост-делителем)')
    for hi, name in bins:
        lo = ([0] + [b[0] for b in bins])[bins.index((hi, name))]
        cnt = []
        for mode in (None, 'А', 'Б', 'В'):
            cnt.append(sum(1 for row in rows if lo < abs(err(row, result(row, mode))) <= hi or (lo == 0 and err(row, result(row, mode)) == 0)))
        print(f'  {name:9s} | {cnt[0]:5d} | {cnt[1]:5d} | {cnt[2]:5d} | {cnt[3]:5d}')
    miss = [row for row in rows if not hit(row['fh'], row['got'])]
    print(f'\nмимо ±2 % без обходного пути: {len(miss)} пар в {len(set(id(m["r"]) for m in miss))} образах')
    grp = collections.defaultdict(list)
    for m in miss:
        grp[(m['r']['chip'], m['lvl'], m['fh'] // 1000, m['flh'], m['fx'] // 1000, m['xpll'], m['fs'] // 1000, m['fls'], m['got'] // 1000,
             m['r']['sub'], result(m, 'А') // 1000, result(m, 'Б') // 1000, result(m, 'В') // 1000)].append(m['r']['label'])
    print('чип | уровень | хаб VBIOS, МГц / флаг | XBAR2CLK, МГц (на PLL?) | SYS2CLK, МГц / флаг | подвыбор при загрузке | сейчас без пути → А / Б / В, МГц (ошибка) | образов')
    for k, labels in sorted(grp.items(), key=lambda x: (x[0][0], x[0][1], x[0][2])):
        chip, lvl, fh, flh, fx, xpll, fs, fls, got, sub, ra, rb, rc = k
        e = lambda g: f'{g} ({(g - fh) * 100.0 / fh:+.1f} %)'
        print(f'  {chip} | {lvl:02x} | {fh} / {flh} | {fx} ({"PLL" if xpll else "делитель"}) | {fs} / {fls} | {sub if sub is not None else "—"} | '
              f'{e(got)} → {e(ra)} / {e(rb)} / {e(rc)} | {len(labels)}' + (': ' + ', '.join(sorted(labels)[:6]) + (' …' if len(labels) > 6 else '') if show else ''))
    for mode in ('А', 'Б', 'В'):
        fixed = [m for m in miss if hit(m['fh'], result(m, mode))]
        print(f'вариант {mode}: исправляет {len(fixed)} пар из {len(miss)} (образов {len(set(id(m["r"]) for m in fixed))}); '
              f'чипы: ' + (', '.join(f'{c} {n}' for c, n in sorted(collections.Counter(m["r"]["chip"] for m in fixed).items())) or '—'))


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(open(__file__).read().split('\nimport')[0]); sys.exit(1)
    main()
