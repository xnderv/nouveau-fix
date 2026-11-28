#!/usr/bin/env python3
# ЧАСТОТЫ ХАБА, ШИНЫ XBAR И ПАМЯТИ В ЗАПИСЯХ NVIDIA ВОКРУГ СМЕНЫ ПАМЯТИ (28.11.2026), Fermi, Kepler, Maxwell.
# Вопрос владельца: бывает ли у следующих поколений (где NVIDIA сначала поднимает шину, потом память) тот же разрыв
# частот, что вешает нашу GF114 — быстрые хаб и шина над медленной памятью.
# Способ: по трассе ведётся состояние регистров тактов (чтения и записи хоста, плюс записи внутри скриптов памяти PMU) и
# по нему считаются частоты так же, как их читает nouveau (clk/gf100.c и clk/gk104.c: read_pll, read_div, read_vco,
# read_clk, read_mem). Отметки снимаются после каждой записи в переключатель источников 0x137100 и до/после каждого
# скрипта памяти. Для каждой записи печатаются самые большие разрывы «шина ÷ память» и «хаб ÷ память» среди отметок, где
# шина быстрее памяти, и частоты в этот момент. Только чтение; участники обезличены; пути базы не печатаются.
#   python3 -I lab/db-clock-ratios.py [поколения через запятую = Fermi,Kepler,Maxwell] [МЕТКА ...]
# СОСТОЯНИЕ НА 28.11: НЕ ГОТОВО. Частоты узлов ядра считаются верно (сверено: наша GF114 — хаб 1645, шина 270/810,
# системный 1645; GT 630 тестировщика — хаб 1282, шина 1594). Частота ПАМЯТИ считается неверно: на нашей карте выходит
# «135 всегда» и 8019 вместо 135 / 324 / 2004 — состояние регистров памяти после скрипта восстанавливается неправильно
# (выбор источника 0x1373f0 и делитель P у 0x132000 на железе ведут себя не так, как в чтении nouveau). Пока это не
# исправлено, разрывы «÷ память» в выводе верить нельзя; для Kepler и Maxwell проверки нет вовсе.
# Кварц принят 27 МГц. Отметка, для которой не все нужные регистры встречались в трассе, пропускается.
import sys, os, json, subprocess, concurrent.futures
OUT = os.environ.get('MEMSURVEY') or os.path.expanduser('~/Home/nouveau-archive/mem-survey')
DB = os.environ.get('TRACEDB') or os.path.expanduser('~/Home/nouveau-archive/nouveau_vbios_trace')
inv = json.load(open(OUT + '/inventory.json')); key = json.load(open(OUT + '/inventory-key.json'))
XTAL = 27000


def opener(rel):
    f, _, mem = rel.partition(':'); p = os.path.join(DB, f)
    with open(p, 'rb') as h: m = h.read(6)
    if not mem: return ['xz', '-dc', p] if m.startswith(b'\xfd7zXZ') else ['cat', p]
    if m.startswith(b'\xfd7zXZ'): return ['tar', '-xOJf', p, mem]
    if m.startswith(b'BZh'): return ['tar', '-xOjf', p, mem]
    return ['sh', '-c', 'tar -xOzf "$0" "$1" | (xz -dc 2>/dev/null || cat)', p, mem]


class Miss(Exception): pass


class Clk:
    def __init__(self, st, kepler): self.st = st; self.kepler = kepler
    def rd(self, a):
        if a not in self.st: raise Miss(a)
        return self.st[a]
    def vco(self, dsrc): return self.pll(0x00e800) if not self.rd(dsrc) & 0x100 else self.pll(0x00e820)
    def pll(self, pll):
        ctrl, coef = self.rd(pll), self.rd(pll + 4)
        P, N, M = coef >> 16 & 0x3f, coef >> 8 & 0xff, coef & 0xff
        if not ctrl & 1: return 0
        fn = 0xf000
        if pll in (0x00e800, 0x00e820): s = XTAL; P = 1
        elif pll == 0x132000:
            s = self.pll(0x132020)
            if self.kepler: P = 2 if coef & 0x10000000 else 1
        elif pll == 0x132020:
            s = self.div(0, 0x137320, 0x137330)
            if self.kepler: fn = self.st.get(pll + 0x10, 0xf0000000) >> 16
        elif pll in (0x137000, 0x137020, 0x137040, 0x1370e0): s = self.div((pll & 0xff) // 0x20, 0x137120, 0x137140)
        else: return 0
        P = P or 1
        if not M: return 0
        return (s * N + ((((fn + 4096) & 0xffff) * s) >> 13)) // (M * P)
    def div(self, doff, dsrc, dctl):
        ssrc = self.rd(dsrc + doff * 4)
        k = ssrc & 3
        if k == 0: return XTAL if (ssrc & 0x00030000) != 0x00030000 else 108000
        if k == 2: return 100000
        if k == 3:
            sctl = self.st.get(dctl + doff * 4, 0)    # у узлов 7 и 8 NVIDIA этот регистр не трогает: делителя нет
            v = self.vco(dsrc + doff * 4)
            return v * 2 // ((sctl & 0x3f) + 2) if sctl & 0x80000000 else v
        return 0
    def clk(self, idx):
        sctl = self.st.get(0x137250 + idx * 4, 0)
        if not self.kepler:                                 # Fermi (clk/gf100.c): узлы 7 и 8 на PLL узла 7
            if self.rd(0x137100) & (1 << idx):
                s = self.pll(0x137000 + idx * 0x20 if idx < 7 else 0x1370e0); sd = (sctl >> 8 & 0x3f) + 2
            else:
                s = self.div(idx, 0x137160, 0x1371d0); sd = (sctl & 0x3f) + 2
            return s * 2 // sd if sctl & 0x80000000 else s
        if idx < 7:
            if self.rd(0x137100) & (1 << idx): s = self.pll(0x137000 + idx * 0x20); sd = 1
            else: s = self.div(idx, 0x137160, 0x1371d0); sd = 0
        else:
            ssrc = self.rd(0x137160 + idx * 4)
            s = self.div(idx, 0x137160, 0x1371d0); sd = 0
            if (ssrc & 3) == 3 and ssrc & 0x100:
                if ssrc & 0x40000000: s = self.pll(0x1370e0)
                sd = 1
        if sctl & 0x80000000:
            return s * 2 // (((sctl >> 8 & 0x3f) if sd else (sctl & 0x3f)) + 2)
        return s
    def mem(self):
        if self.kepler:
            k = self.rd(0x1373f4) & 0xf
            return self.pll(0x132020) if k == 1 else self.pll(0x132000) if k == 2 else 0
        return self.pll(0x132000) if self.rd(0x1373f0) & 2 else self.div(0, 0x137300, 0x137310)


def parse(w):
    i, ops, nw = 0, [], 0
    while i < len(w):
        ln, op = w[i] >> 16, w[i] & 0xffff
        if ln == 0 or i + ln > len(w) + 1 or op > 0xff: return None
        a = w[i + 1:i + ln]
        if op == 0x21 and len(a) % 2: return None
        ops.append((op, a)); nw += len(a) // 2 if op == 0x21 else 0
        if op == 0x16: return ops if nw >= 5 else None
        i += ln


def want(a):
    return 0x137000 <= a < 0x137400 or 0x132000 <= a < 0x132040 or a in (0x00e800, 0x00e804, 0x00e820, 0x00e824)


def one(lab):
    r = inv[lab]; bar0 = int(r['bar0'], 16); kep = r['gen'] != 'Fermi'
    st = {}; marks = []; cur = None
    def mark(kind):
        c = Clk(st, kep)
        try: marks.append((kind, c.clk(8) // 1000, c.clk(2) // 1000, c.clk(7) // 1000, c.mem() // 1000))
        except Miss: pass
    pr = subprocess.Popen(opener(key[lab]), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    for raw in pr.stdout:
        if raw[:2] not in (b'W ', b'R '): continue
        p = raw.split()
        if len(p) < 6: continue
        try: a = int(p[4], 16) - bar0; v = int(p[5], 16)
        except ValueError: continue
        if not 0 <= a < 0x1000000: continue
        wr = raw[0] == 87
        if wr and a == 0x10a1c4 and cur is not None: cur.append(v); continue
        if cur is not None and wr:
            ops = parse(cur); cur = None
            if ops and any(0x100000 <= x[k] < 0x101000 or 0x10f000 <= x[k] < 0x130000 or 0x132000 <= x[k] < 0x133000
                           for op, x in ops if op == 0x21 for k in range(0, len(x), 2)):
                mark('до скрипта')
                for op, x in ops:
                    if op == 0x21:
                        for k in range(0, len(x), 2):
                            if want(x[k]): st[x[k]] = x[k + 1]
                mark('после скрипта')
        if wr and a == 0x10a1c0: cur = []; continue
        if want(a):
            st[a] = v
            if wr and a == 0x137100: mark('переключатель')
    pr.stdout.close(); pr.wait()
    return lab, marks


def main():
    a = sys.argv[1:]
    gens = a[0].split(',') if a and not a[0].startswith('nv') else ['Fermi', 'Kepler', 'Maxwell']
    labs = [x for x in a if x.startswith('nv')] or [l for l, r in inv.items() if r['gen'] in gens and r.get('pmu_scripts')]
    labs.sort(key=lambda l: (l.split('#')[0], int(l.split('#')[1])))
    res = {}
    with concurrent.futures.ProcessPoolExecutor(4) as ex:
        for lab, marks in ex.map(one, labs): res[lab] = marks
    json.dump(res, open(OUT + '/clock-ratios.json', 'w'))
    print(f"{'метка':10} {'откуда':10} {'чип':6} отметок | наибольший разрыв шина÷память (хаб / шина / память, МГц) | наибольший хаб÷память | уровни памяти, МГц")
    for lab in labs:
        m = [x for x in res[lab] if x[2] and x[4] and x[1] and x[0] != 'переключатель']    # только границы скриптов памяти
        if not m: print(f"{lab:10} {inv[lab].get('src', 'база'):10} {inv[lab]['chip']:6} нет отметок с известными частотами"); continue
        bx = max(m, key=lambda x: x[2] / x[4]); bh = max(m, key=lambda x: x[1] / x[4])
        mems = sorted({x[4] for x in m})
        print(f"{lab:10} {inv[lab].get('src', 'база'):10} {inv[lab]['chip']:6} {len(m):5}   | {bx[2] / bx[4]:5.1f} ({bx[1]} / {bx[2]} / {bx[4]}, {bx[0]}) | {bh[1] / bh[4]:5.1f} ({bh[1]} / {bh[2]} / {bh[4]}) | {mems[:6]}")


if __name__ == '__main__':
    main()
