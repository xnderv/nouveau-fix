#!/usr/bin/env python3
# РЕГИСТРЫ ЛИНИЙ РАЗДЕЛОВ ПАМЯТИ 0x11x620 / 0x11x628 / 0x11x630 (25.11): что в них держит драйвер NVIDIA и что оставляют
# таблицы VBIOS. Повод: тестировщик на GT 630M (GF108, DDR3) нашёл, что порча данных на 896 МГц уходит, если поставить в
# них значения NVIDIA. Правило из открытого кода (nouveau fb/ramgt215.c, GT21x: 0x100760 / 0x1007a0 / 0x1007e0, маска
# 0x22222222, порог 750 МГц): выше порога бит 1 каждой тетрады снят.
# Для каждой записи печатается: ремешок памяти, значения VBIOS для этого ремешка (то, что оставляет инициализация по
# таблицам, она же devinit у nouveau), что читает и пишет хост, что пишут скрипты памяти; для записей --extra — сверка
# «NVIDIA = VBIOS со снятым битом 1».
# Только чтение; участники обезличены, пути не печатаются.
#   python3 -I lab/db-fbpa-750.py [ОПИСЬ] [БАЗА] [--type DDR3|GDDR5] [--extra МЕТКА=ЗАПИСЬ[.xz],СКРИПТЫ.json,ОБРАЗ.rom ...]
import sys, os, json, subprocess, collections, importlib.util
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE); sys.path.insert(0, os.path.join(os.path.dirname(HERE), 'tools'))
def load(name):
    sp = importlib.util.spec_from_file_location(name.replace('-', '_'), os.path.join(HERE, name + '.py')); m = importlib.util.module_from_spec(sp)
    sp.loader.exec_module(m); return m
mg = load('memgen2')
argv = sys.argv[1:]; extra = []; TYPE = 'DDR3'
while '--extra' in argv:
    i = argv.index('--extra'); k, v = argv[i + 1].split('=', 1); extra.append((k, v.split(','))); del argv[i:i + 2]
if '--type' in argv:
    i = argv.index('--type'); TYPE = argv[i + 1]; del argv[i:i + 2]
OUT = argv[0] if argv else os.path.expanduser('~/Home/nouveau-archive/mem-survey')
DB = argv[1] if len(argv) > 1 else os.path.expanduser('~/Home/nouveau-archive/nouveau_vbios_trace')
REG3 = (0x620, 0x628, 0x630)                                   # три регистра правила; 0x624 / 0x62c / 0x634 — для полноты
OFFS = [p * 0x1000 + 0x110000 + o for p in range(4) for o in (0x620, 0x624, 0x628, 0x62c, 0x630, 0x634)]


def opener(path):
    return ['xz', '-dc', path] if path.endswith('.xz') else ['bzip2', '-dc', path] if path.endswith('.bz2') else \
           ['gzip', '-dc', path] if path.endswith('.gz') else ['cat', path]


def bar0_of(path):
    p = subprocess.Popen(opener(path), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, errors='replace'); b = None
    for l in p.stdout:
        f = l.split()
        if l.startswith('PCIDEV') and len(f) > 4 and f[2].startswith('10de') and int(f[1], 16) % 0x100 == 0: b = int(f[4], 16) & ~0xf; break
        if l.startswith(('R ', 'W ')): break
    p.kill(); return b


def scan(path, bar0):   # обращения хоста: (время, R/W, адрес, значение); ремешок — из чтений 0x101000
    pat = '|'.join(f'0x{bar0 + o:x} ' for o in OFFS + [0x101000])
    p1 = subprocess.Popen(opener(path), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    p2 = subprocess.Popen(['grep', '-aE', pat], stdin=p1.stdout, stdout=subprocess.PIPE, text=True, errors='replace'); p1.stdout.close()
    ev = []; strap = collections.Counter()
    for l in p2.stdout:
        f = l.split()
        if len(f) < 6 or f[0] not in ('R', 'W'): continue
        try: t, a, v = float(f[2]), int(f[4], 16) - bar0, int(f[5], 16)
        except ValueError: continue
        if a == 0x101000:
            if f[0] == 'R': strap[(v >> 2) & 0xf] += 1
        else: ev.append((t, f[0], a, v))
    p2.wait(); return ev, (strap.most_common(1)[0][0] if strap else None)


def script_writes(scripts):   # записи скриптов в наши регистры; оба формата: опись базы и JSON от lab/trace-memscr.py
    out = []
    for i, s in enumerate(scripts):
        for op in s.get('ops', []):
            if op[0] == 'WR' and op[1] in OFFS: out.append((i, op[1], op[2]))
            elif op[0] == 0x21:
                a = op[1]
                out += [(i, a[k], a[k + 1]) for k in range(0, len(a) - 1, 2) if a[k] in OFFS]
    return out


def fmt(vals):
    return ' '.join(f'{v:08x}' if v is not None else '—' for v in vals)


def report(lab, chip, typ, ev, sw, nscr, strap, rom):
    print(f'== {lab} {chip} {typ}: скриптов памяти {nscr}, ремешок {strap if strap is not None else "?"}')
    vb = None
    if rom and strap is not None:
        try: vb = mg.Vbios(rom, strap)
        except Exception as e: print('   образ VBIOS не разобран:', type(e).__name__)
    parts = sorted({(a - 0x110000) >> 12 for _, _, a, _ in ev} | {(a - 0x110000) >> 12 for _, a, _ in sw}) or [0]
    for p in parts:
        base = 0x110000 + p * 0x1000; regs = [base + o for o in REG3]
        line = f'   раздел {p} (0x{regs[0]:06x} / 0x{regs[1]:06x} / 0x{regs[2]:06x}):'
        if vb: line += f' VBIOS {fmt([vb.devinit.get(a) for a in regs])};'
        hr = [sorted({v for _, op, a, v in ev if op == 'R' and a == r}) for r in regs]
        hw = [sorted({v for _, op, a, v in ev if op == 'W' and a == r}) for r in regs]
        ss = [sorted({v for _, a, v in sw if a == r}) for r in regs]
        line += ' хост читает ' + ' / '.join(','.join(f'{v:08x}' for v in x) or '—' for x in hr) + ';'
        if any(hw): line += ' хост пишет ' + ' / '.join(','.join(f'{v:08x}' for v in x) or '—' for x in hw) + ';'
        line += ' скрипты пишут ' + (' / '.join(','.join(f'{v:08x}' for v in x) or '—' for x in ss) if any(ss) else 'ничего')
        print(line)
        if vb and all(a in vb.devinit for a in regs) and all(len(x) == 1 for x in hr) and not any(ss) and not any(hw):
            want = [(vb.devinit.get(a) or 0) & ~0x22222222 & 0xffffffff for a in regs]; got = [x[0] for x in hr]
            diff = [f'0x{a:06x}' for a in regs if (vb.devinit.get(a) or 0) & 0x22222222]
            print(f'      NVIDIA = VBIOS со снятым битом 1 каждой тетрады: {"да" if want == got else "НЕТ"} ({fmt(want)}); '
                  f'после инициализации по VBIOS бит 1 стоит в: {", ".join(diff) if diff else "нигде — правка не нужна"}')


S = json.load(open(os.path.join(OUT, 'scripts.json'))); inv = json.load(open(os.path.join(OUT, 'inventory.json')))
key = json.load(open(os.path.join(OUT, 'inventory-key.json')))
touched = collections.Counter()
for lab in sorted(S, key=lambda x: (S[x].get('chip', ''), x)):
    e = S[lab]; chip = e.get('chip', '')
    if not chip.startswith(('nvc', 'nvd9')) or e.get('type') != TYPE: continue
    path = os.path.join(DB, key[lab].split(':')[0]); b = inv[lab]['bar0']; b = int(b, 16) if isinstance(b, str) else b
    try: ev, strap = scan(path, b)
    except Exception as ex: print(lab, 'запись не прочитана:', type(ex).__name__); continue
    if strap is None and inv[lab].get('strap'): strap = (int(inv[lab]['strap'][0], 16) >> 2) & 0xf
    d = os.path.dirname(path)
    roms = [os.path.join(d, x) for x in sorted(os.listdir(d)) if not x.endswith('.eml') and (x.lower().endswith(('.rom', '.bin')) or 'vbios' in x.lower())]
    sw = script_writes(e.get('scripts', []))
    touched['пишут' if sw or any(op == 'W' for _, op, _, _ in ev) else 'только читают' if ev else 'не трогают'] += 1
    report(lab, chip, e.get('type'), ev, sw, len(e.get('scripts', [])), strap, roms[0] if roms else None)
print(f'записей {TYPE} в базе: {sum(touched.values())}; {dict(touched)}')
for lab, (trace, scr, rom) in extra:
    b = bar0_of(trace)
    if b is None: print(lab, 'BAR0 не найден'); continue
    ev, strap = scan(trace, b); scripts = json.load(open(scr))
    report(lab, 'GF108', 'DDR3 (запись тестировщика)', ev, script_writes(scripts), len(scripts), strap, rom)
    st = sorted(s['t'] for s in scripts)
    rt = sorted({round(t, 1) for t, op, _, _ in ev if op == 'R'})
    print(f'      чтения хоста — в моменты {", ".join(f"{t:.1f}" for t in rt)} с; пуски скриптов — {", ".join(f"{t:.1f}" for t in st)} с')
