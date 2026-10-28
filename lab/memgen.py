#!/usr/bin/env python3
# Генератор скриптов памяти GF11x, этап 1 — карта покрытия (только чтение файлов, карту не трогает).
# Для каждой записи в скриптах NVIDIA A–E (как они записаны на нашей карте) определяет, откуда берётся значение:
#   ФОРМУЛА  — считается из таблиц VBIOS этой карты (проверено до бита на всех частотах, где регистр пишется);
#   ЧИП      — то же значение в скриптах той же стадии у второй карты (сценарий nouveau) или одно на все скрипты нашей;
#   БАЗА+БИТЫ — постоянная база платы (сохранять с загрузки) + управляющие биты из известных масок (Сплит, разность значений);
#   ЧИСЛО    — пока известно только как число из нашей записи.
# Формулы — docs/2026-10-24/two-cards-method.md (часть — по открытой работе Р. Сплита, 2017).
#   python3 -I lab/memgen.py ПУТЬ/vbios.rom ПУТЬ/ramgf100.c(лабораторный, с массивами lab_nv_*) ПУТЬ/ramgf100.c(чистый nouveau) [ремешок]
import sys, os, re, struct, collections

rom, lab_c, nv_c = sys.argv[1], sys.argv[2], sys.argv[3]
STRAP = int(sys.argv[4]) if len(sys.argv) > 4 else 3
b = open(rom, 'rb').read()
r8 = lambda o: b[o]
r16 = lambda o: struct.unpack_from('<H', b, o)[0]
r32 = lambda o: struct.unpack_from('<I', b, o)[0]

# --- таблицы VBIOS: тайминги (T), ramcfg ремешка (R), rammap (M) по частотному окну
bit = b.find(b'\xff\xb8BIT')
ent = {chr(r8(bit + 12 + i * r8(bit + 9))): (r8(bit + 13 + i * r8(bit + 9)), r16(bit + 14 + i * r8(bit + 9)), r16(bit + 16 + i * r8(bit + 9)))
       for i in range(r8(bit + 10))}
po = ent['P'][2]
rammap, timing = r32(po + 4), r32(po + 8)
rh, rl, rs, rn, rc = r8(rammap + 1), r8(rammap + 2), r8(rammap + 3), r8(rammap + 4), r8(rammap + 5)
th, tc, tl = r8(timing + 1), r8(timing + 2), r8(timing + 3)


def tables(mhz):
    for i in range(rc):
        e = rammap + rh + i * (rl + rn * rs)
        if r16(e) <= mhz <= r16(e + 2):
            M = b[e:e + rl]
            R = b[e + rl + STRAP * rs:e + rl + (STRAP + 1) * rs]
            T = b[timing + th + R[1] * tl:timing + th + (R[1] + 1) * tl] if R[1] != 0xff else bytes(tl)
            return T, R, M
    raise SystemExit(f'нет записи rammap для {mhz} МГц')


# --- скрипты NVIDIA из лабораторного ramgf100.c
src = open(lab_c).read()
arr = {m.group(1): [int(x, 16) for x in re.findall(r'0x[0-9a-fA-F]+', m.group(2))]
       for m in re.finditer(r'static const u32 (lab_nv_scr\w)\[\] = \{(.*?)\};', src, re.S)}


def decode(w):
    i, ops = 0, []
    while i < len(w):
        ln, op = w[i] >> 16, w[i] & 0xffff
        a = w[i + 1:i + ln]
        if op == 0x21:
            ops += [('WR', a[k], a[k + 1]) for k in range(0, len(a), 2)]
        elif op == 0x16:
            break
        else:
            ops.append((f'OP{op:02x}', *a))
        i += ln
    return ops


SCR = {'A': ('lab_nv_scrA', 135, 324), 'B': ('lab_nv_scrB', 324, 2004), 'C': ('lab_nv_scrC', 2004, 324),
       'D': ('lab_nv_scrD', 324, 324), 'E': ('lab_nv_scrE', 324, 135)}

# --- вторая карта: все записи сценария nouveau (обе ветки)
nv = collections.defaultdict(set)
for m in re.finditer(r'ram_wr32\(fuc, (0x[0-9a-f]+), (0x[0-9a-f]+)\)', open(nv_c).read()):
    nv[int(m.group(1), 16)].add(int(m.group(2), 16))
for a_, v_ in ((0x100760, 0xff00ff00), (0x100764, 0x0000ff00), (0x100768, 0xff00ff00)):   # Сплит: «chipset == 0xce»
    nv[a_].add(v_)
for m in re.finditer(r'gf100_ram_train\(fuc, (0x[0-9a-f]+)\)', open(nv_c).read()):   # команды обучения памяти
    nv[0x10f910].add(int(m.group(1), 16)); nv[0x10f914].add(int(m.group(1), 16))

# --- формулы: регистр -> (маска, функция(T, R, M) -> значение); только проверенные до бита
lo, hi = (lambda x: x & 0xf), (lambda x: x >> 4)
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
}
# делитель памяти: поле B = 3240/f - 2 на делителе; на MPLL поле не трогается, ставится бит 27 (FBVDDQ различается в таблице)
F[0x137310] = (0x08003f00, lambda T, R, M: (0x08000000 | 0x0800) if FREQ >= 1000 else ((3240 // FREQ - 2) << 8))
F[0x1373f8] = (0x000000ff, lambda T, R, M: (R[2] & 1) * 0x55)                       # Сплит: ramcfg_10_02_01 * 0x55
F[0x100c00] = (0x08000000, lambda T, R, M: ((R[4] >> 3) & 1) << 27)                 # кандидат: бит 27 = FBVDDQ (две точки)
F[0x00e108] = (0x00000f00, lambda T, R, M: 0x300 if (T[14] & 7) == 0 else 0x600)    # кандидат: GPIO 10 (функция 0x2e) = ODT != 0, лог. 1 -> 0
F[0x10f630] = (0xffffffff, lambda T, R, M: hi(R[6]) * 0x11111111)                    # Сплит: ramcfg_10_06
F[0x10f634] = (0xffffffff, lambda T, R, M: lo(R[6]) * 0x11111111)
F[0x00e280] = (0xf0000000, lambda T, R, M: (0x3 if (R[4] >> 3) & 1 else 0x2) << 28)   # кандидат: GPIO 23 = FBVDDQ (одна точка)
# сценарий VBIOS по указателю BIT P + 0x1c (операции 0x8f: группы регистров, значение на ремешок) — Сплит, «unk1c»
cnt = r8(ent['M'][2]) if ent['M'][0] == 2 else r8(ent['M'][2] + 2)
o = r16(po + 0x1c)
while o and r8(o) == 0x8f:
    addr, incr, num = r32(o + 1), r8(o + 5), r8(o + 6)
    o += 7
    for k2 in range(num):
        val = r32(o + 4 * STRAP)
        F[addr + k2 * incr] = (0xffffffff, (lambda vv: (lambda T, R, M: vv))(val))
        o += 4 * cnt
# коэффициенты PLL памяти: проверяется, что они дают частоту цели (опора 405: REFPLL N/M, затем MPLL N/M) — расчёт как gt215_pll_calc
PLLCHK = {0x10fe24: lambda v: 405 * ((v >> 8) & 0xff) / (v & 0xff), 0x132004: lambda v: 594 * ((v >> 8) & 0xff) / (v & 0xff)}
PLLWANT = {0x10fe24: 594, 0x132004: 2004}
for i in range(8):
    F[0x10fc20 + i * 0xc] = (0xffffffff, lambda T, R, M: lo(R[0x0a]))

CAND = {0x100c00, 0x00e108, 0x00e280, 0x10f610, 0x10f614, 0x10f604}   # формулы, проверенные лишь на двух частотах или только частично
CTRL = {0x10f200: 0x00009800, 0x10f830: 0x41700007, 0x10f824: 0x000007a3, 0x10f808: 0x32a80000, 0x1373ec: 0x00030f0f,
        0x1373f8: 0x000020ff, 0x10f800: 0x00002004, 0x10f614: 0xf0000100, 0x10f610: 0xf0000100}
total = collections.Counter()
print(f'Ремешок {STRAP}. Метки: Ф — формула VBIOS (значение под маской совпало), Ф✘ — формула есть, но не совпала,'
      f' Ч — постоянная (вторая карта или все скрипты), П — постоянная база платы + известные управляющие биты, N — пока число.\n')
allvals = collections.defaultdict(set)
for k, (n, f0, f1) in SCR.items():
    for o in decode(arr[n]):
        if o[0] == 'WR':
            allvals[o[1]].add(o[2])
unknown = collections.defaultdict(list)
for k, (n, f0, f1) in SCR.items():
    FREQ = f1
    T, R, M = tables(f1)
    ops = decode(arr[n])
    last = {}
    for o in ops:
        if o[0] == 'WR':
            last[o[1]] = o[2]
    c = collections.Counter()
    for o in ops:
        if o[0] != 'WR':
            c['операции'] += 1
            continue
        a, v = o[1], o[2]
        tag = None
        if a in PLLCHK and abs(PLLCHK[a](v) - PLLWANT[a]) < 1:
            tag = 'Ф'
        if tag is None and a in F and v == last[a]:          # формула описывает итоговое значение регистра в скрипте
            mask, fn = F[a]
            tag = 'Ф' if (v & mask) == (fn(T, R, M) & mask) else 'Ф✘'
            if tag == 'Ф' and a in CAND:
                tag = 'Фк'
        if tag is None and v in nv.get(a, ()):
            tag = 'Ч'
        if tag is None and len(allvals[a]) == 1:
            tag = 'Ч1'
        if tag is None and a in CTRL and len({x & ~CTRL[a] for x in allvals[a]}) == 1:
            tag = 'П'
        if tag is None:
            tag = 'N'
            unknown[(a, v)].append(k)
        c[tag] += 1
    w = sum(c[t] for t in ('Ф', 'Фк', 'Ф✘', 'Ч', 'Ч1', 'П', 'N'))
    total.update(c)
    print(f'скрипт {k} ({f0} -> {f1} МГц): записей {w}: формула {c["Ф"]}, кандидат {c["Фк"]}, не сошлась {c["Ф✘"]},'
          f' постоянных (и у карты 2) {c["Ч"]}, постоянных (только у нас) {c["Ч1"]}, база+упр. биты {c["П"]}, числом {c["N"]}')
w = sum(total[t] for t in ('Ф', 'Фк', 'Ф✘', 'Ч', 'Ч1', 'П', 'N'))
pc = lambda t: f'{total[t]} ({100 * total[t] // w} %)'
print(f'\nвсего записей {w}: формула {pc("Ф")}, кандидат {pc("Фк")}, не сошлось {pc("Ф✘")}, постоянных и у карты 2 {pc("Ч")},'
      f' постоянных только у нас {pc("Ч1")}, база+упр. биты {pc("П")}, числом {pc("N")}')
print('\nпостоянные только у нас (одно значение во всех пяти скриптах, у карты 2 не встречаются):')
for a in sorted(x for x, vs in allvals.items() if len(vs) == 1 and not (vs & nv.get(x, set())) and x not in F and x not in PLLCHK):
    print(f'  {a:06x} = {next(iter(allvals[a])):08x}')
print('\nчислом (регистр = значение: в каких скриптах):')
for (a, v), ks in sorted(unknown.items()):
    print(f'  {a:06x} = {v:08x}: {"".join(ks)}')
# --regs: по регистрам — какие метки он получил во всех скриптах (для docs/model/registers.tsv, колонка «значение»)
if os.environ.get('MEMGEN_REGS'):
    per = collections.defaultdict(collections.Counter)
    for k, (n, f0, f1) in SCR.items():
        FREQ = f1
        T, R, M = tables(f1)
        ops = decode(arr[n]); last = {}
        for o in ops:
            if o[0] == 'WR': last[o[1]] = o[2]
        for o in ops:
            if o[0] != 'WR': continue
            a, v = o[1], o[2]; tag = None
            if a in PLLCHK and abs(PLLCHK[a](v) - PLLWANT[a]) < 1: tag = 'Ф'
            if tag is None and a in F and v == last[a]:
                mask, fn = F[a]; tag = 'Ф' if (v & mask) == (fn(T, R, M) & mask) else 'Ф✘'
                if tag == 'Ф' and a in CAND: tag = 'Фк'
            if tag is None and v in nv.get(a, ()): tag = 'Ч'
            if tag is None and len(allvals[a]) == 1: tag = 'Ч1'
            if tag is None and a in CTRL and len({x & ~CTRL[a] for x in allvals[a]}) == 1: tag = 'П'
            if tag is None: tag = 'N'
            per[a][tag] += 1
    print('\nПО РЕГИСТРАМ (адрес: метки×записей):')
    for a in sorted(per): print(f'  {a:06x}: ' + ' '.join(f'{t}×{c}' for t, c in per[a].most_common()))
