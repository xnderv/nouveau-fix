#!/usr/bin/env python3
# Время до признака «замедление вступило» по скобкам из журнала ядра лабораторного драйвера (строки «LAB therm wait idx XX:
# признак через N нс»): распределение по домену. journalctl -k -b N -o cat | python3 lab/flag-stat.py
import sys, re, statistics
# строки «LAB therm wait idx XX: признак через N нс» из stdin -> распределение по idx
d = {}
for l in sys.stdin:
    m = re.search(r'LAB therm wait idx ([0-9a-f]{2}): признак через (\d+) нс', l)
    if m: d.setdefault(m.group(1), []).append(int(m.group(2)))
for k, v in sorted(d.items()):
    v.sort(); n = len(v)
    q = lambda p: v[min(n - 1, int(p * n))]
    print(f"  idx {k}: n={n} мин {v[0]} p10 {q(.10)} медиана {q(.5)} p90 {q(.9)} p99 {q(.99)} макс {v[-1]} нс")
