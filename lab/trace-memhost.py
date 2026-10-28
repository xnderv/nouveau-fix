#!/usr/bin/env python3
# Прямые записи хоста вокруг скриптов памяти PMU в записи mmiotrace драйвера NVIDIA: для каждого скрипта (из JSON
# lab/trace-memscr.py) — «pre» (записи в регистры памяти за окно до загрузки скрипта, но после пуска предыдущего) и
# «post» (после пуска скрипта — записи 0x10a4a0 — до загрузки следующего или до конца окна). Только чтение.
# Правило отреза (проверено на нашей записи 20.10: воспроизводит массивы preA/midAB/postB/preC/midCD/postD драйвера):
#   pre — записи за ОКНО_МС (20) до загрузки, но после пуска предыдущего скрипта; post — после пуска до загрузки
#   следующего скрипта, до первой записи в 0x100bxx (настройка PFB после перехода) или до 50 мс.
# python3 -I lab/trace-memhost.py ЗАПИСЬ.txt BAR0 СКРИПТЫ.json ВЫХОД.json [окно_мс=20]
import sys, json
path, bar, scr_json, out = sys.argv[1], int(sys.argv[2], 16), sys.argv[3], sys.argv[4]
win = float(sys.argv[5]) / 1000 if len(sys.argv) > 5 else 0.020
R = [(0x10f000, 0x110000), (0x132000, 0x133000), (0xe104, 0xe108), (0xe280, 0xe284), (0x137360, 0x137364), (0x100b00, 0x100c04)]
S = json.load(open(scr_json)); ts = [s['t'] for s in S]
W = []  # (t, addr, val) записи хоста в диапазонах + пуски
trig = []
for line in open(path, errors='replace'):
    if not line.startswith('W '): continue
    p = line.split(); t = float(p[2])
    if t < ts[0] - win - 1 or t > ts[-1] + 1: continue
    a = int(p[4], 16) - bar
    if a == 0x10a4a0: trig.append((t, int(p[5], 16))); continue
    if any(lo <= a < hi for lo, hi in R): W.append((t, a, int(p[5], 16)))
res = []
for i, s in enumerate(S):
    t = s['t']
    tr = next((x for x in trig if x[0] > t), None)
    if tr is None: print('нет пуска для скрипта', i); continue
    texec = tr[0]
    prev_exec = next((x[0] for x in reversed(trig) if x[0] < t), -1)
    t0 = max(t - win, prev_exec)
    t1 = min(ts[i + 1] if i + 1 < len(S) else 1e9, texec + 0.050)
    pre = [(a, v) for (tt, a, v) in W if t0 < tt < t]
    post = []
    for (tt, a, v) in W:
        if not (texec < tt < t1): continue
        if 0x100b00 <= a < 0x100c04: break
        post.append((a, v))
    res.append(dict(i=i, t=t, texec=texec, launcher=tr[1], nwords=s['nwords'], nregs=len(s['regs']), pre=pre, post=post))
    print(f"скрипт {i} t={t:.3f} слов {s['nwords']} WR {len(s['regs'])}: пуск +{(texec-t)*1e3:.1f} мс (launcher {tr[1]:#x}); pre {len(pre)} пар с {t0:.3f}, post {len(post)} пар до {t1:.3f}")
json.dump(res, open(out, 'w'))
