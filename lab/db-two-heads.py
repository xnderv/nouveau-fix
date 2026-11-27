#!/usr/bin/env python3
# ДВА ЭКРАНА И СКРИПТ ПАМЯТИ В ЗАПИСЯХ NVIDIA (26.11). По трассам Fermi из базы (частная, вне репозитория): для каждого
# скрипта памяти — что драйвер NVIDIA на стороне компьютера читал и писал в регистрах дисплея (0x610000–0x62ffff) в окне
# перед загрузкой скрипта и сразу после, какие выходы в этот момент активны (по последним виденным значениям регистров
# развёртки), и что в самом скрипте: ожидания кадра (оп 0x14) и записи в регистр паузы вывода 0x611200.
# Вопрос: чем запись с двумя активными экранами отличается от записи с одним — ждёт ли NVIDIA кадр второго экрана,
# читает ли положение развёртки обоих, меняет ли числа паузы.
# Только чтение; участники обезличены (метки вида nvc8#7), пути базы не печатаются.
#   python3 -I lab/db-two-heads.py [ОПИСЬ_КАТАЛОГ] [БАЗА] [метка ...]      -> ОПИСЬ/two-heads.json + сводка в stdout
import sys, os, json, subprocess, collections
args = [a for a in sys.argv[1:]]
OUT = args[0] if len(args) > 0 else os.path.expanduser('~/Home/nouveau-archive/mem-survey')
DB = args[1] if len(args) > 1 else os.path.expanduser('~/Home/nouveau-archive/nouveau_vbios_trace')
ONLY = set(args[2:])
inv = json.load(open(os.path.join(OUT, 'inventory.json'))); key = json.load(open(os.path.join(OUT, 'inventory-key.json')))
PRE, POST = 0.150, 0.150        # окно до загрузки скрипта и после неё, с

def opener(rel):
    f, _, mem = rel.partition(':'); p = os.path.join(DB, f)
    with open(p, 'rb') as h: m = h.read(6)
    if not mem: return ['xz', '-dc', p] if m.startswith(b'\xfd7zXZ') else ['cat', p]
    if m.startswith(b'\xfd7zXZ'): return ['tar', '-xOJf', p, mem]
    if m.startswith(b'BZh'): return ['tar', '-xOjf', p, mem]
    return ['sh', '-c', 'tar -xOzf "$0" "$1" | (xz -dc 2>/dev/null || cat)', p, mem]

def parse(w):
    i, ops, nw = 0, [], 0
    while i < len(w):
        ln, op = w[i] >> 16, w[i] & 0xffff
        if ln == 0 or i + ln > len(w) + 1 or op > 0xff: return None
        a = w[i + 1:i + ln]
        if op == 0x21 and len(a) % 2: return None
        ops.append([op, a]); nw += len(a) // 2 if op == 0x21 else 0
        if op == 0x16: return ops if nw >= 5 else None
        i += ln
    return None
def is_mem(ops):
    for op, a in ops:
        if op == 0x21:
            for k in range(0, len(a), 2):
                r = a[k]
                if 0x100000 <= r < 0x101000 or 0x10f000 <= r < 0x130000 or 0x132000 <= r < 0x133000: return True
    return False

res = {}
if ONLY and os.path.exists(os.path.join(OUT, 'two-heads.json')): res = json.load(open(os.path.join(OUT, 'two-heads.json')))
for lab, r in inv.items():
    if r['gen'] != 'Fermi' or not r['pmu_scripts']: continue
    if ONLY and lab not in ONLY: continue
    bar0 = int(r['bar0'], 16); pr = subprocess.Popen(opener(key[lab]), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    ring = collections.deque(maxlen=6000)      # последние обращения к дисплею: (t, 'R'/'W', адрес, значение)
    last = {}                                  # последнее виденное значение регистра дисплея
    cur = None; tcur = 0; t0 = None; scripts = []; pend = []
    for raw in pr.stdout:
        c = raw[:2]
        if c != b'W ' and c != b'R ': continue
        p = raw.split()
        if len(p) < 6: continue
        try: a = int(p[4], 16) - bar0; v = int(p[5], 16); t = float(p[2])
        except ValueError: continue
        if t0 is None: t0 = t
        if 0x610000 <= a < 0x630000:
            ev = (round(t - t0, 6), chr(c[0]), a, v); ring.append(ev); last[a] = v
            for s in pend: s['post'].append(ev)
        pend = [s for s in pend if t - t0 - s['t'] <= POST]
        if c != b'W ': continue
        if a == 0x10a1c4 and cur is not None: cur.append(v); continue
        if cur is not None:
            ops = parse(cur)
            if ops and is_mem(ops):
                ts = round(tcur - t0, 6)
                s = dict(t=ts, words=len(cur),
                         wait=[x for op, x in ops if op == 0x14],
                         pause=[x[k + 1] for op, x in ops if op == 0x21 for k in range(0, len(x), 2) if x[k] == 0x611200],
                         pre=[e for e in ring if ts - e[0] <= PRE and e[0] <= ts], post=[],
                         state={hex(k): v for k, v in last.items()
                                if k in (0x610050, 0x610af8, 0x610af8 + 0x540, 0x610b40, 0x610b40 + 0x540, 0x610ad0, 0x610ad0 + 0x540,
                                         0x610ae8, 0x610ae8 + 0x540, 0x610af0, 0x610af0 + 0x540, 0x611200,
                                         0x616340, 0x616b40, 0x616308, 0x616b08, 0x610024, 0x610020)})
                scripts.append(s); pend.append(s)
            cur = None
        if a == 0x10a1c0: cur = []; tcur = t
    pr.stdout.close(); pr.wait()
    res[lab] = dict(chip=r['chip'], scripts=scripts, seen={hex(k): v for k, v in sorted(last.items())})
    print(f"{lab:9} скриптов памяти {len(scripts):>3}; регистров дисплея видно {len(last)}", flush=True)
json.dump(res, open(os.path.join(OUT, 'two-heads.json'), 'w'))
print('готово')
