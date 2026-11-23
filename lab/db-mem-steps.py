#!/usr/bin/env python3
# СЛОВАРЬ ШАГОВ ПО СМЫСЛУ и разметка скриптов памяти (23.11). Каждая операция/регистр скрипта NVIDIA -> шаг словаря.
# Источники смысла: nouveau (имена регистров и порядок в ramgk104.c/ramgf100.c, sddr3.c, gddr5.c), открытый драйвер NVIDIA
# для Tegra K1 (drivers/memory/tegra/tegra124-emc.c, DDR3L: порядок смены частоты с комментариями), наши опыты (перевод
# операций в lab ramgf100.c). «?» — смысл не установлен. Для каждого кластера (clusters-ПОРОГ.json от lab/db-mem-cluster.py)
# печатает свёрнутую цепочку шагов самого частого скрипта и долю скриптов кластера, где шаг есть. Только чтение.
#   python3 -I lab/db-mem-steps.py [ПОРОГ=0.6] [ОПИСЬ_КАТАЛОГ]
import sys, os, json, collections
TH = sys.argv[1] if len(sys.argv) > 1 else '0.6'
OUT = sys.argv[2] if len(sys.argv) > 2 else os.path.expanduser('~/Home/nouveau-archive/mem-survey')
S = json.load(open(os.path.join(OUT, 'scripts.json'))) if __name__ == '__main__' else None

OPS = {0x21: None, 0x2e: 'пауза', 0x13: 'пауза', 0x00: 'ожидание', 0x01: 'ожидание', 0x15: 'ожидание',
       0x14: 'ДИСПЛЕЙ: ждать кадр', 0x20: 'ДОСТУП: стоп/пуск хоста к VRAM', 0x16: 'конец',
       0x34: '? оп 0x34', 0x3a: '? оп 0x3a', 0x39: '? оп 0x39', 0x0b: '? оп 0x0b', 0x22: '? оп 0x22'}
def step(r, v):
    if 0x9a0000 <= r < 0x9a1000: r = 0x10f000 | (r & 0xfff)          # Pascal: блок переехал
    if r in (0x611200, 0x62c000, 0x62503c): return 'ДИСПЛЕЙ: пауза чтения VRAM'
    if r == 0x10f314: return 'КОМАНДА: PRECHARGE (закрыть банки)'
    if r == 0x10f310: return 'КОМАНДА: REFRESH'
    if r == 0x10f210: return 'ОБНОВЛЕНИЕ: авто ' + ('вкл' if v & 0x80000000 else 'выкл')
    if r == 0x10f200: return 'КОНТРОЛЛЕР 0x10f200' + (' (бит 31)' if v & 0x80000000 else '')
    if r == 0x10f090: return '? 0x10f090 (интерфейс)'
    if r == 0x10f300: return 'MR0 (CL, WR; у DDR3 — сброс DLL)'
    if r == 0x10f330: return 'MR1 (ODT, сила; у DDR3 — DLL вкл/выкл)'
    if 0x10f334 <= r <= 0x10f354: return 'MR2…MR8'
    if 0x10f290 <= r <= 0x10f2ec or r in (0x10f248, 0x10f24c, 0x10f250, 0x10f224): return 'ТАЙМИНГИ'
    if 0x132000 <= r < 0x133000: return 'PLL ПАМЯТИ'
    if 0x137300 <= r < 0x137400: return 'ТАКТ ПАМЯТИ (источник/делитель)'
    if r in (0x10f870, 0x10f640, 0x10f644, 0x10f628, 0x10f62c, 0x10f630, 0x10f634, 0x10f65c, 0x10f6b8, 0x10f6bc) or 0x10fc20 <= r < 0x10fc80:
        return 'ЛИНИИ: настройки по байтам (из ramcfg)'
    if 0x10f900 <= r < 0x10fa00: return 'ОБУЧЕНИЕ линий'
    if r in (0x00e108, 0x00e280, 0x00e104) or 0x00d600 <= r < 0x00d700: return 'ПИТАНИЕ памяти (GPIO)'
    if 0x13d800 <= r < 0x13da00: return '? 0x13d8x4 (рядом с оп 0x3a)'
    if 0x100000 <= r < 0x101000: return 'PFB (арбитраж/настройка) 0x100xxx'
    if 0x110000 <= r < 0x130000: return 'РАЗДЕЛЫ: per-partition'
    if r in (0x10f808, 0x10f824, 0x10f82c, 0x10f830, 0x10f800, 0x10f828, 0x10f604, 0x10f610, 0x10f614, 0x10f670, 0x10f340):
        return f'? FBPA {r:06x}'
    if 0x10f000 <= r < 0x110000: return 'FBPA прочее'
    return f'прочее {r:06x}'

def chain(ops):
    out = []
    for op, a in ops:
        names = [step(a[i], a[i + 1]) for i in range(0, len(a), 2)] if op == 0x21 else [OPS.get(op, f'? оп 0x{op:02x}')]
        for n in names:
            if n in ('пауза', 'ожидание'): n = '·' + n
            if not out or out[-1] != n: out.append(n)
    return out
def main():
    CL = json.load(open(os.path.join(OUT, f'clusters-{TH}.json')))
    for ci, members in enumerate(CL):
        if len(members) < 10: continue
        scripts = [S[m['trace']]['scripts'][m['n']] for m in members]
        g = collections.Counter(f"{m['gen']} {m['type']}" for m in members)
        chains = [tuple(c for c in chain(s['ops']) if not c.startswith('·')) for s in scripts]
        common = collections.Counter(chains).most_common(1)[0][0]
        pres = collections.Counter(st for c in chains for st in set(c))
        print(f"## К{ci + 1} ({', '.join(f'{k} {v}' for k, v in g.most_common(4))}; {len(members)} скриптов)\n")
        print('Типичная цепочка: ' + ' → '.join(common) + '\n')
        print('Шаги в доле скриптов кластера: ' + ', '.join(f'{st} {100 * n // len(chains)} %' for st, n in pres.most_common()) + '\n')

if __name__ == '__main__':
    main()
