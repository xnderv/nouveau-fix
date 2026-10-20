#!/usr/bin/env python3
# Сравнение снимка регистров nouveau с эталоном NVIDIA (только чтение файлов).
# Запуск: python3 memcmp.py НАШ_ФАЙЛ ЭТАЛОН_ФАЙЛ МЕТКА_ЭТАЛОНА
# Берётся ПОСЛЕДНИЙ снимок из нашего файла и снимок эталона, чья метка начинается с МЕТКА_ЭТАЛОНА.
import sys
def load(p):
    snaps = []; cur = None
    for l in open(p, encoding='utf-8', errors='replace'):
        if l.startswith('###'): cur = {}; snaps.append((l[4:].strip(), cur)); continue
        if l.startswith('##') or not l.strip(): continue
        a, v = l.split()[:2]; cur[int(a, 16)] = int(v, 16)
    return snaps
ours = load(sys.argv[1])[-1]
ref = [s for s in load(sys.argv[2]) if s[0].startswith(sys.argv[3])][-1]
print(f'наш:    {ours[0]}\nэталон: {ref[0]}')
KEY = {0x10f290: 'тайминги', 0x10f294: 'тайминги', 0x10f298: 'тайминги', 0x10f29c: 'тайминги', 0x10f2a0: 'тайминги',
       0x10f300: '', 0x10f824: '', 0x10f050: '', 0x137310: 'делитель памяти', 0x1373f0: 'режим памяти',
       0x132000: 'MPLL', 0x10f200: '', 0x10f808: '', 0x10f830: '', 0x10f614: '', 0x10f610: ''}
ranges = [(0x100700, 0x100800), (0x10f000, 0x10fc00), (0x132000, 0x132200), (0x137300, 0x137400)]
diff = []
for lo, hi in ranges:
    for a in range(lo, hi, 4):
        if a in ours[1] and a in ref[1] and ours[1][a] != ref[1][a]:
            diff.append(a)
print('Ключевые регистры:')
for a, n in KEY.items():
    o, r = ours[1].get(a), ref[1].get(a)
    if o is None or r is None: continue
    print(f'  {"✓" if o == r else "✗"} {a:06x} наш {o:08x}  NVIDIA {r:08x}  {n}')
print(f'Всего различий в диапазонах памяти: {len(diff)}')
for a in diff[:60]:
    print(f'  {a:06x} наш {ours[1][a]:08x}  NVIDIA {ref[1][a]:08x}')
if len(diff) > 60: print('  …')
