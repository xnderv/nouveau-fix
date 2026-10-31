#!/usr/bin/env python3
# СВЕРКА ГЕНЕРАТОРА (30.10): одинаково ли драйвер считает узлы ядра (GPC, ROP, hubk07, hubk06, hubk01) обычным путём
# (lab_vbios_src=0) и генератором по VBIOS (lab_vbios_src=1). Читает строки «LAB calc» из журнала ядра; только чтение.
#   journalctl -k -b --no-pager | python3 -I lab/vbios-src-compare.py
#   python3 -I lab/vbios-src-compare.py ЖУРНАЛ.txt
# Строка генератора кончается «(lab_vbios_src: уровень …)»; обычная — без этого; у GPC на делителях обычный путь пишет
# «путь NVIDIA (lab_gpc_div)» (там ssel 0, coef 0, dsrc 3). Сравнивается каждая пара (узел, частота из таблицы).
import re, sys

NAMES = {0: 'gpc', 1: 'rop', 2: 'hubk07', 7: 'hubk06', 8: 'hubk01'}
GEN = re.compile(r'LAB calc idx ([0-9a-f]{2}) dom \d+: want (\d+) got (\d+) ssel ([0-9a-f]{8}) coef ([0-9a-f]{8}) '
                 r'dsrc ([0-9a-f]{8}) ddiv ([0-9a-f]{8}) mdiv ([0-9a-f]{8})( \(lab_vbios_src: уровень ([0-9a-f]{2}))?')
DIV = re.compile(r'LAB calc idx 00 dom \d+: путь NVIDIA \(lab_gpc_div\): want (\d+) got (\d+), VCO \d+, '
                 r'ddiv ([0-9a-f]{8}) mdiv ([0-9a-f]{8})')
old, new, level = {}, {}, {}
for line in (open(sys.argv[1], encoding='utf-8', errors='replace') if len(sys.argv) > 1 else sys.stdin):
    m = GEN.search(line)
    if m:
        idx = int(m.group(1), 16)
        if idx not in NAMES:
            continue
        key, val = (idx, int(m.group(2))), (int(m.group(3)),) + tuple(m.group(i) for i in range(4, 9))
        (new if m.group(9) else old).setdefault(key, set()).add(val)
        if m.group(10):
            level[key] = m.group(10)
        continue
    m = DIV.search(line)
    if m:
        old.setdefault((0, int(m.group(1))), set()).add((int(m.group(2)), '00000000', '00000000', '00000003', m.group(3), m.group(4)))

if not new:
    sys.exit('строк генератора (lab_vbios_src=1) в журнале нет: включи ключ и переключи уровни')
same = diff = miss = 0
print(f'{"узел":7} {"ур.":3} {"хочет":>8}  {"обычный путь (got ssel coef dsrc ddiv mdiv)":52} генератор')
for key in sorted(set(old) | set(new)):
    a, b = old.get(key, set()), new.get(key, set())
    fmt = lambda s: ' | '.join(' '.join(str(x) for x in v) for v in sorted(s)) or '—'
    if not a or not b:
        miss += 1
        res = 'нет пары: ' + ('генератор этот уровень не считал' if not b else 'обычный путь этот уровень не считал')
    elif a == b and len(a) == 1:
        same += 1; res = '= то же'
    else:
        diff += 1; res = fmt(b) + '  <-- РАЗНИЦА'
    print(f'{NAMES[key[0]]:7} {level.get(key, "?"):3} {key[1]:8}  {fmt(a):52} {res}')
print(f'\nсовпало {same}, расходится {diff}, без пары {miss}')
sys.exit(1 if diff else 0)
