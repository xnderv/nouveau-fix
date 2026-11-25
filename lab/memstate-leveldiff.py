#!/usr/bin/env python3
# СВЕРКА СОСТОЯНИЯ ПО УРОВНЯМ (25.11): что держит драйвер NVIDIA в регистрах памяти, шины XBAR, тактов и кэша L2 на каждом
# уровне памяти (lab/trace-memstate.py по записи) против снимков той же карты под нашим модулем (lab/memstate-levels.sh).
# Состояние NVIDIA на уровне — это состояния «до» всех скриптов, которые с этого уровня уходят (за 25 мс до пуска: переход на
# уровень давно закончен, прямые записи следующего перехода ещё не начались). Регистр, у которого NVIDIA на одном уровне
# держит разные значения в разные моменты, помечается «плавает» и в отличия не идёт.
# Только чтение файлов.
#   python3 -I lab/memstate-leveldiff.py nvidia-state.json КАТАЛОГ_СНИМКОВ [--all]     (--all — печатать и совпадения)
import sys, json, os, re, collections
st = json.load(open(sys.argv[1])); D = sys.argv[2]; ALL = '--all' in sys.argv
info = st['regs']; moments = st['moments']
def level_of(label):
    if label.startswith('PLL'): return 'верх'
    m = re.match(r'(\d+) МГц', label)
    return m.group(1) if m else None
nv = collections.defaultdict(lambda: collections.defaultdict(set))      # уровень -> адрес -> значения NVIDIA
cnt = collections.Counter()
for m in moments:
    if m['when'] != 'до': continue
    lv = level_of(m['memory'])
    if lv is None: continue
    cnt[lv] += 1
    for a, v in m['state'].items(): nv[lv][a].add(v)
dumps = {}
for f in sorted(os.listdir(D)):
    if not f.startswith('level-'): continue
    head = open(os.path.join(D, f), encoding='utf-8').readline()
    mem = re.search(r'memory (\d+) MHz', head); mhz = int(mem.group(1)) if mem else 0
    vals = {}
    for l in open(os.path.join(D, f), encoding='utf-8'):
        if l.startswith('#') or not l.strip(): continue
        p = l.split('#')[0].split()
        vals[p[0]] = [int(x, 16) for x in p[1:]]
    dumps[f[6:8]] = (mhz, vals)
low = sorted(k for k in nv if k != 'верх')
def nv_level(mhz):
    if str(mhz) in nv: return str(mhz)
    return 'верх' if mhz > 1000 else None
print(f'моментов NVIDIA по уровням: {dict(cnt)}; снимки: ' + ', '.join(f'{k} ({v[0]} МГц)' for k, v in dumps.items()))
rows = collections.OrderedDict(); summary = {}
for lvl, (mhz, vals) in dumps.items():
    k = nv_level(mhz); c = collections.Counter()
    for a, ours in vals.items():
        theirs = nv[k].get(a) if k else None
        if not theirs: c['NVIDIA на этом уровне не трогала'] += 1; res = ('—', None)
        elif len(theirs) > 1: c['у NVIDIA плавает'] += 1; res = ('~', sorted(theirs))
        elif len(set(ours)) > 1: c['у нас плавает'] += 1; res = ('~', sorted(theirs))
        elif ours[0] == next(iter(theirs)): c['совпало'] += 1; res = ('=', sorted(theirs))
        else: c['ОТЛИЧАЕТСЯ'] += 1; res = ('!', sorted(theirs))
        rows.setdefault(a, {})[lvl] = (res[0], res[1], ours)
    summary[lvl] = c
for lvl, c in summary.items():
    print(f'уровень {lvl}: ' + ', '.join(f'{k} {v}' for k, v in sorted(c.items(), key=lambda x: -x[1])))
byunit = collections.defaultdict(list)
for a, r in rows.items():
    if ALL or any(x[0] == '!' for x in r.values()): byunit[info.get(a, {}).get('unit', '?')].append(a)
def fmt(x):
    mark, theirs, ours = x
    t = '/'.join(f'{v:08x}' for v in theirs) if theirs else '—'
    return f'{t} | {ours[0]:08x}' + (' !' if mark == '!' else ' ~' if mark == '~' else '')
print('\nотличия (NVIDIA | мы; «!» — отличается, «~» — плавает, «—» — NVIDIA на этом уровне регистр не трогала):')
for u in sorted(byunit, key=lambda u: -len(byunit[u])):
    print(f'## {u}: {len(byunit[u])}')
    for a in sorted(byunit[u]):
        i = info.get(a, {})
        print(f'  {a}  ' + '   '.join(f'{lvl}: {fmt(rows[a][lvl])}' for lvl in dumps if lvl in rows[a])
              + f'   [NVIDIA: записей хоста {i.get("host", 0)}, из скриптов {i.get("script", 0)}, чтений {i.get("read", 0)}]')
