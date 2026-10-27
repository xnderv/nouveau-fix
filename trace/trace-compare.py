#!/usr/bin/env python3
# Разбор и сравнение записей mmiotrace драйвера NVIDIA на GTX 560 Ti (стенд 10.04 и try7), без сырых данных в репозитории.
#   trans ЗАПИСЬ                      — переходы уровней: группы записей в переключатель 0x137100, скобку FSRM 0x0201x0,
#                                       делители 0x1371d0/0x137250 и PLL GPC 0x137000 (разрыв > 0,5 с — новая группа)
#   seq ЗАПИСЬ T0 ДО_МС ПОСЛЕ_МС      — записи хоста в PCLOCK 0x137xxx, скобку 0x0201xx, MPLL 0x132000/4 и сброс 0x070000
#                                       в окне вокруг T0 (время — мс от T0)
#   mux ЗАПИСЬ                        — застревание переключателя GPC: каждая запись в 0x137100, снимающая бит 0 (GPC с PLL
#                                       на делитель), и следующее чтение 0x137100 (270.x читает сразу после записи);
#                                       бит 0 в прочитанном = застрял; плюс счёт циклов сценария mux и спусков в них
#   init ЗАПИСЬ_А ЗАПИСЬ_Б            — что пишет драйвер от загрузки модуля до первой метки «0 максимум» (прохода записи):
#                                       регистры BAR0 и значения, которые есть только в одной из записей (без массовых
#                                       портов прошивок FECS/GPCCS и I2C — по ним только число записей)
# ЗАПИСЬ — текст mmiotrace или .xz. Время — секунды записи. Окно регистров другой машины: BAR0=0xf6000000 python3 -I …
# Запуск: python3 -I trace/trace-compare.py trans ~/Home/stand-2011/results/out-…/mmiotrace.txt.xz
import collections, io, lzma, os, sys

BAR0 = int(os.environ.get('BAR0', '0xf4000000'), 16)   # окно регистров карты; у других машин иное (PCIDEV-строка записи)
KEY = {0x137100: 'mux', 0x020160: 'fsrm160', 0x020180: 'fsrm180', 0x0201a0: 'fsrm1a0',
       0x1371d0: 'div1d0', 0x137250: 'div250', 0x137000: 'gpcpll'}
BULK = {0x409184: 'FECS данные', 0x41a184: 'GPCCS данные', 0x409180: 'FECS адрес', 0x41a180: 'GPCCS адрес'}


def lines(path):
    f = io.TextIOWrapper(lzma.open(path), encoding='utf-8', errors='replace') if path.endswith('.xz') \
        else open(path, encoding='utf-8', errors='replace')
    with f:
        for l in f:
            yield l.split()


def bar0_writes(path):
    """(время, смещение, значение) записей в BAR0 и метки ('MARK', время, текст)."""
    for p in lines(path):
        if not p:
            continue
        if p[0] == 'MARK':
            yield ('MARK', float(p[1]), ' '.join(p[2:]))
        elif p[0] == 'W' and len(p) >= 6:
            a = int(p[4], 16)
            if BAR0 <= a < BAR0 + 0x1000000:
                yield ('W', float(p[2]), a - BAR0, p[5])


def trans(path):
    groups, marks = [], []
    for e in bar0_writes(path):
        if e[0] == 'MARK':
            marks.append((e[1], e[2][:60]))
            continue
        _, t, o, v = e
        if o not in KEY:
            continue
        if groups and t - groups[-1][-1][0] < 0.5:
            groups[-1].append((t, KEY[o], v))
        else:
            groups.append([(t, KEY[o], v)])
    for g in groups:
        before = [m for m in marks if m[0] <= g[0][0]]
        muxes = [v for _, k, v in g if k == 'mux']
        print('%9.3f  n=%3d  mux=%-40s | %s' % (g[0][0], len(g), ','.join(muxes[:7]), before[-1][1] if before else '-'))


def seq(path, t0, before_ms, after_ms):
    lo, hi = t0 - before_ms / 1000, t0 + after_ms / 1000
    for e in bar0_writes(path):
        if e[0] != 'W':
            continue
        _, t, o, v = e
        if t < lo:
            continue
        if t > hi:
            break
        if 0x137000 <= o < 0x138000 or 0x020100 <= o < 0x020200 or o in (0x132000, 0x132004, 0x070000):
            print('%9.3f %06x %s' % ((t - t0) * 1000, o, v))


def mux(path):
    mux_val, pending, events, cycles, cur = None, None, [], 0, None
    for p in lines(path):
        if not p:
            continue
        if p[0] == 'MARK':
            txt = ' '.join(p[2:])
            if 'цикл' in txt and 'максимум' in txt:
                cycles += 1
                cur = txt.split('цикл', 1)[1].split(':', 1)[0].strip()
            continue
        if len(p) < 6 or p[4] != '0xf4137100':
            continue
        t, v = float(p[2]), int(p[5], 16)
        if p[0] == 'W':
            if mux_val is not None and (mux_val & 1) and not (v & 1):
                pending = (t, v, cur)
            mux_val = v
        elif p[0] == 'R':
            if pending and t - pending[0] < 0.01:
                events.append((pending[0], pending[1], v, (t - pending[0]) * 1e6, pending[2]))
                pending = None
            mux_val = v if mux_val is None else mux_val
    stuck = [e for e in events if e[2] & 1]
    print('циклов сценария: %d; переключений GPC с PLL на делитель: %d; застреваний (бит 0 в чтении): %d'
          % (cycles, len(events), len(stuck)))
    if events:
        d = sorted(e[3] for e in events)
        print('чтение после записи: через %.0f…%.0f мкс (медиана %.0f)' % (d[0], d[-1], d[len(d) // 2]))
    for e in stuck:
        print('  ЗАСТРЯЛ: %.6f с, цикл %s: записано %#x, прочитано %#x через %.0f мкс' % (e[0], e[4], e[1], e[2], e[3]))
    if cycles:
        per = collections.Counter(e[4] for e in events)
        miss = [c for c in range(1, cycles + 1) if per.get(str(c), 0) == 0]
        print('циклов без спуска GPC: %d%s' % (len(miss), (' (первые: ' + ' '.join(map(str, miss[:20])) + ')') if miss else ''))


def init_writes(path):
    """Записи от метки «загрузка драйвера» прохода записи до метки «0 максимум» того же прохода."""
    on = False
    vals, bulk = collections.defaultdict(collections.Counter), collections.Counter()
    for e in bar0_writes(path):
        if e[0] == 'MARK':
            if 'запись' in e[2] and 'загрузка драйвера' in e[2]:
                on = True
            elif on and '0 максимум' in e[2]:
                break
            continue
        if not on:
            continue
        _, t, o, v = e
        if o in BULK or 0x00e000 <= o < 0x00f000:
            bulk[BULK.get(o, 'I2C/GPIO 0x00e')] += 1
        else:
            vals[o][v] += 1
    return vals, bulk


def init(a, b):
    va, ba = init_writes(a)
    vb, bb = init_writes(b)
    print('массовые записи (порты прошивок, I2C):', dict(ba), '|', dict(bb))
    print('регистров BAR0 с записями: %d | %d' % (len(va), len(vb)))
    only_a = sorted(set(va) - set(vb))
    only_b = sorted(set(vb) - set(va))
    print('только в А (%d):' % len(only_a), ' '.join('%06x' % o for o in only_a[:80]))
    print('только в Б (%d):' % len(only_b), ' '.join('%06x' % o for o in only_b[:80]))
    diff = [o for o in sorted(set(va) & set(vb)) if set(va[o]) != set(vb[o])]
    print('общие регистры с разными значениями (%d):' % len(diff))
    for o in diff[:120]:
        print('  %06x  А: %s  |  Б: %s' % (o, ','.join(sorted(va[o])[:6]), ','.join(sorted(vb[o])[:6])))


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    if cmd == 'trans':
        trans(sys.argv[2])
    elif cmd == 'seq':
        seq(sys.argv[2], float(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5]))
    elif cmd == 'mux':
        mux(sys.argv[2])
    elif cmd == 'init':
        init(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__ or 'trans | seq | mux | init')
