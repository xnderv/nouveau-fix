#!/usr/bin/env python3
# СВЕРКА СОСТОЯНИЯ, часть 3: сравнить снимок lab/memstate-dump.py с состоянием NVIDIA из lab/trace-memstate.py.
#   python3 -I lab/memstate-diff.py nvidia-state.json СНИМОК.txt [номер момента | «МГц после», напр. 896]
# Без третьего аргумента печатает список моментов. Момент можно задать числом из списка или частотой памяти: тогда берётся
# первое состояние «после скрипта» с этой частотой.
import json, sys
J = json.load(open(sys.argv[1])); M = J['moments']
if len(sys.argv) < 4:
    for i, m in enumerate(M): print(f'{i:3d}: {m["t"]:10.3f} с, скрипт {m["script"]} ({m["nwords"]} слов), {m["when"]}: память {m["memory"]}')
    sys.exit()
sel = sys.argv[3]
m = M[int(sel)] if sel.isdigit() and int(sel) < len(M) else next((x for x in M if x['when'] == 'после' and x['memory'].startswith(sel + ' ')), None)
if m is None: sys.exit('момент не найден')
dump = {}; vol = set(); head = ''
for l in open(sys.argv[2]):
    if l.startswith('#'): head = l.strip(); continue
    p = l.split('#')[0].split()
    if not p: continue
    dump[p[0]] = int(p[1], 16)
    if len(p) > 2: vol.add(p[0])
print(f'NVIDIA: {m["t"]:.3f} с, скрипт {m["script"]} ({m["nwords"]} слов), {m["when"]}, память {m["memory"]}')
print(f'снимок: {head}')
same = diff = miss = 0; rows = []
for a, nv in sorted(m['state'].items()):
    if a not in dump: miss += 1; continue
    if dump[a] == nv: same += 1; continue
    diff += 1; r = J['regs'].get(a, {})
    rows.append((r.get('unit', '?'), a, nv, dump[a], r.get('host', 0), r.get('script', 0), a in vol))
print(f'совпадает {same}, различается {diff}, нет в снимке {miss} (не читаются или NVIDIA к этому моменту их не трогала)')
print('блок | регистр | NVIDIA | у нас | отличающиеся биты | кто пишет у NVIDIA | замечание')
for u, a, nv, our, h, s, v in sorted(rows):
    who = ('хост ×%d' % h if h else '') + (' скрипт ×%d' % s if s else '') or 'только читает'
    print(f'{u} | {a} | {nv:08x} | {our:08x} | {nv ^ our:08x} | {who.strip()} | {"меняется между чтениями" if v else ""}')
