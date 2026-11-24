#!/usr/bin/env python3
# ПОРЯДОК ШИНЫ XBAR2CLK И ПАМЯТИ У KEPLER И MAXWELL (24.11) — проверка гипотезы «правила топологии действуют сквозь
# поколения». Шаг 1 (один раз): из каждой трассы с полными скриптами памяти (с таймингами 0x10f290) выбираются записи
# хоста в переключатель источников 0x137100 и в регистры узла XBAR2CLK (PLL, её опора, путь делителя, выходной делитель);
# они складываются в закрытую опись xbar-events.json. Шаг 2: по биту 2 переключателя (1 — PLL, 0 — делитель) строятся
# события. Пара «на делитель и почти сразу обратно на PLL» — перенастройка PLL (узел на время уводят на делитель); её
# направление берётся из коэффициентов PLL и выходного делителя до и после. Остальные события — настоящие переходы:
# «на PLL» = подъём, «на делитель» = спуск. «Шина снаружи памяти» = на подъёме шина раньше скрипта памяти, на спуске —
# позже. Только чтение базы; участники обезличены.
#   python3 -I lab/db-xbar-order.py [чипы через запятую = все Kepler и Maxwell] [ОПИСЬ_КАТАЛОГ] [БАЗА]
#   PAIR_MS — порог пары «делитель → PLL» (20; провал гистограммы в выводе); WIN_MS — окно вокруг скрипта (60)
#   SHOW=метка — вместо таблиц лента событий одной трассы (FROM, TO — секунды от начала трассы)
#   ODD=0 — не печатать ленты случаев против порядка «шина снаружи» (для чипов Fermi, где обратный порядок — норма)
# Контроль инструмента: на Fermi (nvc0,nvc1,nvc3,nvc4,nvc8,nvce,nvcf,nvd7,nvd9) он повторяет известное деление без исключений.
import sys, os, json, subprocess, collections, concurrent.futures, bisect
CH = sys.argv[1].split(',') if len(sys.argv) > 1 and sys.argv[1] else ['nv108', 'nve4', 'nve6', 'nve7', 'nvf0', 'nvf1', 'nv117', 'nv118', 'nv124']
OUT = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser('~/Home/nouveau-archive/mem-survey')
DB = sys.argv[3] if len(sys.argv) > 3 else os.path.expanduser('~/Home/nouveau-archive/nouveau_vbios_trace')
PAIR = float(os.environ.get('PAIR_MS', '20')) / 1000; WIN = float(os.environ.get('WIN_MS', '60')) / 1000
MUX, PCTL, COEF, RSRC, RDIV, DSRC, DDIV, ODIV = 0x137100, 0x137040, 0x137044, 0x137128, 0x137148, 0x137168, 0x1371d8, 0x137258
REGS = (MUX, PCTL, COEF, RSRC, RDIV, DSRC, DDIV, ODIV)
NAME = {MUX: 'переключатель', PCTL: 'PLL управление', COEF: 'PLL коэффициенты', RSRC: 'опора PLL: источник', RDIV: 'опора PLL: делитель',
        DSRC: 'путь делителя: источник', DDIV: 'путь делителя: значение', ODIV: 'выходной делитель'}
inv = json.load(open(os.path.join(OUT, 'inventory.json'))); key = json.load(open(os.path.join(OUT, 'inventory-key.json')))
S = json.load(open(os.path.join(OUT, 'scripts.json')))
topo = json.load(open(os.path.join(OUT, 'topo.json'))) if os.path.exists(os.path.join(OUT, 'topo.json')) else {}
CACHE = os.path.join(OUT, 'xbar-events.json')
cache = json.load(open(CACHE)) if os.path.exists(CACHE) else {}
if cache.get('_regs') != list(REGS): cache = {'_regs': list(REGS), 'tr': {}}
tr = cache['tr']

def opener(rel):
    f, _, mem = rel.partition(':'); p = os.path.join(DB, f)
    with open(p, 'rb') as h: m = h.read(6)
    if not mem: return ['xz', '-dc', p] if m.startswith(b'\xfd7zXZ') else ['cat', p]
    if m.startswith(b'\xfd7zXZ'): return ['tar', '-xOJf', p, mem]
    if m.startswith(b'BZh'): return ['tar', '-xOjf', p, mem]
    return ['sh', '-c', 'tar -xOzf "$0" "$1" | (xz -dc 2>/dev/null || cat)', p, mem]

def extract(lab):
    """Записи хоста в REGS: [[время от первой записи трассы, смещение регистра, значение], ...]."""
    bar0 = int(inv[lab]['bar0'], 16); want = {'0x%x' % (bar0 + r): r for r in REGS}
    prog = 'BEGIN{' + ''.join('A["%s"]=1;' % a for a in want) + '} $1=="W" && NF>=6 { if(!f){print $3; f=1} if($5 in A) print $3,$5,$6 }'
    p1 = subprocess.Popen(opener(key[lab]), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    p2 = subprocess.Popen(['mawk', prog], stdin=p1.stdout, stdout=subprocess.PIPE); p1.stdout.close()
    lines = p2.communicate()[0].split(b'\n'); p1.wait()
    t0 = None; w = []
    for ln in lines:
        p = ln.split()
        try:
            if len(p) == 1 and t0 is None: t0 = float(p[0])
            elif len(p) == 3: w.append([round(float(p[0]) - t0, 6), want[p[1].decode()], int(p[2], 16)])
        except (ValueError, KeyError, TypeError): pass
    if any(r == MUX for _, r, _ in w): return lab, w, 'mawk'
    # запасной путь: адреса в трассе записаны иначе, чем '0x%x' — медленный разбор средствами Python
    t0 = None; w = []
    pr = subprocess.Popen(opener(key[lab]), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    for raw in pr.stdout:
        if raw[:2] != b'W ': continue
        p = raw.split()
        try: a = int(p[4], 16) - bar0; v = int(p[5], 16); t = float(p[2])
        except (ValueError, IndexError): continue
        if t0 is None: t0 = t
        if a in REGS: w.append([round(t - t0, 6), a, v])
    pr.stdout.close(); pr.wait()
    return lab, w, 'python'

def is_full(s):
    return any(op == 0x21 and any((a[i] & 0xfff) == 0x290 and a[i] >> 12 in (0x10f, 0x9a0) for i in range(0, len(a), 2)) for op, a in s['ops'])
labs = sorted(k for k, r in inv.items() if r['chip'] in CH and any(is_full(s) for s in S.get(k, {}).get('scripts', [])))
todo = [k for k in labs if k not in tr]
if todo:
    print(f'шаг 1: читаю {len(todo)} трасс (остальные {len(labs) - len(todo)} уже в описи)', file=sys.stderr)
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as ex:
        for lab, w, how in ex.map(extract, todo):
            tr[lab] = dict(chip=inv[lab]['chip'], w=w, how=how)
    print('  способ чтения: ' + ', '.join(f'{k} — {v}' for k, v in collections.Counter(tr[k]['how'] for k in todo).items()), file=sys.stderr)
    json.dump(cache, open(CACHE, 'w'))

def state_at(w, t):
    """Последние записанные значения регистров на момент t (то, чего трасса ещё не писала, неизвестно)."""
    st = {}
    for tt, r, v in w:
        if tt > t: break
        st[r] = v
    return st
def pll_rel(st):
    """Частота выхода PLL в долях опоры: N / (M × P), с выходным делителем, если он включён. None — неизвестно."""
    c = st.get(COEF)
    if c is None or not c & 0xff: return None
    f = ((c >> 8) & 0xff) / ((c & 0xff) * (((c >> 16) & 0x3f) or 1))
    o = st.get(ODIV)
    if o is not None and o & 0x80000000: f = f * 2 / (((o >> 8) & 0x3f) + 2)
    return f
def rdir(w, t1, t2):
    """Направление перенастройки PLL: сравнение частоты до ухода на делитель и после возврата."""
    a, b = state_at(w, t1 - 1e-6), state_at(w, t2 + 0.005)
    if any(a.get(r) != b.get(r) for r in (RSRC, RDIV)) or (ODIV in b) != (ODIV in a): return 'неизвестно'
    fa, fb = pll_rel(a), pll_rel(b)
    if fa is None or fb is None: return 'неизвестно'
    return 'та же частота' if abs(fb - fa) < 1e-9 else ('вверх' if fb > fa else 'вниз')

def timeline(lab, lo, hi):
    w = tr[lab]['w']; rows = [(t, f"{NAME[r]} = {v:#x}" + (f" (бит XBAR2CLK: {'PLL' if v & 4 else 'делитель'})" if r == MUX else '')) for t, r, v in w]
    rows += [(s['t'], 'СКРИПТ ПАМЯТИ ' + ('полный' if is_full(s) else 'без таймингов')) for s in S[lab]['scripts']]
    return [(t, x) for t, x in sorted(rows) if lo <= t <= hi]
if os.environ.get('SHOW'):
    lab = os.environ['SHOW']
    for t, x in timeline(lab, float(os.environ.get('FROM', '-1')), float(os.environ.get('TO', '1e9'))): print(f'{t:12.6f}  {x}')
    sys.exit(0)

def bucket(x, edges, names):
    for e, n in zip(edges, names):
        if x < e: return n
    return names[-1]
GE = (1e-4, 1e-3, 1e-2, 2e-2, 1e-1, 1, 10); GN = ('< 0,1 мс', '0,1–1 мс', '1–10 мс', '10–20 мс', '20–100 мс', '0,1–1 с', '1–10 с', '> 10 с')
DE = (1e-3, 5e-3, 2e-2, 6e-2, 0.2, 1); DN = ('< 1 мс', '1–5 мс', '5–20 мс', '20–60 мс', '60–200 мс', '0,2–1 с', '> 1 с')
gap_dp = collections.Counter(); gap_pd = collections.Counter(); dist = collections.Counter()
tot = collections.defaultdict(collections.Counter); ntr = collections.Counter(); odd = []
for lab in labs:
    ch = inv[lab]['chip']; ntr[ch] += 1; c = tot[ch]; w = tr[lab]['w']
    full = sorted(s['t'] for s in S[lab]['scripts'] if is_full(s))
    ev = []; mux = None
    for t, r, v in w:
        if r != MUX: continue
        b = (v >> 2) & 1
        if mux is not None and b != mux: ev.append((t, b))
        mux = b
    for i in range(len(ev) - 1):
        (gap_dp if ev[i][1] == 0 else gap_pd)[bucket(ev[i + 1][0] - ev[i][0], GE, GN)] += 1
    kinds = []; i = 0                       # (время, вид, время конца): 'U' подъём, 'D' спуск, 'R…' перенастройка PLL
    while i < len(ev):
        t, b = ev[i]
        if b == 0 and i + 1 < len(ev) and ev[i + 1][0] - t < PAIR: kinds.append((t, 'R ' + rdir(w, t, ev[i + 1][0]), ev[i + 1][0])); i += 2
        else: kinds.append((t, 'U' if b else 'D', t)); i += 1
    for te, k, te2 in kinds:
        j = bisect.bisect_left(full, te)
        if k[0] == 'R' and j < len(full) and full[j] < te2:      # скрипт памяти попал внутрь пары «делитель … PLL»
            c['перенастройка: скрипт внутри пары'] += 1; odd.append((ch, lab, 'скрипт памяти между уходом шины на делитель и возвратом на PLL', te, full[j])); continue
        d = min((te - ts for ts in full[max(0, j - 1):j + 1]), key=abs)
        dist[bucket(abs(d), DE, DN)] += 1
        if abs(d) > WIN: c['не рядом: ' + ('перенастройка' if k[0] == 'R' else 'переход')] += 1; continue
        side = 'до' if d < 0 else 'после'
        if k[0] == 'R':
            c[f'перенастройка {k[2:]} {side}'] += 1
            if (k[2:], side) in (('вверх', 'после'), ('вниз', 'до')): odd.append((ch, lab, f'перенастройка {k[2:]}, шина {side} скрипта', te, te - d))
            continue
        c[('подъём, шина ' if k == 'U' else 'спуск, шина ') + side] += 1
        if (k == 'U') != (d < 0): odd.append((ch, lab, ('подъём' if k == 'U' else 'спуск') + f', шина {side} скрипта', te, te - d))

def table(title, cols):
    print(f'\n{title}\n\n| чип | трасс | разделов × подразделов | ' + ' | '.join(cols) + ' |'); print('|---' * (len(cols) + 3) + '|')
    for ch in CH:
        if not ntr[ch]: continue
        tp = sorted({(t.get('active'), t.get('slices')) for k, t in topo.items() if t.get('chip') == ch and t.get('active')})
        print(f"| {ch} | {ntr[ch]} | {', '.join(f'{a} × {s}' for a, s in tp) or '—'} | " + ' | '.join(str(tot[ch][c]) for c in cols) + ' |')
    print('| всего | ' + str(sum(ntr.values())) + ' | | ' + ' | '.join(str(sum(tot[ch][c] for ch in tot)) for c in cols) + ' |')
print(f'Порог пары «делитель → PLL»: {PAIR * 1000:g} мс; окно вокруг скрипта памяти: ±{WIN * 1000:g} мс.')
table('Настоящие переходы шины XBAR2CLK (делитель ↔ PLL) относительно ближайшего полного скрипта памяти:',
      ['подъём, шина до', 'спуск, шина после', 'подъём, шина после', 'спуск, шина до', 'не рядом: переход'])
table('Перенастройки PLL шины (с PLL на PLL через делитель), направление по коэффициентам:',
      ['перенастройка вверх до', 'перенастройка вниз после', 'перенастройка вверх после', 'перенастройка вниз до', 'перенастройка та же частота до',
       'перенастройка та же частота после', 'перенастройка неизвестно до', 'перенастройка неизвестно после', 'перенастройка: скрипт внутри пары', 'не рядом: перенастройка'])
print('\nПромежуток между соседними сменами переключателя XBAR2CLK (все трассы):\n')
print('| промежуток | ' + ' | '.join(GN) + ' |'); print('|---' * (len(GN) + 1) + '|')
print('| с делителя → обратно на PLL | ' + ' | '.join(str(gap_dp[n]) for n in GN) + ' |')
print('| с PLL → на делитель | ' + ' | '.join(str(gap_pd[n]) for n in GN) + ' |')
print('\nРасстояние от события до ближайшего полного скрипта памяти:\n')
print('| ' + ' | '.join(DN) + ' |'); print('|---' * len(DN) + '|'); print('| ' + ' | '.join(str(dist[n]) for n in DN) + ' |')
print(f'\nСлучаи против порядка «шина снаружи»: {len(odd)}')
for ch, lab, what, te, ts in (odd if os.environ.get('ODD', '1') != '0' else []):
    print(f'\n- {ch} {lab}: {what}; событие в {te:.6f} с, скрипт в {ts:.6f} с. Лента (мс от скрипта):')
    for t, x in timeline(lab, min(te, ts) - 0.03, max(te, ts) + 0.03): print(f'    {(t - ts) * 1000:+9.3f}  {x}')
