#!/usr/bin/env python3
# Count level transitions in tester kernel logs: who started them (governor or by hand) and from which level.
import sys, os, re, hashlib, collections, datetime

root = sys.argv[1]
files = []
for d, _, fs in os.walk(root):
    for f in fs:
        if f.endswith(('.txt', '.log')):
            files.append(os.path.join(d, f))
seen = set()
re_ts = re.compile(r'^([A-Z][a-z]{2}) +(\d+) (\d\d):(\d\d):(\d\d) ')
re_iso = re.compile(r'^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)')
re_dm = re.compile(r'^\[ *(\d+)\.(\d+)\]')
MON = {m: i + 1 for i, m in enumerate('Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec'.split())}

def ts(l):
    m = re_ts.match(l)
    if m:
        return datetime.datetime(2026, MON[m.group(1)], int(m.group(2)), int(m.group(3)), int(m.group(4)), int(m.group(5))).timestamp()
    m = re_iso.match(l)
    if m:
        return datetime.datetime(*map(int, m.groups())).timestamp()
    m = re_dm.match(l)
    if m:
        return float(m.group(1) + '.' + m.group(2))
    return None

boards = collections.OrderedDict()   # key -> stats
def board(key):
    return boards.setdefault(key, dict(files=0, boots=0, secs=0.0, tr=collections.Counter(), gov=collections.Counter(),
                                       govmem=collections.Counter(), nlev=0, ids={}))
for p in sorted(files):
    try:
        data = open(p, 'rb').read()
    except OSError:
        continue
    if b'LAB pstate' not in data:
        continue
    h = hashlib.md5(data).hexdigest()
    if h in seen:
        continue
    seen.add(h)
    L = data.decode('utf-8', 'replace').split('\n')
    chip = bios = None
    cur = None; t0 = t1 = None; last = None; mem = 0
    key = None
    segs = []
    seg = None
    def newseg():
        return dict(tr=[], t0=None, t1=None)
    seg = newseg()
    for l in L:
        if 'Linux version' in l and seg['tr']:
            segs.append(seg); seg = newseg(); cur = None
        m = re.search(r'nouveau [0-9a-f:.]+: NVIDIA (\w+) \(([0-9a-f]+)\)', l)
        if m:
            chip = m.group(1)
        m = re.search(r'bios: version ([0-9a-f.]+)', l)
        if m:
            bios = m.group(1)
        if 'LAB' not in l:
            continue
        t = ts(l)
        if t is not None:
            if seg['t0'] is None:
                seg['t0'] = t
            seg['t1'] = t
        m = re.search(r'LAB pstate (\d+): flags .*?mem=(\d)', l)
        if m:
            last = dict(frm=cur, to=int(m.group(1)), mem=int(m.group(2)), gov=None, ok=None)
            seg['tr'].append(last)
            continue
        m = re.search(r'LAB pstate (\d+): done ret (-?\d+)', l)
        if m and last and last['to'] == int(m.group(1)):
            last['ok'] = (m.group(2) == '0')
            if last['ok']:
                cur = last['to']
            continue
        m = re.search(r'LAB gov: -> ([0-9a-f]{2}) \(([^,]*)', l)
        if m and last:
            last['gov'] = m.group(2)
            last['id'] = m.group(1)
    if seg['tr']:
        segs.append(seg)
    key = f'{chip} bios {bios}'
    b = board(key)
    b['files'] += 1
    for s in segs:
        b['boots'] += 1
        if s['t0'] is not None and s['t1'] is not None and s['t1'] >= s['t0']:
            b['secs'] += s['t1'] - s['t0']
        for tr in s['tr']:
            if tr['ok'] is False:
                continue
            b['nlev'] = max(b['nlev'], tr['to'] + 1, (tr['frm'] or 0) + 1)
            if tr.get('id'):
                b['ids'][tr['to']] = tr['id']
            k = (tr['frm'], tr['to'])
            b['tr'][k] += 1
            if tr['gov']:
                b['gov'][k] += 1
                if tr['mem']:
                    b['govmem'][k] += 1

def name(b, i):
    if i is None:
        return 'boot'
    return b['ids'].get(i, f'#{i}')

tot = collections.Counter()
for key, b in boards.items():
    top = b['nlev'] - 1
    print(f"\n== {key}: {b['files']} logs, {b['boots']} boots, {b['secs']/3600:.1f} h of log, levels {b['nlev']} ({', '.join(name(b,i) for i in range(b['nlev']))})")
    for k in sorted(b['tr'], key=lambda k: ((-1 if k[0] is None else k[0]), k[1])):
        print(f"   {name(b,k[0]):>5} -> {name(b,k[1]):<3}: all {b['tr'][k]:5}   by governor {b['gov'][k]:5}   (governor, memory switching on: {b['govmem'][k]})")
    if top >= 2:
        for k, n in b['gov'].items():
            if k[1] == top:
                tot['gov rise to top from ' + ('lowest' if k[0] == 0 else 'middle' if k[0] is not None and 0 < k[0] < top else 'boot state')] += n
                if b['govmem'][k]:
                    tot['same, memory on, from ' + ('lowest' if k[0] == 0 else 'middle' if k[0] is not None and 0 < k[0] < top else 'boot state')] += b['govmem'][k]
        tot['hours (3-level boards)'] += b['secs'] / 3600
print('\n== three-level boards together')
for k, v in sorted(tot.items()):
    print(f'   {k}: {v:.1f}' if isinstance(v, float) else f'   {k}: {v}')
