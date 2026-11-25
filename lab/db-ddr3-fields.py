#!/usr/bin/env python3
# КАРТА ПОЛЕЙ DDR3 У FERMI: проверка правил «поле таблиц VBIOS -> биты регистра» на всех записях DDR3 поколения Fermi
# (GF108, GF119) базы и на записях тестировщиков. Правила взяты из открытого кода: тайминги и управляющие биты — ветка
# Р. Сплита kernel-nouveau-nv50-pm (2017, путь GDDR5 для Fermi), регистры режима MR0–MR2 — nouveau fb/sddr3.c и стандарт
# DDR3, задержки числами — nouveau fb/ramgt215.c; правила с пометкой «М» найдены этим же инструментом (--explain).
# Для каждого скрипта подбирается запись диапазона частот VBIOS (по регистру таймингов 0x10f290, при равных — по частоте
# PLL из скрипта), затем каждое правило сверяется с последним значением, которое скрипт пишет в регистр.
# Только чтение; участники обезличены, пути не печатаются.
#   python3 -I lab/db-ddr3-fields.py [ОПИСЬ] [БАЗА] [--extra МЕТКА=СКРИПТЫ.json,ОБРАЗ.rom,РЕМЕШОК ...] [режимы]
# --extra: запись вне базы (JSON от lab/trace-memscr.py, образ VBIOS, сырой ремешок — биты 2–5 регистра 0x101000).
# Режимы: --detail — строка на каждое несовпадение; --dump — байты таблиц и значения регистров по скриптам;
#   --explain — для каждого бита, который меняется и не покрыт правилом: какими битами таблиц VBIOS он объясняется на всех
#   записях сразу, либо он постоянен для платы (и совпадает ли с состоянием после POST из init-скриптов VBIOS).
import sys, os, json, collections, importlib.util
HERE = os.path.dirname(os.path.abspath(__file__))
def load(name):
    sp = importlib.util.spec_from_file_location(name.replace('-', '_'), os.path.join(HERE, name + '.py')); m = importlib.util.module_from_spec(sp)
    sp.loader.exec_module(m); return m
mg = load('memgen2')
argv = sys.argv[1:]; extra = []
while '--extra' in argv:
    i = argv.index('--extra'); k, v = argv[i + 1].split('=', 1); extra.append((k, v.split(','))); del argv[i:i + 2]
DETAIL = '--detail' in argv; DUMP = '--dump' in argv; EXPLAIN = '--explain' in argv
argv = [a for a in argv if not a.startswith('--')]
OUT = argv[0] if argv else os.path.expanduser('~/Home/nouveau-archive/mem-survey')
DB = argv[1] if len(argv) > 1 else os.path.expanduser('~/Home/nouveau-archive/nouveau_vbios_trace')
S = json.load(open(os.path.join(OUT, 'scripts.json'))); inv = json.load(open(os.path.join(OUT, 'inventory.json')))
key = json.load(open(os.path.join(OUT, 'inventory-key.json')))
CHIP = {'nvc1': 'GF108', 'nvd9': 'GF119'}

CLX = {5: 2, 6: 4, 7: 6, 8: 8, 9: 10, 10: 12, 11: 14, 12: 1, 13: 3, 14: 5}       # задержка чтения -> код MR0 (A6 A5 A4 A2)
WRX = {5: 1, 6: 2, 7: 3, 8: 4, 10: 5, 12: 6, 14: 7, 15: 7, 16: 0}               # восстановление записи -> код MR0
CWLX = {5: 0, 6: 1, 7: 2, 8: 3, 9: 4, 10: 5}                                    # задержка записи -> код MR2
DREG = [0x10f200, 0x10f224, 0x10f294, 0x10f298, 0x10f29c, 0x10f2a0, 0x10f300, 0x10f304, 0x10f320, 0x10f604, 0x10f610, 0x10f614,
        0x10f658, 0x10f660, 0x10f808, 0x10f824, 0x10f830, 0x10f870, 0x10f874, 0x10f910, 0x10f914, 0x1373ec, 0x1373f8, 0x132018,
        0x100c00, 0x137360, 0x132004, 0x10f324, 0x10f60c, 0x10f618, 0x10f668, 0x10fe20, 0x10fe24, 0x110620, 0x110628, 0x110630,
        0x111620, 0x111628, 0x111630, 0x137310, 0x132000]


def roms(lab):
    d = os.path.dirname(os.path.join(DB, key[lab].split(':')[0]))
    return [os.path.join(d, x) for x in sorted(os.listdir(d)) if not x.endswith('.eml') and (x.lower().endswith(('.rom', '.bin')) or 'vbios' in x.lower())]


def words_to_ops(w):
    out = []; i = 0
    while i < len(w):
        h = w[i]; n = h >> 16
        if n == 0: break
        out.append([h & 0xffff, w[i + 1:i + n]]); i += n
    return out


def writes(ops):
    out = []
    for op, a in ops:
        if op == 0x21: out += [(a[i], a[i + 1]) for i in range(0, len(a) - 1, 2)]
    return out


def entries(vb):
    """записи диапазонов частот: (нижняя, верхняя МГц, T, R, M)"""
    r16 = vb.rom.r16; out = []
    for i in range(vb.rc):
        e = vb.rammap + vb.rh + i * (vb.rl + vb.rn * vb.rs)
        M = vb.b[e:e + vb.rl]; R = vb.b[e + vb.rl + vb.strap * vb.rs:e + vb.rl + (vb.strap + 1) * vb.rs]
        T = vb.b[vb.timing + vb.th + R[1] * vb.tl:vb.timing + vb.th + (R[1] + 1) * vb.tl] if R[1] != 0xff else None
        out.append((r16(e), r16(e + 2), T, R, M))
    return out


def t290(T): return T[9] << 24 | T[7] << 17 | T[5] << 8 | T[3]


def pll_mhz(W):
    """частота PLL памяти, если скрипт пишет её коэффициенты (опора 405 МГц или по делителю опоры из скрипта)"""
    c = W.get(0x132004)
    if c is None or not (c & 0xff) or not ((c >> 16) & 0x3f): return None
    r = W.get(0x137330); ref = 405.0
    if r is not None and (r & 0x80000000): ref = 3240.0 / ((r & 0x3f) + 2)
    return ref * ((c >> 8) & 0xff) / (c & 0xff) / ((c >> 16) & 0x3f)


def pick(vb, W):
    """запись диапазона для скрипта: по таймингам (если однозначно), при равных — по частоте PLL; запасной путь — частота"""
    E = entries(vb); mhz = pll_mhz(W)
    v = W.get(0x10f290)
    cand = [e for e in E if e[2] is not None and v is not None and t290(e[2]) == v]
    byf = [e for e in E if mhz is not None and e[0] <= round(mhz) <= e[1]]
    if len(cand) == 1: return cand[0], 'тайминги'
    if len(cand) > 1:
        both = [e for e in cand if e in byf]
        if both: return both[0], 'тайминги + частота PLL %d МГц' % round(mhz)
        return cand[0], 'тайминги (подходит %d записей, взята первая)' % len(cand)
    if byf: return byf[0], 'частота PLL %d МГц' % round(mhz)
    return None, 'запись диапазона не найдена'


def bit(x): return 1 if x else 0
# правило: (регистр, маска поля, имя, источник, чипы или None, функция(T, R, M, vb) -> ожидаемое значение поля или None)
RULES = [
    (0x10f290, 0xffffffff, 'RP, RAS, RFC, RC — четыре тайминга строк', 'С17', None, lambda T, R, M, vb: t290(T)),
    (0x10f294, 0x0000007f, 'CL — задержка чтения (минус 1 при выключенной DLL памяти)', 'С17+СТ', None, lambda T, R, M, vb: T[2] - bit(R[2] & 0x40)),
    (0x10f294, 0x00003f80, 'CWL — задержка записи', 'С17', None, lambda T, R, M, vb: T[0x13] << 7 if vb.tl > 0x13 else None),
    (0x10f294, 0x000fc000, 'RCDRD', 'С17', None, lambda T, R, M, vb: T[0xa] << 14),
    (0x10f294, 0x03f00000, 'RCDWR', 'С17', None, lambda T, R, M, vb: T[0xb] << 20),
    (0x10f298, 0x00ff0000, 'WR — восстановление после записи', 'С17', None, lambda T, R, M, vb: T[0] << 16),
    (0x10f298, 0x0000ff00, 'WTR', 'С17', None, lambda T, R, M, vb: T[1] << 8),
    (0x10f29c, 0x0000001f, 'XPDLL', 'С17', None, lambda T, R, M, vb: T[0xd] & 0x1f),
    (0x10f29c, 0x000001e0, 'CKE', 'С17', None, lambda T, R, M, vb: (T[0x15] << 5) & 0x1e0 if vb.tl > 0x15 else None),
    (0x10f29c, 0x0000fe00, 'FAW', 'С17', None, lambda T, R, M, vb: (T[0x14] << 9) & 0xfe00 if vb.tl > 0x14 else None),
    (0x10f2a0, 0x001f8000, 'RRD', 'С17', None, lambda T, R, M, vb: T[0xc] << 15),
    (0x10f224, 0x00ff0000, 'байт 0x12 записи таймингов', 'М', None, lambda T, R, M, vb: T[0x12] << 16 if vb.tl > 0x12 else None),
    (0x10f300, 0x00000074, 'MR0: код задержки чтения CL', 'СТ', None, lambda T, R, M, vb: ((CLX[T[2]] & 0xe) << 3 | (CLX[T[2]] & 1) << 2) if T[2] in CLX else None),
    (0x10f300, 0x00000e00, 'MR0: код восстановления после записи WR', 'СТ', None, lambda T, R, M, vb: (WRX[T[0]] << 9) if T[0] in WRX else None),
    (0x10f304, 0x00000001, 'MR1: DLL памяти выключена (ramcfg байт 2, бит 6)', 'СТ', None, lambda T, R, M, vb: bit(R[2] & 0x40)),
    (0x10f304, 0x00000244, 'MR1: согласование линий ODT (тайминги, байт 0xe)', 'СТ', None, lambda T, R, M, vb: (T[0xe] & 1) << 2 | (T[0xe] & 2) << 5 | (T[0xe] & 4) << 7),
    (0x10f320, 0x00000038, 'MR2: код задержки записи CWL', 'СТ', None, lambda T, R, M, vb: (CWLX[T[0x13]] << 3) if vb.tl > 0x13 and T[0x13] in CWLX else None),
    (0x10f658, 0xffffffff, 'задержки линий числами: ramcfg байты 5, 6 (0, если бит 3 байта 4 диапазона снят)', 'GT', None, lambda T, R, M, vb: (R[6] << 16 | R[5] << 8 | R[5]) if M[4] & 8 else 0),
    (0x10f660, 0xffffffff, 'задержки линий числами: ramcfg байты 7, 8', 'GT', None, lambda T, R, M, vb: (R[8] << 8 | R[7]) if M[4] & 8 else None),
    (0x10f870, 0xffffffff, 'ramcfg байт 13, младшая тетрада × 0x11111111', 'С17', None, lambda T, R, M, vb: (R[0xd] & 0xf) * 0x11111111 if vb.rs > 0xd else None),
    (0x1373ec, 0x00020000, 'бит 17 = не (ramcfg байт 2, бит 4)', 'С17', None, lambda T, R, M, vb: bit(not R[2] & 0x10) << 17),
    (0x1373f8, 0x00000001, 'бит 0 = ramcfg байт 2, бит 0', 'С17', None, lambda T, R, M, vb: R[2] & 1),
    (0x1373f8, 0x00000004, 'бит 2 = ramcfg байт 2, бит 0 (у GF119 всегда 1)', 'С17', ('nvc1',), lambda T, R, M, vb: (R[2] & 1) << 2),
    (0x10f604, 0xf0000000, 'ramcfg байт 2, бит 5 -> 0xf', 'С17', None, lambda T, R, M, vb: 0xf0000000 if R[2] & 0x20 else 0),
    (0x10f604, 0x01000000, 'бит 24 = не (ramcfg байт 2, бит 2)', 'С17', None, lambda T, R, M, vb: bit(not R[2] & 4) << 24),
    (0x10f610, 0x00000100, 'бит 8 = ramcfg байт 2, бит 1', 'С17', None, lambda T, R, M, vb: bit(R[2] & 2) << 8),
    (0x10f614, 0x00000100, 'бит 8 = ramcfg байт 2, бит 0', 'С17', None, lambda T, R, M, vb: bit(R[2] & 1) << 8),
    (0x10f610, 0xf0000000, 'биты 28–31 = байт 0x18 записи таймингов', 'С17', None, lambda T, R, M, vb: (T[0x18] & 0xf) << 28 if vb.tl > 0x18 and T[0x18] != 0xff else None),
    (0x10f614, 0xf0000000, 'биты 28–31 = байт 0x18 записи таймингов', 'С17', None, lambda T, R, M, vb: (T[0x18] & 0xf) << 28 if vb.tl > 0x18 and T[0x18] != 0xff else None),
    (0x10f808, 0x12800000, 'биты 23, 25, 28 = не (ramcfg байт 2, бит 2) — у GT21x то же в 0x111100', 'GT', None, lambda T, R, M, vb: 0 if R[2] & 4 else 0x12800000),
    (0x10f808, 0x00000004, 'бит 2 = ramcfg байт 2, бит 2 — у GT21x то же', 'GT', None, lambda T, R, M, vb: R[2] & 4),
    (0x10f808, 0x08000000, 'бит 27 = ramcfg байт 2, бит 4 — у GT21x то же', 'GT', None, lambda T, R, M, vb: bit(R[2] & 0x10) << 27),
    (0x10f808, 0x04000000, 'бит 26 = не (ramcfg байт 2, бит 4) — у GT21x то же', 'GT', None, lambda T, R, M, vb: bit(not R[2] & 0x10) << 26),
    (0x10f808, 0x00100000, 'бит 20 = не (ramcfg байт 2, бит 3)', 'М', None, lambda T, R, M, vb: bit(not R[2] & 8) << 20),
    (0x10f668, 0xffffffff, '0x80000000 + ramcfg байт 9 (две тетрады) и байт 3 (младшая) — формула GT21x для 0x10f804', 'GT', None,
     lambda T, R, M, vb: 0x80000000 | (R[9] >> 4) << 20 | (R[3] & 0xf) << 16 | (R[9] & 0xf)),
    (0x10f618, 0xffffffff, 'ramcfg байт 3, младшая тетрада × 0x11111111', 'М', None, lambda T, R, M, vb: (R[3] & 0xf) * 0x11111111),
    (0x10f200, 0x00001000, 'бит 12 = не (ramcfg байт 2, бит 3) — у GF119 правило неполное', 'С17', ('nvc1',), lambda T, R, M, vb: bit(not R[2] & 8) << 12),
]
FRULES = [   # правила, которым нужна частота цели: функция(x) от строки скрипта
    (0x132018, 0x10000000, 'бит 28 = частота не выше 750 МГц — у GT21x то же в 0x004018 (GF119: частота из скрипта не восстановлена)', 'GT', ('nvc1',), lambda x: bit(x['mhz'] <= 750) << 28 if x['mhz'] else None),
    (0x132018, 0x00004000, 'бит 14 = верхний диапазон (выше 450 МГц)', 'М', None, lambda x: bit(x['rng'][0] > 450) << 14),
    (0x10f830, 0x00000006, 'биты 1–2 = частота не выше 500 МГц — у GT21x то же в 0x100700 (только NVA3)', 'GT', ('nvc1',), lambda x: (6 if x['mhz'] <= 500 else 0) if x['mhz'] else None),
    (0x110620, 0x22222222, 'бит 1 каждой тетрады = частота не выше 750 МГц — у GT21x то же в 0x100760', 'GT', ('nvc1',), lambda x: (0x22222222 if x['mhz'] <= 750 else 0) if x['mhz'] else None),
    (0x110628, 0x22222222, 'то же', 'GT', ('nvc1',), lambda x: (0x22222222 if x['mhz'] <= 750 else 0) if x['mhz'] else None),
    (0x110630, 0x22222222, 'то же', 'GT', ('nvc1',), lambda x: (0x22222222 if x['mhz'] <= 750 else 0) if x['mhz'] else None),
    (0x10f874, 0x04000000, 'бит 26 = задержки числами (бит 3 байта 4 диапазона)', 'М', None, lambda x: bit(x['M'][4] & 8) << 26),
    (0x10f910, 0x00002000, 'бит 13 = не (задержки числами) — у GT21x то же в 0x10053c, бит 12', 'GT', None, lambda x: bit(not x['M'][4] & 8) << 13),
    (0x10f914, 0x00002000, 'то же', 'GT', None, lambda x: bit(not x['M'][4] & 8) << 13),
    (0x10f824, 0x00006000, 'биты 13–14 = нижние диапазоны (до 450 МГц)', 'М', None, lambda x: 0x6000 if x['rng'][1] <= 450 else 0),
]
RULES = [(r, m, n, sr, ch, (lambda x, fn=fn: fn(x['T'], x['R'], x['M'], x['vb']))) for r, m, n, sr, ch, fn in RULES] + FRULES
SRC = {'С17': 'открытая ветка Сплита 2017 (путь GDDR5 для Fermi)', 'С17+СТ': 'она же + стандарт DDR3 (режим без DLL)',
       'СТ': 'стандарт DDR3 + nouveau fb/sddr3.c', 'GT': 'nouveau fb/ramgt215.c (DDR3 у GT21x, 2014)', 'М': 'найдено этим инструментом (--explain)'}

recs = []
for lab, d in sorted(S.items()):
    if d['gen'] != 'Fermi' or d['type'] != 'DDR3' or not d['scripts']: continue
    rs = roms(lab); raw = {(int(s, 16) >> 2) & 0xf for s in inv[lab]['strap']}
    if len(rs) != 1 or len(raw) != 1: print(f'{lab}: пропуск (образов {len(rs)}, ремешков {len(raw)})'); continue
    recs.append((lab, d['chip'], rs[0], raw.pop(), [s['ops'] for s in d['scripts']]))
for lab, (scr, rom, raw) in extra:
    J = json.load(open(scr)); recs.append((lab, 'nvc1', rom, int(raw, 0), [words_to_ops(s['words']) for s in J]))

stat = collections.OrderedDict((i, dict(ok=0, bad=0, na=0, recs=set(), badrecs=collections.Counter(), ex=[])) for i in range(len(RULES)))
rows = []        # по одному на (запись, уникальный скрипт): dict(lab, chip, rng, T, R, M, W, vb)
summary = []
for lab, chip, rom, raw, scripts in recs:
    try:
        vb0 = mg.Vbios(rom, 0); idx = mg.ramcfg_index(vb0.rom, raw); vb = mg.Vbios(rom, idx)
    except Exception as e:
        print(f'{lab}: VBIOS не разобран ({type(e).__name__})'); continue
    if vb.b[vb.rammap] != 0x10: print(f'{lab}: таблица диапазонов версии {vb.b[vb.rammap]:#x} — не Fermi-формат, пропуск'); continue
    seen = set(); nscr = 0; nfound = 0; lv = collections.Counter()
    for ops in scripts:
        wl = writes(ops); sig = tuple(wl)
        if sig in seen or len(wl) < 20: continue
        seen.add(sig); nscr += 1; W = dict(wl)
        ent, how = pick(vb, W)
        if ent is None: lv['?'] += 1; continue
        nfound += 1; lo, hi, T, R, M = ent; lv[f'{lo}–{hi}'] += 1
        x = dict(lab=lab, chip=chip, rng=(lo, hi), T=T, R=R, M=M, W=W, vb=vb, how=how, mhz=pll_mhz(W)); rows.append(x)
        if DUMP:
            print(f'## {lab} {chip} диапазон {lo}–{hi} ({how}); записей {len(wl)}; PLL {round(x["mhz"]) if x["mhz"] else "—"} МГц')
            print('   M', M.hex(' '), '| R', R.hex(' '), '| T', T.hex(' ') if T else '-')
            print('   ' + '  '.join(f'{r & 0xfffff:05x}={W[r]:08x}' for r in DREG if r in W))
        for i, (reg, mask, nm, src, chips, fn) in enumerate(RULES):
            st = stat[i]
            if reg not in W or T is None or (chips and chip not in chips): st['na'] += 1; continue
            try: exp = fn(x)
            except (IndexError, KeyError): exp = None
            if exp is None: st['na'] += 1; continue
            got = W[reg] & mask
            if got == (exp & mask): st['ok'] += 1; st['recs'].add(lab)
            else:
                st['bad'] += 1; st['badrecs'][lab] += 1
                if len(st['ex']) < 40: st['ex'].append(f'{lab} диапазон {lo}–{hi} ({how}): в скрипте {got:#x}, по VBIOS {exp & mask:#x}')
    summary.append((lab, chip, idx, nscr, nfound, dict(lv), vb.tl, vb.rs, vb.rl))

print('| запись | чип | вариант ramcfg | уникальных скриптов | диапазон найден | по диапазонам | длина записи таймингов / ramcfg / диапазона |')
print('|---|---|---|---|---|---|---|')
for lab, chip, idx, n, nf, lv, tl, rs, rl in summary:
    print(f'| {lab} | {CHIP.get(chip, chip)} | {idx} | {n} | {nf} | {lv} | {tl} / {rs} / {rl} |')
print('\n| регистр | биты | поле | источник | сошлось (скриптов) | плат, где сошлось | не сошлось | нет в скрипте |')
print('|---|---|---|---|---|---|---|---|')
for i, (reg, mask, nm, src, chips, fn) in enumerate(RULES):
    st = stat[i]
    bad = f"{st['bad']} ({', '.join(f'{k}×{v}' for k, v in st['badrecs'].items())})" if st['bad'] else '0'
    print(f"| 0x{reg:06x} | {mask:#010x} | {nm} | {src} | {st['ok']} | {len(st['recs'])} | {bad} | {st['na']} |")
print('\nИсточники: ' + '; '.join(f'{k} — {v}' for k, v in SRC.items()))
if DETAIL:
    print('\nНесовпадения:')
    for i, st in stat.items():
        for x in st['ex']: print(f'- 0x{RULES[i][0]:06x} {RULES[i][2]}: {x}')

if EXPLAIN:
    cov = collections.defaultdict(int)
    for reg, mask, nm, src, chips, fn in RULES: cov[reg] |= mask
    # предикторы: каждый бит байтов M[4..8], R[2..13], признаки «верхний диапазон», «нижний диапазон»
    def preds(x):
        p = {}
        for k in range(4, 9):
            for b in range(8): p[f'диапазон байт {k} бит {b}'] = (x['M'][k] >> b) & 1
        for k in range(2, len(x['R'])):
            for b in range(8): p[f'ramcfg байт {k} бит {b}'] = (x['R'][k] >> b) & 1
        p['верхний диапазон (выше 450 МГц)'] = bit(x['rng'][0] > 450)
        p['нижний диапазон (до 162 МГц)'] = bit(x['rng'][1] <= 162)
        return p
    P = [preds(x) for x in rows]
    regs = sorted({r for x in rows for r in x['W']})
    print('\n| регистр | плат | меняется | покрыто правилами | остаток: бит -> чем объясняется |')
    print('|---|---|---|---|---|')
    for r in regs:
        xs = [(x, p) for x, p in zip(rows, P) if r in x['W']]
        vals = [x['W'][r] for x, _ in xs]
        OR = 0; AND = 0xffffffff
        for v in vals: OR |= v; AND &= v
        var = OR & ~AND & 0xffffffff; rest = var & ~cov[r] & 0xffffffff
        notes = []
        for b in range(32):
            if not (rest >> b) & 1: continue
            vec = [(v >> b) & 1 for v in vals]
            # постоянен внутри каждой платы?
            per = collections.defaultdict(set)
            for (x, _), v in zip(xs, vec): per[x['lab']].add(v)
            if all(len(s) == 1 for s in per.values()):
                # совпадает с состоянием после POST?
                dv = [(x['vb'].devinit.get(r), v) for (x, _), v in zip(xs, vec)]
                have = [(d, v) for d, v in dv if d is not None]
                eq = sum(1 for d, v in have if (d >> b) & 1 == v)
                notes.append(f'{b}: постоянная платы' + (f' (= POST в {eq} из {len(have)})' if have else ' (в init-скриптах VBIOS регистра нет)'))
                continue
            hit = []
            for name in P[0]:
                pv = [p[name] for _, p in xs]
                if pv == vec: hit.append(name)
                elif [1 - q for q in pv] == vec: hit.append('не ' + name)
            # по чипам отдельно, если общего объяснения нет
            if not hit:
                for ch in sorted({x['chip'] for x, _ in xs}):
                    sub = [(p, v) for (x, p), v in zip(xs, vec) if x['chip'] == ch]
                    sv = [v for _, v in sub]
                    if len(set(sv)) == 1: hit.append(f'{CHIP.get(ch, ch)}: всегда {sv[0]}'); continue
                    hh = [n for n in P[0] if [p[n] for p, _ in sub] == sv] + ['не ' + n for n in P[0] if [1 - p[n] for p, _ in sub] == sv]
                    hit.append(f'{CHIP.get(ch, ch)}: ' + (' | '.join(hh[:4]) if hh else 'не объяснён'))
            notes.append(f'{b}: ' + (' | '.join(hit[:5]) + (f' … всего {len(hit)}' if len(hit) > 5 else '') if hit else 'не объяснён'))
        print(f"| 0x{r:06x} | {len({x['lab'] for x, _ in xs})} | {var:#010x} | {var & cov[r]:#010x} | {'; '.join(notes) if notes else '—'} |")
