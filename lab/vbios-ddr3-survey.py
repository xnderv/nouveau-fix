#!/usr/bin/env python3
# DDR3 ПО ОБРАЗАМ VBIOS FERMI: как на разных платах устроены таблицы памяти DDR3 — диапазоны частот, режим задержек
# (числа из VBIOS или автоматика), выключение DLL памяти, таблица обучения линий. Отвечает на вопросы «одинаково ли это
# у всех плат» и «нужна ли кому-то из них процедура обучения» (тип 5 в таблице M0205, как в nouveau fb/ramgt215.c).
# Образ считается DDR3-вариантом, если в таблице типов памяти M0203 есть ремешок с типом 1 (DDR3); берутся все такие
# варианты образа. Только чтение файлов; образы базы записей печатаются метками «чип#номер», пути не выводятся.
#   python3 -I lab/vbios-ddr3-survey.py КАТАЛОГ_ИЛИ_ОБРАЗ [...] [--db КАТАЛОГ_БАЗЫ_ЗАПИСЕЙ] [--list]
import sys, os, struct, hashlib, collections, importlib.util
HERE = os.path.dirname(os.path.abspath(__file__))
def load(name):
    sp = importlib.util.spec_from_file_location(name.replace('-', '_'), os.path.join(HERE, name + '.py')); m = importlib.util.module_from_spec(sp)
    sp.loader.exec_module(m); return m
mg = load('memgen2')
args = sys.argv[1:]; LIST = '--list' in args; db = None
if '--db' in args: i = args.index('--db'); db = args[i + 1]; del args[i:i + 2]
args = [a for a in args if not a.startswith('--')]
VER = {'70.00': 'GF100', '70.04': 'GF104', '70.06': 'GF106', '70.08': 'GF108', '70.10': 'GF110', '70.24': 'GF114',
       '70.26': 'GF116', '75.17': 'GF117', '75.19': 'GF119', '70.19': 'GF119', '70.17': 'GF117'}


def version(b):
    """строка версии из таблицы BIT 'i' (5 байт)"""
    bit = b.find(b'\xff\xb8BIT')
    if bit < 0: return None
    n, esz = b[bit + 10], b[bit + 9]
    for i in range(n):
        e = bit + 12 + i * esz
        if b[e] == ord('i'):
            off = struct.unpack_from('<H', b, e + 4)[0]
            if off + 5 <= len(b): return '%02x.%02x.%02x.%02x.%02x' % (b[off + 3], b[off + 2], b[off + 1], b[off], b[off + 4])
    return None


def mtables(vb):
    """M0203: {сырой ремешок: тип}; M0205: (частота обучения, {номер варианта: тип})"""
    rom = vb.rom; r8, r16 = rom.r8, rom.r16
    ver, ln, off = rom.ent['M']; off = rom.A(off); types = {}; train = (None, {})
    if ver == 2 and ln >= 5:
        t = r16(off + 3)
        if t:
            t = rom.A(t)
            if r8(t) == 0x10:
                hdr, el, cnt = r8(t + 1), r8(t + 2), r8(t + 3)
                for i in range(cnt):
                    e = r8(t + hdr + i * el); types.setdefault(e >> 4, e & 0x0f)
    if ver == 2 and ln >= 7:
        t = r16(off + 5)
        if t:
            t = rom.A(t)
            if r8(t) == 0x10:
                hdr, el, cnt, snr, ssz = r8(t + 1), r8(t + 2), r8(t + 3), r8(t + 4), r8(t + 5)
                tt = {i: r8(t + hdr + i * (el + snr * ssz)) & 0x0f for i in range(cnt)}
                train = (r16(t + 6), tt)
    return types, train


files = []
for a in args:
    if os.path.isdir(a):
        for d, _, fs in os.walk(a):
            for f in sorted(fs):
                if f.lower().endswith(('.rom', '.bin')): files.append((None, os.path.join(d, f)))
    else: files.append((None, a))
if db:
    import json
    OUT = os.path.expanduser('~/Home/nouveau-archive/mem-survey')
    key = json.load(open(os.path.join(OUT, 'inventory-key.json'))); inv = json.load(open(os.path.join(OUT, 'inventory.json')))
    for lab, k in sorted(key.items()):
        if inv[lab]['gen'] != 'Fermi': continue
        d = os.path.dirname(os.path.join(db, k.split(':')[0]))
        for x in sorted(os.listdir(d)):
            if not x.endswith('.eml') and (x.lower().endswith(('.rom', '.bin')) or 'vbios' in x.lower()): files.append((lab, os.path.join(d, x)))

seen = set(); rows = []; skipped = collections.Counter()
for lab, p in files:
    try: b = open(p, 'rb').read()
    except OSError: continue
    h = hashlib.sha1(b).hexdigest()
    if h in seen: skipped['повтор того же файла'] += 1; continue
    seen.add(h)
    v = version(b); chip = VER.get((v or '')[:5])
    if chip is None: skipped['не Fermi или версия не распознана'] += 1; continue
    try:
        vb0 = mg.Vbios(p, 0); types, train = mtables(vb0)
    except Exception as e:
        skipped['таблицы не разобраны: ' + type(e).__name__] += 1; continue
    if vb0.b[vb0.rammap] != 0x10: skipped['таблица диапазонов не версии 0x10'] += 1; continue
    ddr3 = sorted(s for s, t in types.items() if t == 1)
    if not ddr3: skipped['нет вариантов DDR3 (' + chip + ')'] += 1; continue
    idxs = set()
    for s in ddr3:
        try: idxs.add(mg.ramcfg_index(vb0.rom, s))
        except Exception: pass
    for idx in sorted(idxs):
        try: vb = mg.Vbios(p, idx)
        except Exception: continue
        r16 = vb.rom.r16; rng = []
        for i in range(vb.rc):
            e = vb.rammap + vb.rh + i * (vb.rl + vb.rn * vb.rs)
            M = vb.b[e:e + vb.rl]; R = vb.b[e + vb.rl + idx * vb.rs:e + vb.rl + (idx + 1) * vb.rs]
            if len(R) < 3 or R[1] == 0xff: continue
            rng.append((r16(e), r16(e + 2), bool(M[4] & 8), bool(R[2] & 0x40), R[2], M[4]))
        if not rng: continue
        # тип данных обучения — в первой записи таблицы M0205 (у всех просмотренных образов запись одна)
        rows.append(dict(label=lab or os.path.basename(p), chip=chip, ver=v, idx=idx, rng=rng, tfreq=train[0], ttype=train[1].get(0)))

print(f'образов просмотрено: {len(seen)}; вариантов DDR3 найдено: {len(rows)} в {len({r["label"] for r in rows})} образах')
print('пропущено:', dict(skipped))
by = collections.defaultdict(list)
for r in rows: by[r['chip']].append(r)
print('\n| чип | вариантов DDR3 | диапазоны частот (сколько вариантов) | числа ниже порога, автоматика выше | DLL выключена только в нижнем диапазоне | обучение по таблице (тип 5) |')
print('|---|---|---|---|---|---|')
for chip in sorted(by):
    rs = by[chip]; shapes = collections.Counter(tuple((lo, hi) for lo, hi, *_ in r['rng']) for r in rs)
    num = collections.Counter()
    for r in rs:
        flags = [n for lo, hi, n, d, r2, m4 in r['rng']]
        top = r['rng'][-1]
        num['да' if all(flags[:-1]) and not flags[-1] and len(flags) > 1 else ('числа везде' if all(flags) else ('автоматика везде' if not any(flags) else 'иначе'))] += 1
    dll = collections.Counter()
    for r in rs:
        d = [x[3] for x in r['rng']]
        dll['да' if d[0] and not any(d[1:]) else ('нигде не выключена' if not any(d) else 'иначе')] += 1
    tr = collections.Counter('есть: тип 5, %d МГц' % r['tfreq'] if r['ttype'] == 5 and r['tfreq'] else ('тип 5, частота 0' if r['ttype'] == 5 else ('нет (тип %#x, частота %s)' % (r['ttype'], r['tfreq']) if r['ttype'] is not None else 'таблицы нет')) for r in rs)
    print(f"| {chip} | {len(rs)} | {'; '.join(' / '.join(f'{lo}–{hi}' for lo, hi in s) + f' ({n})' for s, n in shapes.most_common(4))} | "
          f"{dict(num)} | {dict(dll)} | {dict(tr)} |")
if LIST:
    print()
    for r in rows:
        print(f"{r['chip']} {r['label']} вариант {r['idx']} версия {r['ver']}: " + '; '.join(f"{lo}–{hi}: {'числа' if n else 'автоматика'}{', DLL выкл' if d else ''} (байт 2 ramcfg {r2:#04x}, байт 4 диапазона {m4:#04x})" for lo, hi, n, d, r2, m4 in r['rng']) +
              f"; обучение: тип {r['ttype']}, {r['tfreq']} МГц")
