#!/usr/bin/env python3
# Разбор записи mmiotrace драйвера NVIDIA: что пишется внутри каждой скобки PTHERM (FSRM GPC / hubk06) и какие
# изменения тактов GPC/hubk06 сделаны вне скобок. Запуск: python3 -I lab/trace-brackets.py <mmiotrace.txt> [...]
import sys
# GPC = idx 0, hubk06 = idx 7. Clock-config registers of these domains (nouveau gf100 layout):
GPC = {0x137000:'PLL0 ctrl',0x137004:'PLL0 coef',0x137160:'GPC dsrc',0x1371d0:'GPC ddiv',0x137250:'GPC postdiv'}
HUB = {0x1370e0:'PLL7 ctrl',0x1370e4:'PLL7 coef',0x13717c:'hub06 dsrc',0x1371ec:'hub06 ddiv',0x13726c:'hub06 postdiv'}
ENTER = {(0x020160,0xa008a):'GPC', (0x020164,0x20082):'hub06'}
LEAVE = {(0x020160,0x0):'GPC', (0x020164,0x82):'hub06'}
for fn in sys.argv[1:]:
    print('########', fn)
    open_b = {}          # dom -> list of inner writes
    mux = None
    outside = []
    nbr = 0
    with open(fn, errors='replace') as f:
        for line in f:
            p = line.split()
            if len(p) >= 6 and p[0] == "R" and (int(p[4], 16) & 0xffffff) == 0x137100: mux = int(p[5], 16); continue
            if len(p) < 6 or p[0] != "W": continue
            t = float(p[2]); a = int(p[4], 16) & 0xffffff; v = int(p[5], 16)
            if (a, v) in ENTER:
                open_b[ENTER[(a, v)]] = [t, []]; continue
            if (a, v) in LEAVE and LEAVE[(a, v)] in open_b:
                d = LEAVE[(a, v)]; t0, inner = open_b.pop(d); nbr += 1
                print(f"  {t0:.6f} скобка {d:5s}: внутри {', '.join(inner) if inner else 'НИЧЕГО'}")
                continue
            if a in (0x0201a0,0x0201a4,0x020180,0x020184,0x020004): continue
            what = None
            if a == 0x137100:
                if mux is not None:
                    ch = mux ^ v
                    bits = [b for b in range(16) if ch >> b & 1]
                    what = f"137100 {mux:#x}->{v:#x} (биты {bits})"
                    tag = ('GPC' if 0 in bits else '') + ('hub06' if 7 in bits else '')
                else:
                    tag = ''
                mux = v
                if what is None: continue
            elif a in GPC: what, tag = f"{GPC[a]}={v:#x}", 'GPC'
            elif a in HUB: what, tag = f"{HUB[a]}={v:#x}", 'hub06'
            else: continue
            inb = [d for d in open_b]
            for d in inb: open_b[d][1].append(what)
            if not inb and tag:
                outside.append(f"{t:.6f} {what}")
    print(f"  скобок всего: {nbr}")
    print(f"  изменения GPC/hub06 ВНЕ скобок: {len(outside)}")
    for o in outside[:40]: print('    ', o)
