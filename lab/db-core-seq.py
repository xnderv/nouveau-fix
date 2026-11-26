#!/usr/bin/env python3
# ОБЗОР СМЕНЫ ТАКТОВ ЯДРА ПО БАЗЕ ЗАПИСЕЙ (25.11.2026): для каждой записи драйвера NVIDIA —
#   порядок, в котором узлы ядра переводятся на PLL и обратно на делитель (биты переключателя 0x137100);
#   глубина «скобок» замедления (0x020160 — GPC2CLK, 0x020164 — SYS2CLK) и что в этих регистрах стояло до первой записи
#   (состояние после init-скрипта VBIOS), а также 0x020130 и 0x020144;
#   трогает ли драйвер узел LTC2CLK (его PLL 0x137020/24, источник 0x137164, делители 0x1371d4 и 0x137254, бит 1
#   переключателя) и что в них стояло;
#   топология памяти (0x022438 — число разделов, 0x022554 — выключенные, 0x17e8dc), ремешок 0x101000.
# Шаг 1 — выборка из записей в закрытую опись core-seq.json (4 записи параллельно); шаг 2 — таблицы. Только чтение базы;
# участники обезличены (метки «чип#номер»), пути не печатаются.
#   python3 -I lab/db-core-seq.py [чипы через запятую = все Fermi] [ОПИСЬ_КАТАЛОГ] [БАЗА]
import sys, os, json, subprocess, collections, concurrent.futures

FERMI = ['nvc0', 'nvc1', 'nvc3', 'nvc4', 'nvc8', 'nvce', 'nvcf', 'nvd7', 'nvd9']
NAMES = {'nvc0': 'GF100', 'nvc1': 'GF108', 'nvc3': 'GF106', 'nvc4': 'GF104', 'nvc8': 'GF110', 'nvce': 'GF114', 'nvcf': 'GF116',
         'nvd7': 'GF117', 'nvd9': 'GF119', 'nve4': 'GK104', 'nve6': 'GK106', 'nve7': 'GK107', 'nvf0': 'GK110', 'nvf1': 'GK110B',
         'nv108': 'GK208', 'nv117': 'GM107', 'nv118': 'GM108', 'nv124': 'GM204'}
CH = sys.argv[1].split(',') if len(sys.argv) > 1 and sys.argv[1] else FERMI
OUT = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser('~/Home/nouveau-archive/mem-survey')
DB = sys.argv[3] if len(sys.argv) > 3 else os.path.expanduser('~/Home/nouveau-archive/nouveau_vbios_trace')
inv = json.load(open(os.path.join(OUT, 'inventory.json'))); key = json.load(open(os.path.join(OUT, 'inventory-key.json')))
CACHE = os.path.join(OUT, 'core-seq.json')
cache = json.load(open(CACHE)) if os.path.exists(CACHE) else {}

WR = [0x137100, 0x020160, 0x020164, 0x020180, 0x020184] + [0x137000 + i * 0x20 + k for i in (0, 1, 2, 7) for k in (0, 4)] \
     + [0x137160 + i * 4 for i in range(10)] + [0x1371d0 + i * 4 for i in range(10)] + [0x137250 + i * 4 for i in range(10)]
RD = [0x020160, 0x020164, 0x020130, 0x020144, 0x0201a0, 0x0201a4, 0x137020, 0x137024, 0x137164, 0x1371d4, 0x137254, 0x137100,
      0x022438, 0x022554, 0x17e8dc, 0x101000, 0x000000, 0x137180]


def opener(rel):
    f, _, mem = rel.partition(':'); p = os.path.join(DB, f)
    with open(p, 'rb') as h: m = h.read(6)
    if not mem: return ['xz', '-dc', p] if m.startswith(b'\xfd7zXZ') else ['cat', p]
    if m.startswith(b'\xfd7zXZ'): return ['tar', '-xOJf', p, mem]
    if m.startswith(b'BZh'): return ['tar', '-xOjf', p, mem]
    return ['sh', '-c', 'tar -xOzf "$0" "$1" | (xz -dc 2>/dev/null || cat)', p, mem]


def extract(lab):
    bar0 = int(inv[lab]['bar0'], 16)
    wa = {'0x%x' % (bar0 + r): r for r in WR}; ra = {'0x%x' % (bar0 + r): r for r in RD}
    prog = ('BEGIN{' + ''.join('W["%s"]=1;' % a for a in wa) + ''.join('R["%s"]=1;' % a for a in ra) + '} '
            'NF>=6 && $1=="W" && ($5 in W) {print "W",$3,$5,$6} NF>=6 && $1=="R" && ($5 in R) && !(s[$5]++) {print "R",$3,$5,$6}')
    p1 = subprocess.Popen(opener(key[lab]), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    p2 = subprocess.Popen(['mawk', prog], stdin=p1.stdout, stdout=subprocess.PIPE); p1.stdout.close()
    lines = p2.communicate()[0].split(b'\n'); p1.wait()
    w = []; first = {}
    for ln in lines:
        p = ln.split()
        if len(p) != 4: continue
        try:
            t = float(p[1]); v = int(p[3], 16)
            if p[0] == b'W': w.append([t, wa[p[2].decode()], v])
            else: first[ra[p[2].decode()]] = [t, v]
        except (ValueError, KeyError): pass
    return lab, dict(w=w, first={f'{a:06x}': x for a, x in first.items()})


todo = [l for l in sorted(inv) if inv[l].get('chip') in CH and l not in cache]
if todo:
    with concurrent.futures.ThreadPoolExecutor(4) as ex:
        for lab, d in ex.map(extract, todo):
            cache[lab] = d; json.dump(cache, open(CACHE, 'w'))
            print(f'  выбрано: {lab} ({len(d["w"])} записей в регистры тактов)', flush=True)


def analyse(d):
    w = d['w']; first = {int(a, 16): x for a, x in d['first'].items()}
    def boot(a):                       # значение до первой записи хоста в этот регистр
        fw = next((t for t, r, v in w if r == a), None); x = first.get(a)
        return x[1] if x and (fw is None or x[0] < fw) else None
    mux = boot(0x137100); groups = []; cur = []; last_t = None
    gpc = collections.Counter(); sys_ = collections.Counter(); ltc = collections.Counter(); hub = set()
    for t, r, v in w:
        if r == 0x137100:
            if mux is not None and mux != v:
                if cur and t - last_t > 0.05: groups.append(cur); cur = []
                for b in range(16):
                    if (mux ^ v) >> b & 1: cur.append((b, v >> b & 1))
                last_t = t
                if (mux ^ v) & 2: ltc['переключатель'] += 1
            mux = v
        elif r == 0x020160 and (v & 0x80) and (v >> 16) & 0x3f: gpc[(v >> 16) & 0x3f] += 1
        elif r == 0x020164 and (v >> 16) & 0x3f: sys_[(v >> 16) & 0x3f] += 1
        elif r in (0x137020, 0x137024): ltc['PLL'] += 1
        elif r == 0x137164: ltc['источник'] += 1
        elif r in (0x1371d4, 0x137254): ltc['делитель'] += 1
        elif r == 0x137180: hub.add(v & 0x07000103)
    if cur: groups.append(cur)
    up = collections.Counter(); dn = collections.Counter()
    for g in groups:
        u = ' '.join(str(b) for b, s in g if s); d_ = ' '.join(str(b) for b, s in g if not s)
        if u: up[u] += 1
        if d_: dn[d_] += 1
    return dict(up=up, dn=dn, gpc=gpc, sys=sys_, ltc=ltc, hub=hub, b160=boot(0x020160), b164=boot(0x020164), b130=boot(0x020130),
                b144=boot(0x020144), fbp=first.get(0x022438, [0, None])[1], fbpmask=first.get(0x022554, [0, None])[1],
                slices=first.get(0x17e8dc, [0, None])[1], strap=first.get(0x101000, [0, None])[1],
                ltc_pll=first.get(0x137020, [0, None])[1], ltc_src=first.get(0x137164, [0, None])[1], boot0=first.get(0, [0, None])[1])


def hx(v, n=8): return '—' if v is None else f'{v:0{n}x}'
def cnt(c, f=str): return ', '.join(f'{f(k)} × {v}' for k, v in sorted(c.items(), key=lambda x: -x[1])) or '—'
rows = [(l, inv[l]['chip'], analyse(cache[l])) for l in sorted(cache) if inv.get(l, {}).get('chip') in CH]
print('\n## Порядок перевода узлов (номера: 0 GPC2CLK, 1 LTC2CLK, 2 XBAR2CLK, 7 SYS2CLK, 8 HUB2CLK)')
print('| запись | чип | на PLL (подъём) | на делитель (спуск) |'); print('|---|---|---|---|')
for l, ch, a in rows:
    if a['up'] or a['dn']: print(f"| {l} | {NAMES.get(ch, ch)} | {cnt(a['up'])} | {cnt(a['dn'])} |")
print('\n## Глубина скобок и состояние после VBIOS')
print('| запись | чип | скобка GPC2CLK (делитель × раз) | скобка SYS2CLK | 0x020160 до скобок | 0x020164 до скобок | 0x020130 | 0x020144 | ремешок 0x101000 |')
print('|---|---|---|---|---|---|---|---|---|')
dv = lambda k: '/%g' % ((k + 2) / 2)
for l, ch, a in rows:
    print(f"| {l} | {NAMES.get(ch, ch)} | {cnt(a['gpc'], dv)} | {cnt(a['sys'], dv)} | {hx(a['b160'])} | {hx(a['b164'])} | {hx(a['b130'])} | {hx(a['b144'])} | {hx(a['strap'])} |")
print('\n## LTC2CLK и топология памяти')
print('| запись | чип | разделов 0x022438 | выключены 0x022554 | 0x17e8dc | записи в узел LTC2CLK | PLL LTC2CLK при первом чтении | источник LTC2CLK | источник HUB2CLK (записи) |')
print('|---|---|---|---|---|---|---|---|---|')
for l, ch, a in rows:
    print(f"| {l} | {NAMES.get(ch, ch)} | {hx(a['fbp'], 1)} | {hx(a['fbpmask'], 1)} | {hx(a['slices'])} | {cnt(a['ltc'])} | {hx(a['ltc_pll'])} | {hx(a['ltc_src'])} | {', '.join(f'{x:08x}' for x in sorted(a['hub'])) or '—'} |")
