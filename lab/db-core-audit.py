#!/usr/bin/env python3
# АУДИТ ЯДРА ПО БАЗЕ (18.11): три места драйвера, где значения пока заданы числом, а не из VBIOS / правила.
#   1 — выход из скобки замедления: что NVIDIA пишет в 0x020160/164, 0x020180/184, 0x0201a0/1a4 после переключателя —
#       то же ли, что было в регистре до первой скобки (состояние после init-скрипта VBIOS), или постоянная;
#       CTRL_1 (0x020004): какие биты снимаются на входе и возвращается ли прежнее значение;
#   2 — ступень перед PLL GPC: частота делительного пути GPC в момент записи 0x137100 бит 0 = 1 (у нас VCO/4 = 405);
#   3 — делитель GPC, пока GPC на PLL: частота делительного пути (у нас поле A = 06, VCO/4).
# Только чтение записей; участники обезличены, пути не выводятся. Класс Д (чужие записи).
#   python3 -I lab/db-core-audit.py
import collections, os, sys, importlib.util
from multiprocessing import Pool

HERE = os.path.dirname(os.path.abspath(__file__))
def _load(name, file):
    s = importlib.util.spec_from_file_location(name, os.path.join(HERE, file)); m = importlib.util.module_from_spec(s)
    s.loader.exec_module(m); return m
dc = _load('dc', 'db-core-check.py')
tv = dc.tv
NAMES = {'nvc0': 'GF100', 'nvc1': 'GF108', 'nvc3': 'GF106', 'nvc4': 'GF104', 'nvc8': 'GF110', 'nvce': 'GF114',
         'nvcf': 'GF116', 'nvd7': 'GF117', 'nvd9': 'GF119'}
FS = (0x020160, 0x020164, 0x020180, 0x020184, 0x0201a0, 0x0201a4)

def gpc_path(r):
    """частота делительного пути GPC, кГц (основной делитель 0x1371d0 и пост-делитель 0x137250), и VCO"""
    s = r.get(0x137160, 0)
    if s & 3 != 3:
        return 0, 0
    vco = dc.sppll(r, s)
    d = r.get(0x1371d0, 0)
    a = ((d >> 8) if s & 0x100 else d) & 0x3f
    f = vco * 2 // (a + 2) if d & 0x80000000 else vco
    p = r.get(0x137250, 0)
    if p & 0x80000000:
        f = f * 2 // ((p & 0x3f) + 2)
    return f, vco

def one(job):
    chip, who, i, path = job
    out = collections.Counter()
    try:
        for member, st in dc.streams(path):
            bar, r, boot = None, {}, {}
            br = {}            # i (0 GPC, 1 hub) -> {адрес: число записей в этой скобке}
            ctrl_before = None
            pe = 0; idle = None     # путь GPC на входе в скобку; ждём первую запись делителя после ухода на PLL
            for raw in st:
                if raw.startswith(b'MAP '):
                    f = raw.split()
                    if bar is None and len(f) > 5 and int(f[5], 16) == 0x1000000:
                        bar = int(f[3], 16)
                    continue
                if bar is None or raw[:2] not in (b'W ', b'R '):
                    continue
                p = raw.split()
                if len(p) < 6:
                    continue
                try:
                    a = int(p[4], 16) - bar; v = int(p[5], 16)
                except ValueError:
                    continue
                w = raw[0] == 87
                if a in FS and a not in boot and not br:
                    boot[a] = v                                  # первое увиденное значение до первой скобки
                if w and a in FS:
                    i = (a >> 2) & 1
                    if a in (0x020160, 0x020164) and (v >> 16) & 0x3f and i not in br:
                        if not br:
                            ctrl_before = r.get(0x020004)
                        br[i] = {}
                        if i == 0:
                            pe = gpc_path(r)[0]
                    if i in br:
                        k = br[i].get(a, 0) + 1
                        br[i][a] = k
                        if k == 2:                               # вторая запись в скобке — выход
                            if a in boot:
                                out[('выход', f'{a:06x}', 'как до первой скобки' if v == boot[a] else f'{v:#x} (до скобок {boot[a]:#x})')] += 1
                            else:
                                out[('выход', f'{a:06x}', f'{v:#x} (до скобок не видно)')] += 1
                            if a in (0x020160, 0x020164):
                                del br[i]
                elif w and a == 0x020004 and ctrl_before is not None:
                    if br and v != ctrl_before:
                        out[('ctrl1 вход: снято', f'{ctrl_before & ~v:#x}', f'поставлено {v & ~ctrl_before:#x}')] += 1
                    elif not br:
                        out[('ctrl1 выход', 'прежнее' if v == ctrl_before else f'{v:#x} при прежнем {ctrl_before:#x}')] += 1
                if w and a == 0x137100:
                    old = r.get(0x137100, 0)
                    if not (old & 1) and (v & 1):
                        f, vco = gpc_path(r)
                        if vco and f:
                            out[('ступень перед PLL', f'вход в скобку {pe // 1000} -> у переключателя {f // 1000} МГц (VCO/{vco / f:.2f})')] += 1
                        idle = 'ждём'
                    elif (old & 1) and not (v & 1) and idle == 'ждём':
                        out[('делитель при GPC на PLL', 'не менялся до спуска')] += 1
                        idle = None
                r[a] = v
                if w and a == 0x1371d0 and (r.get(0x137100, 0) & 1) and idle == 'ждём' and not br:
                    f, vco = gpc_path(r)
                    if vco and f:
                        out[('делитель при GPC на PLL', f'после подъёма {f // 1000} МГц (VCO/{vco / f:.2f})')] += 1
                    idle = None
    except Exception as e:
        out[('ошибка', repr(e)[:80])] += 1
    return chip, out

if __name__ == '__main__':
    jobs = [(c, w, i, os.path.join(tv.DB, t)) for c, w, trs, vbs in tv.boards(0xc0, 0xdf) for i, t in enumerate(trs)]
    jobs += [(c, w, 0, tr) for (c, w), (tr, rom) in dc.EXTRA.items()]
    res = collections.defaultdict(collections.Counter); n = collections.Counter()
    with Pool(4) as pool:
        for chip, c in pool.imap_unordered(one, jobs):
            res[chip].update(c); n[chip] += 1
    for chip in sorted(res):
        print(f'== {NAMES.get(chip, chip)} (записей {n[chip]})')
        for k, v in sorted(res[chip].items()):
            print('  ', ' | '.join(k), '×', v)
