#!/usr/bin/env python3
# Генератор скриптов памяти GF11x, этап 2: собрать скрипты A–E для ЛЮБОЙ платы семейства из её VBIOS и ремешка памяти,
# по разметке этапа 1 (lab/memgen.py): скелет и константы семейства — из наших скриптов (запись NVIDIA на GF114),
# формулы — из таблиц VBIOS платы, «база платы» — из devinit VBIOS платы по ремешку, управляющие биты — по шагам скелета.
# Только чтение файлов. Самопроверка: на нашей VBIOS (ремешок 3) обязан побайтно повторить наши скрипты.
#   python3 -I lab/memgen2.py ОБРАЗ.rom РЕМЕШОК ЛАБ/ramgf100.c ЧИСТЫЙ/ramgf100.c [--emit ВЫХОД.json] [--quiet]
#   python3 -I lab/memgen2.py --corpus КАТАЛОГ РЕМЕШОК ЛАБ/ramgf100.c ЧИСТЫЙ/ramgf100.c [--pci 10de:1200]
import sys, os, re, struct, json, collections, importlib.util

HERE = os.path.dirname(os.path.abspath(__file__))
def load(name):
    sp = importlib.util.spec_from_file_location(name, os.path.join(HERE, name + '.py')); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m); return m
vd = load('vbios-devinit')

SCR = {'A': ('lab_nv_scrA', '03', '07'), 'B': ('lab_nv_scrB', '07', '0f'), 'C': ('lab_nv_scrC', '0f', '07'),
       'D': ('lab_nv_scrD', '07', '07'), 'E': ('lab_nv_scrE', '07', '03')}
CTRL = {0x10f200: 0x00009800, 0x10f830: 0x41700007, 0x10f824: 0x000007a3, 0x10f808: 0x72a80000, 0x1373ec: 0x00030f0f,
        0x1373f8: 0x000020ff, 0x10f800: 0x00002004, 0x10f614: 0xf0000100, 0x10f610: 0xf0000100}
CAND = {0x100c00, 0x00e108, 0x00e280, 0x10f610, 0x10f614, 0x10f604}
lo, hi = (lambda x: x & 0xf), (lambda x: x >> 4)

def formulas(FREQ):
    """формулы этапа 1 (two-cards-method.md): регистр -> (маска, f(T, R, M)); FREQ — целевая частота памяти, МГц"""
    F = {
        0x10f290: (0xffffffff, lambda T, R, M: T[9] << 24 | T[7] << 17 | T[5] << 8 | T[3]),
        0x10f294: (0x03ffc07f, lambda T, R, M: T[11] << 20 | T[10] << 14 | T[2]),
        0x10f298: (0x00ffff00, lambda T, R, M: T[0] << 16 | T[1] << 8),
        0x10f29c: (0xffffffff, lambda T, R, M: T[20] << 9 | T[21] << 5 | T[13]),
        0x10f2a0: (0x001f8000, lambda T, R, M: T[12] << 15),
        0x10f300: (0x00000f78, lambda T, R, M: (T[2] - 5) << 3 | (T[0] - 4) << 8),
        0x10f330: (0x0000003f, lambda T, R, M: (T[22] & 3) << 4 | (T[14] & 7) << 2 | (T[14] & 0x30) >> 4),
        0x10f338: (0x00000020, lambda T, R, M: (1 if FREQ < 1000 else 0) << 5),
        0x10f344: (0x00000ff1, lambda T, R, M: R[12] << 4 | (R[3] >> 6) & 1),
        0x10f348: (0x00000088, lambda T, R, M: ((R[4] >> 5) & 1) << 7 | ((R[3] >> 5) & 1) << 3),
        0x10f870: (0xffffffff, lambda T, R, M: lo(R[0x0d]) * 0x11111111),
        0x10f640: (0xffffffff, lambda T, R, M: hi(R[7]) * 0x11111111),
        0x10f644: (0xffffffff, lambda T, R, M: lo(R[7]) * 0x11111111),
        0x10f628: (0xffffffff, lambda T, R, M: hi(R[5]) * 0x11111111),
        0x10f62c: (0xffffffff, lambda T, R, M: lo(R[5]) * 0x11111111),
        0x1373ec: (0x00020f0f, lambda T, R, M: (0 if (R[2] >> 4) & 1 else 1) << 17 | lo(R[0x0b]) * 0x101),
        0x10f610: (0x00000100, lambda T, R, M: ((R[2] >> 1) & 1) << 8),
        0x10f614: (0x00000100, lambda T, R, M: (R[2] & 1) << 8),
        0x10f808: (0x32a00000, lambda T, R, M: 0 if (R[2] >> 2) & 1 else 0x32a00000),
        0x10f604: (0xf1000000, lambda T, R, M: (0xf0000000 if (R[2] >> 5) & 1 else 0) | (0 if (R[2] >> 2) & 1 else 0x01000000)),
        0x137310: (0x08003f00, lambda T, R, M: (0x08000000 | 0x0800) if FREQ >= 1000 else ((3240 // FREQ - 2) << 8)),
        0x1373f8: (0x000000ff, lambda T, R, M: (R[2] & 1) * 0x55),
        0x100c00: (0x08000000, lambda T, R, M: ((R[4] >> 3) & 1) << 27),
        0x00e108: (0x00000f00, lambda T, R, M: 0x300 if (T[14] & 7) == 0 else 0x600),
        0x10f630: (0xffffffff, lambda T, R, M: hi(R[6]) * 0x11111111),
        0x10f634: (0xffffffff, lambda T, R, M: lo(R[6]) * 0x11111111),
        0x00e280: (0xf0000000, lambda T, R, M: (0x3 if (R[4] >> 3) & 1 else 0x2) << 28),
    }
    for i in range(8):
        F[0x10fc20 + i * 0xc] = (0xffffffff, lambda T, R, M: lo(R[0x0a]))
    return F

class Vbios:
    def __init__(self, path, strap):
        self.b = b = open(path, 'rb').read(); self.rom = vd.Rom(b); self.strap = strap
        r8, r16, r32 = self.rom.r8, self.rom.r16, self.rom.r32
        self.po = self.rom.A(self.rom.ent['P'][2])
        self.rammap, self.timing = self.rom.A(r32(self.po + 4)), self.rom.A(r32(self.po + 8))
        self.rh, self.rl, self.rs, self.rn, self.rc = (r8(self.rammap + k) for k in (1, 2, 3, 4, 5))
        self.th, self.tc, self.tl = r8(self.timing + 1), r8(self.timing + 2), r8(self.timing + 3)
        # уровни: частота памяти по id уровня (таблица 0x40)
        perf = self.rom.A(r32(self.po)); hdr, ln, cnt, snr, ssz = (r8(perf + k) for k in (1, 2, 3, 4, 5))
        self.mem = {}
        for i in range(cnt):
            e = perf + hdr + i * (ln + snr * ssz); lid = r8(e)
            if lid == 0xff: continue
            # подзапись 5 — память (DOM в vbios-survey); частота в кГц/10? нет: в МГц, биты 0-13
            sub = e + ln + 5 * ssz
            self.mem[f'{lid:02x}'] = r16(sub) & 0x3fff
        # сценарий BIT P + 0x1c (группы 0x8f по ремешку) — тоже формулы-константы по ремешку
        self.unk1c = {}
        cntM = self.rom.ramcfg_count()
        o = r16(self.po + 0x1c)
        if o:
            o = self.rom.A(o)
            while o < len(b) and r8(o) == 0x8f:
                addr, incr, num = r32(o + 1), r8(o + 5), r8(o + 6); o += 7
                for k2 in range(num):
                    self.unk1c[addr + k2 * incr] = r32(o + 4 * strap); o += 4 * cntM
        # devinit по ремешку: состояние регистров после POST — записи скриптов инициализации по порядку (zm_* ставят
        # значение, nv_reg/andn/or — по маске, ram_restrict — запись нашего ремешка); операции, зависящие от чтений
        # (copy_nv_reg, xlat, zm_mask_add), пропускаются — такие регистры помечены как неточные
        wr = []; vis = set()
        for i, s in enumerate(self.rom.scripts()):
            vd.walk(self.rom, self.rom.A(s), wr, vis, 0, i)
        self.devinit = {}; self.devinit_unsure = set()
        for w in wr:
            op = w.get('op'); a = w.get('reg')
            if op in ('zm_reg', 'zm_reg_sequence', 'zm_reg_group', 'zm_reg16', 'macro', 'zm_reg_indirect'): self.devinit[a] = w['val']
            elif op == 'ram_restrict_zm_reg_group':
                if w.get('strap') == strap: self.devinit[a] = w['val']
            elif op == 'nv_reg': self.devinit[a] = (self.devinit.get(a, 0) & w['mask']) | w['val']
            elif op == 'andn_reg': self.devinit[a] = self.devinit.get(a, 0) & ~w['mask'] & 0xffffffff
            elif op == 'or_reg': self.devinit[a] = self.devinit.get(a, 0) | w['mask']
            elif op in ('copy_nv_reg', 'xlat', 'zm_mask_add', 'copy_zm_reg', 'idx_addr_latched', 'reset'): self.devinit_unsure.add(a)
    def tables(self, mhz):
        r8, r16 = self.rom.r8, self.rom.r16
        for i in range(self.rc):
            e = self.rammap + self.rh + i * (self.rl + self.rn * self.rs)
            if r16(e) <= mhz <= r16(e + 2):
                M = self.b[e:e + self.rl]; R = self.b[e + self.rl + self.strap * self.rs:e + self.rl + (self.strap + 1) * self.rs]
                T = self.b[self.timing + self.th + R[1] * self.tl:self.timing + self.th + (R[1] + 1) * self.tl] if R[1] != 0xff else bytes(self.tl)
                return T, R, M
        raise ValueError(f'нет записи rammap для {mhz} МГц')

def ramcfg_index(rom, raw_strap):
    """сырой ремешок (биты 2–5 регистра 0x101000) -> индекс ramcfg, как nvbios_ramcfg_index (BIT M v2: таблица M0203 или xlat)"""
    if 'M' not in rom.ent: return raw_strap
    ver, ln, off = rom.ent['M']; o = rom.A(off)
    if ver == 2 and ln >= 7:
        t = rom.r16(o + 3)
        if t:
            t = rom.A(t)
            if rom.r8(t) == 0x10:
                hdr, el, cnt, typ = rom.r8(t + 1), rom.r8(t + 2), rom.r8(t + 3), rom.r8(t + 4)
                for i in range(cnt):
                    e = t + hdr + i * el
                    if (rom.r8(e) & 0x0f) == (typ & 0x0f) and (rom.r8(e) >> 4) == raw_strap:
                        return rom.r8(e + 1) & 0x0f
    xlat = rom.r16(o + 1) if ver == 2 and ln >= 3 else (rom.r16(o + 3) if ver == 1 and ln >= 5 else 0)
    return rom.r8(rom.A(xlat) + raw_strap) if xlat else raw_strap

def decode(w):
    i, ops = 0, []
    while i < len(w):
        ln, op = w[i] >> 16, w[i] & 0xffff; a = w[i + 1:i + ln]
        if op == 0x21: ops += [('WR', a[k], a[k + 1]) for k in range(0, len(a), 2)]
        elif op == 0x16: ops.append(('END',)); break
        else: ops.append((f'OP{op:02x}', *a))
        i += ln
    return ops

def pll_nm(freq, ref=594.0, mmax=16, nmax=255):
    best = None
    for m in range(1, mmax + 1):
        n = round(freq * m / ref)
        if 1 <= n <= nmax:
            err = abs(ref * n / m - freq)
            if best is None or err < best[0]: best = (err, n, m)
    return best

def classify(ref_vb, arrs, nv):
    """разметка этапа 1 на нашей плате: для каждой записи скелета — метка и маска"""
    allvals = collections.defaultdict(set)
    for k, (n, l0, l1) in SCR.items():
        for o in decode(arrs[n]):
            if o[0] == 'WR': allvals[o[1]].add(o[2])
    skel = {}
    for k, (n, l0, l1) in SCR.items():
        f1 = ref_vb.mem[l1]; F = formulas(f1); T, R, M = ref_vb.tables(f1)
        ops = decode(arrs[n]); last = {o[1]: o[2] for o in ops if o[0] == 'WR'}
        out = []
        for o in ops:
            if o[0] != 'WR': out.append(dict(op=o)); continue
            a, v = o[1], o[2]; tag, mask = None, 0
            if a in (0x10fe24, 0x132004): tag, mask = 'PLL', 0xffff
            elif a in ref_vb.unk1c: tag, mask = 'Ф', 0xffffffff
            elif a in F and v == last[a]:
                mask, fn = F[a]
                tag = ('Фк' if a in CAND else 'Ф') if (v & mask) == (fn(T, R, M) & mask) else 'Ф✘'
            if tag is None and v in nv.get(a, ()): tag = 'Ч'
            if tag is None and len(allvals[a]) == 1: tag = 'Ч1'
            if tag is None and a in CTRL and len({x & ~CTRL[a] for x in allvals[a]}) == 1: tag, mask = 'П', ~CTRL[a] & 0xffffffff
            if tag is None: tag = 'N'
            item = dict(op=('WR', a, v), tag=tag, mask=mask)
            if tag in ('Ф', 'Фк') and mask != 0xffffffff:
                base_ours = ref_vb.devinit.get(a)
                ctrl = CTRL.get(a, 0)
                item['base_devinit'] = base_ours is not None and ((v ^ base_ours) & ~mask & ~ctrl & 0xffffffff) == 0
            out.append(item)
        skel[k] = out
    return skel

def generate(vb, skel):
    """скрипты для платы vb по скелету; возвращает {скрипт: [(op...), ...]}, замечания"""
    notes = collections.Counter(); gen = {}
    for k, (n, l0, l1) in SCR.items():
        f1 = vb.mem.get(l1)
        if f1 is None: notes['нет уровня ' + l1] += 1; gen[k] = None; continue
        F = formulas(f1)
        try: T, R, M = vb.tables(f1)
        except ValueError as e: notes[str(e)] += 1; gen[k] = None; continue
        ops = []
        for item in skel[k]:
            o = item['op']
            if o[0] != 'WR': ops.append(o); continue
            a, v, tag, mask = o[1], o[2], item['tag'], item['mask']
            if tag == 'PLL':
                # опора MPLL: REFPLL платы после POST (devinit 0x10fe24: 405·N/M), если скрипт её не перепрограммирует иначе
                refpll = 594.0
                rp = vb.devinit.get(0x10fe24)
                if rp and (rp & 0xff): refpll = 405.0 * ((rp >> 8) & 0xff) / (rp & 0xff)
                want = f1 if a == 0x132004 else 594
                err, N, Mv = pll_nm(want, refpll if a == 0x132004 else 405.0)
                v = (v & ~0xffff) | (N << 8) | Mv; notes['PLL пересчитан'] += 1
            elif tag in ('Ф', 'Фк') or (tag == 'П' and a in F):
                use_dev = item.get('base_devinit') or tag == 'П'
                base = vb.devinit.get(a, v) if use_dev else v   # база (биты вне формулы): devinit платы, если на нашей это проверено; иначе как у нас
                if a in vb.unk1c and mask == 0xffffffff: v = vb.unk1c[a]; notes['формула'] += 1
                elif a in F:
                    fm, fn = F[a]
                    v = (base & ~fm) | (fn(T, R, M) & fm)
                    if a in CTRL: v = (v & ~CTRL[a]) | (o[2] & CTRL[a])   # управляющие биты шага — по скелету
                    notes['формула' + (' (база devinit)' if use_dev and a in vb.devinit else ' (база как у нас)')] += 1
                else: notes[f'нет в сценарии 0x1c: {a:06x} (оставлено как у нас)'] += 1
            elif tag == 'П':
                base = vb.devinit.get(a)
                if base is None: notes[f'нет devinit для {a:06x}'] += 1
                else: v = (base & mask) | (v & ~mask); notes['база из devinit'] += 1
            elif tag in ('Ч', 'Ч1'): notes['константа'] += 1
            else: notes['число (как у нас)'] += 1
            ops.append(('WR', a, v))
        gen[k] = ops
    return gen, notes

def compare(gen, arrs):
    diffs = {}
    for k, (n, l0, l1) in SCR.items():
        ref = decode(arrs[n]); g = gen.get(k)
        if g is None: diffs[k] = 'не собран'; continue
        d = [(i, r, x) for i, (r, x) in enumerate(zip(ref, g)) if r != x]
        diffs[k] = d + ([('len', len(ref), len(g))] if len(ref) != len(g) else [])
    return diffs

def load_arrays(lab_c):
    src = open(lab_c).read()
    return {m.group(1): [int(x, 16) for x in re.findall(r'0x[0-9a-fA-F]+', m.group(2))] for m in re.finditer(r'static const u32 (lab_nv_scr\w)\[\] = \{(.*?)\};', src, re.S)}

def load_nv(nv_c):
    nv = collections.defaultdict(set); s = open(nv_c).read()
    for m in re.finditer(r'ram_wr32\(fuc, (0x[0-9a-f]+), (0x[0-9a-f]+)\)', s): nv[int(m.group(1), 16)].add(int(m.group(2), 16))
    for a_, v_ in ((0x100760, 0xff00ff00), (0x100764, 0x0000ff00), (0x100768, 0xff00ff00)): nv[a_].add(v_)
    for m in re.finditer(r'gf100_ram_train\(fuc, (0x[0-9a-f]+)\)', s): nv[0x10f910].add(int(m.group(1), 16)); nv[0x10f914].add(int(m.group(1), 16))
    return nv

def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]; flags = {a: True for a in sys.argv[1:] if a.startswith('--')}
    emit = next((sys.argv[i + 1] for i, a in enumerate(sys.argv) if a == '--emit'), None)
    pci = next((sys.argv[i + 1] for i, a in enumerate(sys.argv) if a == '--pci'), None)
    if emit: args.remove(emit)
    if pci: args.remove(pci)
    corpus = '--corpus' in flags
    target, strap, lab_c, nv_c = args[0], int(args[1]), args[2], args[3]
    ours = os.path.expanduser('~/Home/nouveau-archive/vbios.rom')
    arrs, nv = load_arrays(lab_c), load_nv(nv_c)
    ref_vb = Vbios(ours, 3); skel = classify(ref_vb, arrs, nv)
    tags = collections.Counter(it['tag'] for k in skel for it in skel[k] if 'tag' in it)
    print('скелет (наша плата, ремешок 3): записей', sum(tags.values()), dict(tags))
    if not corpus:
        vb = Vbios(target, strap); gen, notes = generate(vb, skel); diffs = compare(gen, arrs)
        print(f'цель {os.path.basename(target)} pci {vb.rom.ven:04x}:{vb.rom.dev:04x} ремешок {strap}; память по уровням {vb.mem}; devinit по ремешку: {len(vb.devinit)} регистров')
        print('замечания:', dict(notes))
        for k in SCR:
            d = diffs[k]
            if d == 'не собран': print(f'  {k}: не собран'); continue
            print(f'  {k}: отличий от наших скриптов {len(d)}' + (': ' + '; '.join(f'#{i} {r} -> {x}' if i != 'len' else f'длина {r} -> {x}' for i, r, x in d[:6]) if d else ''))
        if emit:
            json.dump({k: {'ops': [list(o) for o in (gen[k] or [])], 'tags': [it.get('tag') for it in skel[k]]} for k in SCR}, open(emit, 'w'), indent=0); print('скрипты записаны в', emit)
        return
    import glob
    stats = collections.Counter(); fails = []
    for f in sorted(glob.glob(os.path.join(target, '*.rom'))):
        try:
            vb = Vbios(f, strap)
        except Exception as e: fails.append((os.path.basename(f), 'VBIOS: ' + str(e)[:60])); continue
        if pci and f'{vb.rom.ven:04x}:{vb.rom.dev:04x}' != pci: continue
        try: gen, notes = generate(vb, skel)
        except Exception as e: fails.append((os.path.basename(f), 'сборка: ' + repr(e)[:80])); stats['ошибка сборки'] += 1; continue
        ok = all(gen[k] is not None for k in SCR)
        stats['плат'] += 1; stats['все 5 скриптов собраны' if ok else 'не все'] += 1
        for k2, v2 in notes.items():
            if k2.startswith('нет'): stats[k2] += v2
        if not ok: fails.append((os.path.basename(f), [k for k in SCR if gen[k] is None], dict(notes)))
    print('корпус', target, ':', dict(stats))
    for f in fails[:10]: print('  ', f)

if __name__ == '__main__':
    main()
