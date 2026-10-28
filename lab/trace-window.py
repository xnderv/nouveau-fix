#!/usr/bin/env python3
# Окно записи mmiotrace: записи хоста (W) в заданных диапазонах адресов за отрезок времени; загрузки слов в PMU
# (0x10a1c4) свёрнуты в одну строку. Только чтение.
# python3 -I lab/trace-window.py ЗАПИСЬ.txt BAR0 T0 T1 [диапазоны через запятую, напр. 10f000-110000,132000-133000]
import sys
path, bar, t0, t1 = sys.argv[1], int(sys.argv[2], 16), float(sys.argv[3]), float(sys.argv[4])
rng = sys.argv[5] if len(sys.argv) > 5 else '10f000-110000,132000-133000,e100-e300,137000-138000,10a1c0-10a1c1,10a400-10a600,100b00-100c00,100c00-100c04,611200-611204,13d800-13e000'
R = [tuple(int(x, 16) for x in r.split('-')) for r in rng.split(',')]
up, ust, last = 0, 0.0, None
def flush():
    global up
    if up: print(f'  {ust:.6f}  PMU: загрузка {up} слов'); up = 0
for line in open(path, errors='replace'):
    if not line.startswith(('W ', 'R ')): continue
    p = line.split()
    t = float(p[2])
    if t < t0: continue
    if t > t1: break
    a = int(p[4], 16) - bar
    if a < 0 or a >= 0x1000000: continue
    if p[0] == 'W' and a == 0x10a1c4:
        if not up: ust = t
        up += 1; continue
    if p[0] == 'R': continue
    if any(lo <= a < hi for lo, hi in R):
        flush(); print(f'  {t:.6f}  W {a:06x} = {p[5]}')
flush()
