#!/usr/bin/env python3
# ПОРЯДОК СМЕНЫ ТАКТОВ ЯДРА В ЗАПИСИ NVIDIA (25.11.2026): для каждой смены уровня — в каком порядке драйвер NVIDIA
# переводит узлы ядра между делителем и PLL (регистр 0x137100), когда программирует PLL, когда переключает источник
# HUB2CLK (0x137180), какие «скобки» замедления ставит (0x020160 — GPC2CLK, 0x020164 — SYS2CLK) и с какой глубиной,
# и где в этом ряду стоят записи линий GPIO (напряжение). Одинаковые последовательности печатаются один раз со счётчиком.
# В конце — устоявшиеся состояния узлов (частоты по регистрам) на каждом уровне.
# Только чтение файла записи. Адрес BAR0 определяется по первому обращению к 0x137100.
#   python3 -I lab/trace-core-seq.py ЗАПИСЬ.txt[.xz] [--all]      (--all: печатать каждую смену, а не только разные)
#   xz -dc ЗАПИСЬ.tar.xz | tar -xO … | python3 -I lab/trace-core-seq.py -
import sys, lzma, collections

NODE = {0: 'GPC2CLK', 1: 'LTC2CLK', 2: 'XBAR2CLK', 7: 'SYS2CLK', 8: 'HUB2CLK', 9: 'copy', 12: 'PWRCLK', 14: 'MSDCLK'}
PLLIDX = {0x137000: 0, 0x137020: 1, 0x137040: 2, 0x1370e0: 7}

def opener(fn):
    if fn == '-':
        return sys.stdin
    if fn.endswith('.xz'):
        return lzma.open(fn, 'rt', errors='replace')
    return open(fn, errors='replace')

def code_div(code):          # код глубины замедления -> делитель (код = 2·делитель − 2)
    return (code + 2) / 2

def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    show_all = '--all' in sys.argv
    if not args:
        sys.exit(__doc__ or 'usage: trace-core-seq.py TRACE')
    base = None
    reg = {}                 # последнее известное значение регистра (чтение или запись)
    ev = []                  # (t, текст, ключ для подписи)
    with opener(args[0]) as f:
        for line in f:
            if not line or line[0] not in 'RW':
                continue
            p = line.split()
            if len(p) < 6 or p[1] != '4':
                continue
            try:
                a = int(p[4], 16); v = int(p[5], 16); t = float(p[2])
            except ValueError:
                continue
            if base is None:
                if (a & 0xffffff) == 0x137100:
                    base = a - 0x137100
                else:
                    continue
            a -= base
            if not 0 <= a < 0x1000000:
                continue
            if p[0] == 'R':
                reg.setdefault(a, v) if a not in reg else None
                if a == 0x137100:
                    reg[a] = v
                continue
            old = reg.get(a)
            reg[a] = v
            if a == 0x137100:
                ch = (old ^ v) if old is not None else v
                for b in range(16):
                    if ch >> b & 1:
                        to = 'PLL' if v >> b & 1 else 'делитель'
                        ev.append((t, f'{NODE.get(b, "узел %d" % b)} -> {to}', f'mux{b}{"+" if v >> b & 1 else "-"}'))
            elif a in PLLIDX:
                i = PLLIDX[a]
                if (v & 1) and not ((old or 0) & 1):
                    ev.append((t, f'PLL {NODE[i]} включена', f'pll{i}on'))
                elif not (v & 1) and ((old or 0) & 1):
                    ev.append((t, f'PLL {NODE[i]} выключена', f'pll{i}off'))
            elif a - 4 in PLLIDX:
                i = PLLIDX[a - 4]
                if old != v:
                    ev.append((t, f'PLL {NODE[i]} коэффициенты {v:08x}', f'pll{i}coef'))
            elif 0x137160 <= a <= 0x13719c and (a & 3) == 0:
                i = (a - 0x137160) // 4
                if old != v:
                    sub = (v >> 24) & 7
                    ev.append((t, f'источник {NODE.get(i, "узел %d" % i)} = {v:08x}' + (f' (код {v & 3}, подвыбор {sub})' if i == 8 else ''),
                               f'src{i}:{v & 3}:{sub if i == 8 else 0}'))
            elif 0x1371d0 <= a <= 0x13720c and (a & 3) == 0:
                i = (a - 0x1371d0) // 4
                if old != v:
                    ev.append((t, f'делитель {NODE.get(i, "узел %d" % i)} = {v:08x}', f'ddiv{i}'))
            elif 0x137250 <= a <= 0x13728c and (a & 3) == 0:
                i = (a - 0x137250) // 4
                if old != v:
                    ev.append((t, f'пост-делитель {NODE.get(i, "узел %d" % i)} = {v:08x}', f'mdiv{i}'))
            elif a in (0x020160, 0x020164):
                who = 'GPC2CLK' if a == 0x020160 else 'SYS2CLK'
                idle, cmd = (v >> 16) & 0x3f, v & 0x3f
                if idle or (v & 0x08):
                    ev.append((t, f'скобка {who}: вход, значение {v:08x} (глубина /{code_div(idle):g})', f'br{a & 0xf}in:{idle:x}'))
                else:
                    ev.append((t, f'скобка {who}: выход, значение {v:08x}', f'br{a & 0xf}out'))
            elif a in (0x00e104, 0x00e108, 0x00e280, 0x00e284) or 0x00d610 <= a < 0x00d690:
                if old != v:
                    ev.append((t, f'линии GPIO {a:06x} = {v:08x}', 'gpio'))
    if base is None:
        sys.exit('в записи нет обращений к 0x137100')
    # группы: пауза больше 50 мс
    groups, cur = [], []
    for e in ev:
        if cur and e[0] - cur[-1][0] > 0.05:
            groups.append(cur); cur = []
        cur.append(e)
    if cur:
        groups.append(cur)
    groups = [g for g in groups if any(k.startswith('mux') for _, _, k in g)]
    print(f'BAR0 {base:#x}; смен уровня с переключением узлов между делителем и PLL: {len(groups)}')
    sig = collections.OrderedDict()
    for g in groups:
        key = tuple(k for _, _, k in g if k != 'gpio' or True)
        sig.setdefault(key, []).append(g)
    for n, (key, gs) in enumerate(sig.items(), 1):
        if show_all:
            todo = gs
        else:
            todo = gs[:1]
        for g in todo:
            t0 = g[0][0]
            print(f'\n--- последовательность {n}: встречается {len(gs)} раз; пример с t = {t0:.3f} с')
            for t, txt, _ in g:
                print(f'  +{(t - t0) * 1e6:8.0f} мкс  {txt}')
    # сводка по скобкам
    br = collections.Counter(k for g in groups for _, _, k in g if k.startswith('br') and 'in' in k)
    print('\nглубина скобок (сколько раз):', ', '.join(f'{"GPC2CLK" if k[2] == "0" else "SYS2CLK"} код {k.split(":")[1]} (/{code_div(int(k.split(":")[1], 16)):g}) × {c}' for k, c in sorted(br.items())) or 'скобок нет')
    up = collections.Counter(); dn = collections.Counter()
    for g in groups:
        o_up = [k[3:-1] for _, _, k in g if k.startswith('mux') and k.endswith('+')]
        o_dn = [k[3:-1] for _, _, k in g if k.startswith('mux') and k.endswith('-')]
        if o_up: up[' '.join(o_up)] += 1
        if o_dn: dn[' '.join(o_dn)] += 1
    print('порядок перевода узлов на PLL (номера узлов; 0 GPC2CLK, 1 LTC2CLK, 2 XBAR2CLK, 7 SYS2CLK):', dict(up))
    print('порядок перевода узлов на делитель:', dict(dn))

main()
