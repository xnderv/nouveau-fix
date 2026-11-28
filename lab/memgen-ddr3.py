#!/usr/bin/env python3
# ГЕНЕРАТОР СКРИПТОВ ПАМЯТИ DDR3 ДЛЯ GF108 ИЗ VBIOS (25.11.2026, первая проба). Собирает скрипт смены частоты памяти
# без записи NVIDIA: значения — по правилам карты полей (docs/2026-11-25/ddr3-field-map.md, lab/db-ddr3-fields.py),
# порядок шагов — общий каркас, выписанный из записей трёх плат, коэффициенты PLL — перебором в пределах из VBIOS.
# Два механизма, найденные при сборке (класс А — по записям, 14 скриптов трёх плат):
#   1) «запись, только если значение меняется»: большинство регистров скрипт пишет, только когда новое значение
#      отличается от того, что стоит в регистре сейчас. Поэтому генератору нужно текущее состояние регистров
#      (в драйвере — чтение железа; здесь — состояние перед скриптом, восстановленное по записи);
#   2) «строб»: каждая запись в блок 0x10f600…0x10f8ff копится; перед записью в регистры такта (0x1373xx, 0x132xxx)
#      и в 0x100xxx скрипт пишет 0x13d834 = 0 и ждёт столько шагов, сколько записей накопилось.
# Только чтение файлов. Проверка: сгенерированный скрипт сравнивается с записанным слово в слово.
#   python3 -I lab/memgen-ddr3.py states ЗАПИСЬ[.xz | -] BAR0 СКРИПТЫ.json ВЫХОД.json   — состояние регистров перед
#        каждым скриптом записи (последнее чтение или запись хоста, плюс записи предыдущих скриптов)
#   python3 -I lab/memgen-ddr3.py check МЕТКА ОБРАЗ.rom РЕМЕШОК СКРИПТЫ.json СОСТОЯНИЯ.json [--detail]
#   python3 -I lab/memgen-ddr3.py hostcheck МЕТКА ОБРАЗ.rom РЕМЕШОК СКРИПТЫ.json СОСТОЯНИЯ.json ЗАПИСИ_ХОСТА.json
#        (ЗАПИСИ_ХОСТА.json — от lab/trace-memhost.py)
#   python3 -I lab/memgen-ddr3.py emit ОБРАЗ.rom РЕМЕШОК ОТКУДА_МГц pll|div КУДА_МГц СОСТОЯНИЕ.json [--display]
import sys, os, json, lzma, importlib.util

HERE = os.path.dirname(os.path.abspath(__file__))
def load(name):
    sp = importlib.util.spec_from_file_location(name.replace('-', '_'), os.path.join(HERE, name + '.py'))
    m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m); return m

CLX = {5: 2, 6: 4, 7: 6, 8: 8, 9: 10, 10: 12, 11: 14, 12: 1, 13: 3, 14: 5}       # задержка чтения -> код MR0 (A6 A5 A4 A2)
WRX = {5: 1, 6: 2, 7: 3, 8: 4, 10: 5, 12: 6, 14: 7, 15: 7, 16: 0}               # восстановление записи -> код MR0
CWLX = {5: 0, 6: 1, 7: 2, 8: 3, 9: 4, 10: 5}                                    # задержка записи -> код MR2
HOST_TOUCHED = set()          # регистры, которые читают записи хоста (для стенда на C)
FRAME_TO = 0x02b5f070        # предел ожидания кадра, нс: одинаков во всех записях трёх плат; от VBIOS не зависит


def mem_pll(lim, khz):
    """коэффициенты PLL памяти: P от большего к меньшему (VCO в пределах VBIOS), M — пока опора после деления лежит
    в пределах входной частоты, N округлением; берётся строго лучшая ошибка. Возвращает (кГц, слово 0x132004)."""
    ref = lim['refclk']; best = None
    mlo = max(-(-ref // lim['max_in']), lim['min_m']); mhi = min(ref // lim['min_in'], lim['max_m'])
    for P in range(lim['max_p'], lim['min_p'] - 1, -1):
        vco = khz * P
        if vco < lim['min_freq'] or vco > lim['max_freq']:
            continue
        for M in range(mlo, mhi + 1):
            N = (vco * M + ref // 2) // ref
            if N < lim['min_n'] or N > lim['max_n']:
                continue
            got = ref * N // M // P
            err = abs(khz - got)
            if best is None or err < best[0]:
                best = (err, got, P << 16 | N << 8 | M)
    return (best[1], best[2]) if best else (0, None)


def level(vb, mhz):
    try:
        T, R, M = vb.tables(mhz)
    except ValueError:                   # частота выше верхнего диапазона VBIOS (разгон) — берётся верхний диапазон
        T, R, M = vb.tables(max(vb.rom.r16(vb.rammap + vb.rh + i * (vb.rl + vb.rn * vb.rs) + 2) for i in range(vb.rc)))
    return dict(f=mhz, T=T, R=R, M=M, lo=M[0] | M[1] << 8, hi=M[2] | M[3] << 8, r2=R[2],
                dlloff=bool(R[2] & 0x40), numeric=bool(M[4] & 8))


def t290(T): return T[9] << 24 | T[7] << 17 | T[5] << 8 | T[3]
def mr0(T): c = CLX[T[2]]; return 0x1000 | WRX[T[0]] << 9 | (c & 0xe) << 3 | (c & 1) << 2
def f808(L):
    r2 = L['r2']
    return 0x00020000 | (0x00000004 if r2 & 4 else 0x12800000) | (0x08000000 if r2 & 0x10 else 0x04000000) | (0 if r2 & 8 else 0x00100000)
def dllwait(mhz): return -(-512000 // int(mhz * 1000)) * 1000          # 512 тактов памяти (tDLLK стандарта), вверх до 1 мкс


class Gen:
    def __init__(self, st):
        self.st = dict(st); self.out = []; self.pending = 0; self.miss = []; self.unknown = []
        self.assumed = {}                          # регистр без известного состояния -> значение, принятое за текущее (для стенда на C)
        self.touched = set()                       # все регистры, которые генератор читал или писал (для стенда на C)

    def cur(self, reg):
        self.touched.add(reg)
        if reg not in self.st:
            self.miss.append(reg); return 0
        return self.st[reg]

    def flush(self):
        if self.pending:
            self.out.append(('W', 0x13d834, 0)); self.out.append(('op', 0x3a, (self.pending,))); self.pending = 0

    def w(self, reg, val, always=False):
        val &= 0xffffffff; self.touched.add(reg)
        if not always and self.st.get(reg) == val:
            return False
        if not always and reg not in self.st:      # текущее значение неизвестно (в записи регистр не читался и не писался,
            self.unknown.append(reg)               # в init-скриптах VBIOS его нет): считаем, что менять не нужно.
            self.assumed.setdefault(reg, val)
            self.st[reg] = val; return False       # В драйвере этого случая нет — там значение читается из железа
        if (0x137300 <= reg < 0x137400 or 0x132000 <= reg < 0x133000 or 0x100000 <= reg < 0x101000 or 0x110000 <= reg < 0x118000):
            self.flush()
        self.out.append(('W', reg, val)); self.st[reg] = val
        if 0x10f600 <= reg < 0x10f900:
            self.pending += 1
        return True

    def op(self, code, *a): self.out.append(('op', code, tuple(a)))
    def wait(self, ns): self.op(0x2e, ns)
    def lockwait(self):
        self.op(0x00, 2); self.op(0x01, 0x137390); self.op(0x15, 2, 0xfa00)
        self.st[0x132000] = self.cur(0x132000) | 0x00030000        # признаки захвата читаются единицами, пока PLL работает


def mem_flags(vb):
    """флаг источника такта памяти по уровням из таблицы уровней VBIOS (биты 14–15 частоты, как у узлов ядра):
    1 — PLL, 2 — делитель, 0 — не задано. Возвращает {МГц: флаг}."""
    r8, r16, r32 = vb.rom.r8, vb.rom.r16, vb.rom.r32
    # порядок полей шапки: длина шапки, длина записи, длина подзаписи, число подзаписей, число уровней
    perf = vb.rom.A(r32(vb.po)); hdr, ln, ssz, snr, cnt = (r8(perf + k) for k in (1, 2, 3, 4, 5)); out = {}
    for i in range(cnt):
        e = perf + hdr + i * (ln + snr * ssz)
        if r8(e) == 0xff: continue
        v = r16(e + ln + 5 * ssz); out[v & 0x3fff] = v >> 14
    return out


def want_pll(flags, mhz):
    f = flags.get(mhz, 0)
    if f == 1: return True
    if f == 2: return False
    return (3240 % mhz) != 0 or not 0 <= 3240 // mhz - 2 <= 63          # флага нет: делитель, если он даёт частоту точно


def uses_618(vb):
    """использует ли плата регистр 0x10f618: в VBIOS хотя бы у одного уровня памяти его значение (младшая тетрада байта 3
    ramcfg) не ноль. 26.11, по сверке на железе (GT 630M) и по трём записям NVIDIA: на платах, где оно ноль на всех
    уровнях (GT 630M, Quadro 600), драйвер NVIDIA этот регистр не читает и не пишет вовсе; на ASUS GT 630 (324 МГц — 1,
    остальные — 0) читает перед каждым скриптом и пишет при смене. Регистра нет и в init-скриптах VBIOS этих плат."""
    cached = getattr(vb, '_uses_618', None)
    if cached is None:
        cached = False
        for m in mem_flags(vb):
            if m and level(vb, m)['R'][3] & 0xf: cached = True
        vb._uses_618 = cached
    return cached


def generate(vb, lim, st, cur_mhz, on_pll, tgt_mhz, tgt_pll=True, display=True):
    """скрипт перехода памяти cur -> tgt; st — текущее состояние регистров; on_pll / tgt_pll — от чего идёт такт сейчас
    и от чего должен идти после (флаг уровня в VBIOS). Возвращает (токены, регистры без известного состояния, кГц)."""
    C, L = level(vb, cur_mhz), level(vb, tgt_mhz)
    T, R = L['T'], L['R']; b4 = bool(L['r2'] & 0x10)
    g = Gen(st); cur, w = g.cur, g.w
    global LAST_GEN; LAST_GEN = g
    if tgt_pll:
        got_khz, coef = mem_pll(lim, tgt_mhz * 1000); div = None
    else:
        n = round(3240 / tgt_mhz) - 2; got_khz = 3240000 // (n + 2); coef = None
        div = (cur(0x137310) & ~0x3f00) | n << 8
    f018 = 0x1000 | (0x4000 if L['lo'] > 450 else 0) | (0x10000000 if tgt_mhz <= 750 else 0) | (0 if tgt_pll else 0x8000)
    rng824 = 0x6000 if L['hi'] <= 450 else 0
    odt = (T[0xe] & 1) << 2 | (T[0xe] & 2) << 5 | (T[0xe] & 4) << 7

    # --- до остановки памяти
    if tgt_pll and not on_pll:           # память идёт от делителя: PLL можно настроить и захватить заранее
        w(0x137320, 0x103, True); w(0x137330, 0x81200606, True); w(0x132004, coef, True)
        w(0x132000, cur(0x132000) | 1, True); g.lockwait()
        w(0x132018, f018)
    if on_pll and not tgt_pll:           # память идёт от PLL: делитель можно настроить заранее
        w(0x137310, div)
    if on_pll:
        w(0x137300, 0x103, True)
    if on_pll or tgt_pll:
        w(0x137370, 3, True); w(0x137380, 1, True)
    if not b4:
        w(0x10f808, f808(C) | 0x40000000, True)
    v = cur(0x10f824) & ~(0x600 if b4 else 0x180)
    if tgt_pll and not on_pll and not rng824:      # PLL уже захвачена на частоте цели: снять биты 13–14 сразу (ставятся — позже)
        v &= ~0x6000
    w(0x10f824, v)
    w(0x100b0c, 0x00080012, True)
    if display:
        g.op(0x14, 0, FRAME_TO); g.op(0x14, 0x10000, FRAME_TO); w(0x611200, 0x3300, True)
    g.op(0x34, 0xa); g.op(0x20, 1, 0)

    # --- память остановлена
    w(0x10f200, cur(0x10f200) & ~0x800, True)
    m1 = cur(0x10f304)
    if (m1 & 0x244) & ~odt:              # согласование линий: снять — заранее, поставить — после смены такта
        w(0x10f304, (m1 & ~0x244) | (m1 & 0x244 & odt))
    if not b4:
        w(0x10f808, cur(0x10f808) | 0x04020000)
    if L['dlloff'] and not C['dlloff']:
        w(0x10f314, 1, True); w(0x10f304, cur(0x10f304) | 1, True); g.wait(1000)
    if not b4:
        w(0x1373ec, cur(0x1373ec) | 0x20000)
    rfc = t290(T) & 0x0001ff00
    if rfc > (cur(0x10f290) & 0x0001ff00):            # обновление строк дольше в тактах — поднять заранее
        w(0x10f290, (cur(0x10f290) & ~0x0001ff00) | rfc)
    w(0x10f314, 1, True); w(0x10f210, 0, True); w(0x10f310, 1, True); w(0x10f310, 1, True); g.wait(1000)
    w(0x10f090, 0x60, True); w(0x10f090, 0xc000007e, True)
    if on_pll:                           # уйти с PLL на делитель: насовсем или на время перестройки PLL
        w(0x137360, 3, True)
        w(0x10f830, cur(0x10f830) | 6)
        w(0x137370, 0, True); w(0x137380, 0, True)
        w(0x132018, cur(0x132018) & ~0x4000)
        w(0x132000, cur(0x132000) & ~1, True)
        if tgt_pll:
            w(0x137320, 0x103, True); w(0x137330, 0x81200606, True); w(0x132004, coef, True)
            w(0x132000, cur(0x132000) | 1, True); g.lockwait()
    elif not tgt_pll:                    # делитель -> делитель: поменять делитель на месте
        w(0x137310, div)
    w(0x10f874, (cur(0x10f874) & ~0x04000000) | (0x04000000 if tgt_mhz <= 750 else 0))
    if L['numeric']:
        w(0x10f658, R[6] << 16 | R[5] << 8 | R[5])
        w(0x132018, f018)
        w(0x10f660, R[8] << 8 | R[7], True)
        w(0x10f668, 0x80000000 | (R[9] >> 4) << 20 | (R[3] & 0xf) << 16 | (R[9] & 0xf))
        w(0x10f910, cur(0x10f910) & ~0x2000); w(0x10f914, cur(0x10f914) & ~0x2000)
        w(0x10f824, (cur(0x10f824) & ~0x6000) | rng824)
    else:
        w(0x10f824, (cur(0x10f824) & ~0x6000) | rng824)
        w(0x132018, f018)
        g.wait(20000)
        w(0x10f910, cur(0x10f910) | 0x2000); w(0x10f914, cur(0x10f914) | 0x2000)
        w(0x10f658, 0)
        for part in (0x110000, 0x111000):            # GF108: два раздела; бит 1 каждой тетрады = частота не выше 750 МГц
            for off in (0x620, 0x628, 0x630):
                if part + off in g.st:
                    w(part + off, (g.st[part + off] & ~0x22222222) | (0x22222222 if tgt_mhz <= 750 else 0))
                else:
                    g.unknown.append(part + off); g.assumed.setdefault(part + off, 0x22222222 if tgt_mhz <= 750 else 0)
        if tgt_mhz > 500:
            w(0x10f830, cur(0x10f830) & ~6)
    if tgt_pll:
        w(0x137370, 3, True); w(0x137380, 1, True); w(0x137360, 2, True)
    w(0x10f090, 0x4000007f, True); w(0x10f210, 0x80000000, True)
    g.wait(dllwait(tgt_mhz))

    # --- регистры режима микросхем памяти
    built0 = cur(0x10f300); old0 = built0 & ~0x100
    if not L['dlloff']:
        if C['dlloff']:
            w(0x10f304, cur(0x10f304) & ~1, True); g.wait(1000)
        w(0x10f300, old0 | 0x100, True); g.wait(1000); w(0x10f300, old0, True); g.wait(1000)
    if w(0x10f320, (cur(0x10f320) & ~0x38) | CWLX[T[0x13]] << 3):
        g.wait(1000)
    w(0x10f300, mr0(T) | (built0 & 0x100), True); g.wait(1000)

    # --- тайминги контроллера и управляющие биты
    w(0x10f224, (cur(0x10f224) & ~0x00ff0000) | T[0x12] << 16)
    w(0x10f290, t290(T))
    w(0x10f294, (cur(0x10f294) & 0xfc000000) | T[0xb] << 20 | T[0xa] << 14 | T[0x13] << 7 | (T[2] - (1 if L['dlloff'] else 0)))
    w(0x10f298, (cur(0x10f298) & 0xff000000) | T[0] << 16 | T[1] << 8 | 0x11)
    w(0x10f29c, (cur(0x10f29c) & ~0xffff) | T[0x14] << 9 | T[0x15] << 5 | T[0xd])
    w(0x10f2a0, (cur(0x10f2a0) & ~0x001f8000) | T[0xc] << 15)
    w(0x10f200, (cur(0x10f200) & ~0x1000) | (0 if L['r2'] & 8 else 0x1000))
    w(0x10f604, (cur(0x10f604) & ~0xf1000000) | (0xf0000000 if L['r2'] & 0x20 else 0) | (0 if L['r2'] & 4 else 0x01000000))
    w(0x10f614, (cur(0x10f614) & ~0xf0000100) | (T[0x18] & 0xf) << 28 | (L['r2'] & 1) << 8)
    w(0x10f610, (cur(0x10f610) & ~0xf0000100) | (T[0x18] & 0xf) << 28 | ((L['r2'] >> 1) & 1) << 8)
    w(0x10f808, f808(L) | (cur(0x10f808) & 0x40000000))
    if b4:
        w(0x1373ec, cur(0x1373ec) & ~0x20000)
    w(0x1373f8, (cur(0x1373f8) & ~5) | (5 if L['r2'] & 1 else 0))
    w(0x10f870, (R[0xd] & 0xf) * 0x11111111, True)
    if uses_618(vb):
        w(0x10f618, (R[3] & 0xf) * 0x11111111)
    m1 = cur(0x10f304)
    if (m1 & 0x244) != odt:
        w(0x10f304, (m1 & ~0x244) | odt, True); g.wait(1000)
    # 0x100c00 — копия двух полей контактных регистров на стороне контроллера памяти (28.11, docs/2026-11-28/reg-100c00.md):
    # бит 27 = бит 8 регистра 0x10f614 (ramcfg байт 2 бит 0), биты 8–6 = биты 30–28 регистров 0x10f610/0x10f614.
    # Во всех скриптах NVIDIA копия равна оригиналу (111 из 111 и 162 из 162), поэтому пишется при любом расхождении,
    # и при выключенной DLL тоже: раньше шаг 800 -> 135 МГц менял контактные регистры, а копию оставлял старой.
    # Биты 16 и 19 — смысл неизвестен: после включения (POST) их нет, в каждой записи NVIDIA в этот регистр они стоят.
    mirror = (L['r2'] & 1) << 27 | (T[0x18] & 7) << 6
    if not L['dlloff'] or (cur(0x100c00) & 0x080001c0) != mirror:
        w(0x100c00, (cur(0x100c00) & ~0x080001c0) | 0x00090000 | mirror)
    if not L['dlloff']:
        w(0x10f300, mr0(T) | 0x100, True); g.wait(1000); w(0x10f300, mr0(T), True); g.wait(1000)
        g.wait(dllwait(tgt_mhz))
    else:
        g.wait(5000)
    v = cur(0x10f830)
    w(0x10f830, v | 0x01000000, True); w(0x10f830, v, True)
    g.op(0x20, 0, 0); g.op(0x34, 0xb)

    # --- память снова доступна
    w(0x100b0c, 0x00080028, True); w(0x611200, 0x3330, True); w(0x10f200, cur(0x10f200) | 0x800, True)
    g.op(0x16, 0)
    return g.out, sorted(set(g.miss) | set(g.unknown)), got_khz


def range_set(get, word):
    """шесть регистров диапазона 0x10f4xx из упакованного слова записи диапазона частот VBIOS (байты 5–8);
    раскладка — как у Kepler в nouveau (fb/ramgk104.c), сверена на трёх платах (карта полей, раздел 8)"""
    return [(0x10f468, (get(0x10f468) & ~0x001ff1ff) | (word & 0x1ff) | ((word >> 9) & 0x1ff) << 12),
            (0x10f420, (get(0x10f420) & ~1) | (word >> 18) & 1),
            (0x10f430, (get(0x10f430) & ~1) | (word >> 19) & 1),
            (0x10f400, (get(0x10f400) & ~0x1f) | 0x1700 | (word >> 20) & 0x1f),      # 0x1700 и 0x8800 ниже — смысл неизвестен:
            (0x10f410, (get(0x10f410) & ~0x200) | ((word >> 25) & 1) << 9),
            (0x10f444, (get(0x10f444) & ~0xa0) | 0x8800 | ((word >> 26) & 1) << 5 | ((word >> 27) & 1) << 7)]  # после включения их нет, у NVIDIA стоят всегда (3 платы)


def host_writes(vb, st, cur_mhz, on_pll, tgt_mhz, tgt_pll, st_after):
    """записи хоста вокруг скрипта: (до скрипта, после скрипта, регистры без известного состояния).
    До: 0x10f050 и шесть регистров диапазона — в набор нижнего диапазона VBIOS, каким бы ни был переход; подготовка PLL,
    если её надо пускать с нуля. После: шесть регистров и 0x10f050 — в набор цели; пара битов 0x10f824 и бит 30 0x10f808 по
    биту 4 байта 2 ramcfg (как у GT21x в nouveau: «post fiddlings»). Напряжение сюда не входит — им управляет драйвер."""
    C, L = level(vb, cur_mhz), level(vb, tgt_mhz); miss = []
    def getter(state):
        def get(a):
            HOST_TOUCHED.add(a)
            if a not in state: miss.append(a); return 0
            return state[a]
        return get
    word = lambda lv: lv['M'][5] | lv['M'][6] << 8 | lv['M'][7] << 16 | lv['M'][8] << 24
    low = level(vb, max(vb.rom.r16(vb.rammap + vb.rh), 1))        # первая запись диапазона (самые низкие частоты)
    g = getter(st)
    pre = [(0x10f050, (g(0x10f050) & ~0x1400) | 0x400)] + range_set(g, word(low))
    if tgt_pll and not on_pll and (g(0x132000) & 2):       # бит 1 стоит только после включения (POST): снять перед первым пуском PLL
        pre += [(0x132000, g(0x132000)), (0x132000, g(0x132000) & ~2)]
    g = getter(st_after); post = []
    f018 = 0x1000 | (0x4000 if L['lo'] > 450 else 0) | (0x10000000 if tgt_mhz <= 750 else 0) | (0 if tgt_pll else 0x8000)
    if L['r2'] & 0x10:
        post += [(0x132018, f018), (0x10f824, g(0x10f824) | 0x180), (0x10f808, g(0x10f808) & ~0x40000000)]
    else:
        post += [(0x10f824, g(0x10f824) | 0x600)]
    if not tgt_pll:                      # цель на делителе: снять бит включения PLL (если PLL уже выключена — запись ничего не меняет)
        post += [(0x132000, g(0x132000) & ~1)]
    post += range_set(g, word(L)) + [(0x10f050, (g(0x10f050) & ~0x1400) | (0x1000 if L['lo'] > 450 else 0x400))]
    return pre, post, sorted(set(miss))


def to_words(toks):
    out = []; run = []
    def close():
        if run:
            out.append((1 + 2 * len(run)) << 16 | 0x21)
            for r, v in run: out.extend((r, v))
            run.clear()
    for t in toks:
        if t[0] == 'W':
            run.append((t[1], t[2]))
        else:
            close(); out.append((1 + len(t[2])) << 16 | t[1]); out.extend(t[2])
    close(); return out


def from_words(w):
    i, t = 0, []
    while i < len(w):
        h = w[i]; n, op = h >> 16, h & 0xffff
        if n == 0: break
        a = w[i + 1:i + n]
        if op == 0x21: t += [('W', a[k], a[k + 1]) for k in range(0, len(a) - 1, 2)]
        else: t.append(('op', op, tuple(a)))
        i += n
    return t


def show(t):
    if t[0] == 'W': return f'{t[1]:06x}={t[2]:08x}'
    return '[оп %02x %s]' % (t[1], ' '.join(f'{x:x}' for x in t[2]))


def opener(fn):
    if fn == '-': return sys.stdin
    return lzma.open(fn, 'rt', errors='replace') if fn.endswith('.xz') else open(fn, errors='replace')


def cmd_states(trace, bar0, scripts, out):
    bar0 = int(bar0, 16); J = json.load(open(scripts))
    want = set()
    for s in J:
        want.update(t[1] for t in from_words(s['words']) if t[0] == 'W')
    want.update((0x137360, 0x137310, 0x132004, 0x132000, 0x10f304, 0x10f300, 0x10f320, 0x10f830, 0x10f290,
                 0x10f050, 0x10f468, 0x10f420, 0x10f430, 0x10f400, 0x10f410, 0x10f444,
                 0x110620, 0x110628, 0x110630, 0x111620, 0x111628, 0x111630))
    last = {}; k = 0; states = []; before = []; kb = 0
    def snap():
        nonlocal k
        states.append({f'{a:06x}': v for a, v in sorted(last.items())})
        for t in from_words(J[k]['words']):
            if t[0] == 'W': last[t[1]] = t[2]
        k += 1
    with opener(trace) as f:
        for line in f:
            if not line or line[0] not in 'RW': continue
            p = line.split()
            if len(p) < 6 or p[1] != '4': continue
            try: t = float(p[2]); a = int(p[4], 16) - bar0
            except ValueError: continue
            # состояние берётся в момент пуска скрипта (запись хоста в 0x10a4a0 после его загрузки): часть записей
            # хоста идёт между загрузкой и пуском; если пуска не видно — перед загрузкой следующего скрипта
            while kb < len(J) and t >= J[kb]['t'] - 0.020 and kb <= k:      # перед окном записей хоста этого скрипта
                before.append({f'{x:06x}': v for x, v in sorted(last.items())}); kb += 1
            if k < len(J) and line[0] == 'W' and a == 0x10a4a0 and t > J[k]['t']: snap()
            while k + 1 < len(J) and t >= J[k + 1]['t']: snap()
            if a in want:
                last[a] = int(p[5], 16)
    while k < len(J): snap()
    while kb < len(J): before.append(dict(states[kb])); kb += 1
    json.dump(states, open(out, 'w'))
    json.dump(before, open(out.replace('.json', '-pre.json'), 'w'))
    print(f'скриптов {len(J)}, регистров под наблюдением {len(want)}; состояние перед каждым записано в {out}')


def snap_level(levels, f):
    lv = min((m for m in levels if m), key=lambda x: abs(x - f))
    return lv if abs(lv - f) <= 0.015 * lv else int(round(f))


def mhz_of(st, vb):
    """уровень памяти по состоянию: переключатель 0x137360 (2 — PLL), коэффициенты или делитель"""
    sel = st.get(0x137360)
    if sel is not None and (sel & 3) == 2:
        c = st.get(0x132004, 0); M, N, P = c & 0xff, (c >> 8) & 0xff, (c >> 16) & 0x3f
        f = 405.0 * N / M / P if M and P else 0; pll = True
    else:
        d = st.get(0x137310, 0x81200808); f = 3240.0 / (((d >> 8) & 0x3f) + 2); pll = False
    return snap_level(getattr(vb, 'levels', None) or vb.mem.values(), f), pll, f


def classify(vb, flags, st, rec):
    """откуда и куда идёт записанный скрипт: цель — по коэффициентам PLL или делителю в скрипте, источник — по состоянию"""
    cw = [t[2] for t in rec if t[0] == 'W' and t[1] == 0x132004]; dw = [t[2] for t in rec if t[0] == 'W' and t[1] == 0x137310]
    if cw:
        c = cw[-1]; tf = 405.0 * ((c >> 8) & 0xff) / (c & 0xff) / ((c >> 16) & 0x3f); rec_pll = True
    else:
        d = dw[-1] if dw else st.get(0x137310, 0x81200808); tf = 3240.0 / (((d >> 8) & 0x3f) + 2); rec_pll = False
    vb.levels = [m for m in flags if m]
    tgt = snap_level(vb.levels, tf)
    cur, on_pll, cf = mhz_of(st, vb)
    return cur, on_pll, tgt, want_pll(flags, tgt), rec_pll, any(t[0] == 'op' and t[1] == 0x14 for t in rec)


def same_tok(x, y):
    if x == y: return True, False
    if x[0] == 'W' and y[0] == 'W' and x[1] == y[1] == 0x132000 and not ((x[2] ^ y[2]) & ~0x00030000): return True, True
    return False, False


def cmd_check(label, rom, raw, scripts, states, detail):
    mg = load('memgen2'); cp = load('core-predict')
    vb0 = mg.Vbios(rom, 0); vb = mg.Vbios(rom, mg.ramcfg_index(vb0.rom, int(raw, 0)))
    lim = cp.Rom(rom).pll(0x132000); flags = mem_flags(vb)
    J = json.load(open(scripts)); S = json.load(open(states))
    print(f'## {label}: уровни памяти VBIOS (МГц: источник по флагу) ' + ', '.join(f'{m}: {"PLL" if want_pll(flags, m) else "делитель"}' for m in sorted(flags) if m) + f'; скриптов в записи {len(J)}')
    seen = {}; exact = 0; ndist = 0; nstat = 0
    for i, s in enumerate(J):
        st = {int(a, 16): v for a, v in S[i].items()}
        for a, v in vb.devinit.items():            # чего NVIDIA до скрипта не читала и не писала — как после включения (POST)
            st.setdefault(a, v)
        key = tuple(s['words'])
        if key in seen: continue
        seen[key] = 1; ndist += 1
        rec = from_words(s['words'])
        cur, on_pll, tgt, tgt_pll, rec_pll, display = classify(vb, flags, st, rec)
        toks, miss, khz = generate(vb, lim, st, cur, on_pll, tgt, tgt_pll, display)
        cmpres = [same_tok(x, y) for x, y in zip(rec, toks)] if len(rec) == len(toks) else None
        same = cmpres is not None and all(c[0] for c in cmpres)
        stat = sum(1 for c in cmpres if c[1]) if same else 0
        exact += same; nstat += stat
        print(f'  скрипт {i}: {cur} МГц ({"PLL" if on_pll else "делитель"}) -> {tgt} МГц ({"PLL" if tgt_pll else "делитель"}, выходит {khz / 1000:.1f}), '
              f'{"с ожиданием кадра" if display else "без ожидания кадра"}: записано слов {len(s["words"])}, собрано {len(to_words(toks))} — '
              + ('СОВПАЛО слово в слово' + (f' (кроме битов состояния PLL в {stat} слове)' if stat else '') if same else 'НЕ совпало')
              + ('' if rec_pll == tgt_pll else '  [источник по флагу VBIOS не тот, что в записи!]'))
        if miss: print('     текущее значение неизвестно, принято «менять не нужно»:', ' '.join(f'{a:06x}' for a in miss))
        if not same:
            import difflib
            A = [show(t) for t in rec]; B = [show(t) for t in toks]
            sm = difflib.SequenceMatcher(None, A, B, autojunk=False); nd = 0
            for tag, i1, i2, j1, j2 in sm.get_opcodes():
                if tag == 'equal': continue
                nd += 1
                if detail or nd <= 12:
                    print(f'     запись NVIDIA: {" ".join(A[i1:i2]) or "—"}\n     генератор:     {" ".join(B[j1:j2]) or "—"}')
            print(f'     мест расхождения: {nd}')
    print(f'  ИТОГ {label}: разных скриптов {ndist}, совпало слово в слово {exact}' + (f'; слов, где отличаются только биты состояния PLL: {nstat}' if nstat else ''))
    return ndist, exact


def cmd_hostcheck(label, rom, raw, scripts, states, memhost):
    """записи хоста вокруг каждого скрипта: что собрал генератор против записи. Сравнивается состояние регистров: в момент
    пуска скрипта (после записей «до») и перед окном следующего скрипта (после записей «после»). Так сверка не зависит
    от того, насколько заранее хост сделал запись."""
    mg = load('memgen2'); cp = load('core-predict')
    vb0 = mg.Vbios(rom, 0); vb = mg.Vbios(rom, mg.ramcfg_index(vb0.rom, int(raw, 0)))
    lim = cp.Rom(rom).pll(0x132000); flags = mem_flags(vb)
    J = json.load(open(scripts)); S = json.load(open(states)); H = {h['i']: h for h in json.load(open(memhost))}
    SP = json.load(open(states.replace('.json', '-pre.json')))
    LOWP = (0x10f2fc, 0x100b4c, 0x10f254, 0x10f150)          # снятие настроек малого потребления (NVIDIA включает их после спусков)
    ok = bad = 0; seen = set(); lowp = {}; unknown = set()
    print(f'## {label}: записи хоста вокруг скриптов')
    for i, s in enumerate(J):
        if i not in H: continue
        st = {int(a, 16): v for a, v in S[i].items()}
        for a, v in vb.devinit.items(): st.setdefault(a, v)
        rec = from_words(s['words']); cur, on_pll, tgt, tgt_pll, rec_pll, display = classify(vb, flags, st, rec)
        after = dict(st)
        for t in rec:
            if t[0] == 'W': after[t[1]] = t[2]
        stp = {int(x, 16): v for x, v in SP[i].items()}
        for x, v in vb.devinit.items(): stp.setdefault(x, v)
        pre, post, miss = host_writes(vb, stp, cur, on_pll, tgt, tgt_pll, after); unknown.update(miss)
        nxt = {int(x, 16): v for x, v in SP[i + 1].items()} if i + 1 < len(SP) else None
        for name, gen, ref in (('до', pre, st), ('после', post, nxt)):
            if ref is None: continue
            g = dict(gen); r = {a: ref[a] for a in g if a in ref}
            for a in [a for a in g if a not in ref]: unknown.add(a); del g[a]
            # 0x132000: сравниваются только управляющие биты 0–1 (остальное — признаки состояния)
            if 0x132000 in g: g[0x132000] &= 3; r[0x132000] &= 3
            same = g == r; ok += same; bad += not same
            key = (name, tuple(sorted(g.items())), tuple(sorted(r.items())))
            if not same and key not in seen:
                seen.add(key)
                print(f'  скрипт {i} ({cur} -> {tgt} МГц), {name} скрипта: НЕ совпало')
                for a in sorted(g):
                    if g[a] != r[a]: print(f'     {a:06x}: в записи NVIDIA стоит {r[a]:08x}, генератор ставит {g[a]:08x}')
        for a, v in H[i]['pre']:
            if a in LOWP: lowp[a] = v
    print(f'  ИТОГ {label}: наборов записей хоста (до и после скрипта) {ok + bad}, совпало {ok}'
          + (f'; состояние неизвестно: {" ".join("%06x" % a for a in sorted(unknown))}' if unknown else ''))
    if lowp:
        print('  снятие настроек малого потребления перед скриптом (в сравнение не входит): '
              + '; '.join(f'{a:06x} = {v:08x}, после включения по VBIOS {("%08x" % vb.devinit[a]) if a in vb.devinit else "нет в init-скриптах"}' for a, v in sorted(lowp.items())))


def cmd_cases(label, rom, raw, scripts, states, memhost, out):
    """входы и ожидаемые выходы для стенда на C (lab/memgen-ddr3-ctest.sh): блок на каждый скрипт записи. В блоке — байты
    уровней VBIOS, пределы PLL, состояния регистров (st — в момент пуска; sp — перед окном записей хоста, только виденное
    в записи; dv — после включения по init-скриптам VBIOS; sa — после скрипта; as — принятое за текущее там, где неизвестно),
    записанные слова NVIDIA, слова питоновского генератора и его записи хоста. Все числа — шестнадцатеричные."""
    mg = load('memgen2'); cp = load('core-predict')
    vb0 = mg.Vbios(rom, 0); vb = mg.Vbios(rom, mg.ramcfg_index(vb0.rom, int(raw, 0)))
    lim = cp.Rom(rom).pll(0x132000); flags = mem_flags(vb)
    J = json.load(open(scripts)); S = json.load(open(states)); SP = json.load(open(states.replace('.json', '-pre.json')))
    H = {h['i'] for h in json.load(open(memhost))} if memhost != '-' else set()
    low = level(vb, max(vb.rom.r16(vb.rammap + vb.rh), 1)); seen = set(); n = 0
    hx = lambda b: ' '.join(f'{x:x}' for x in b)
    with open(out, 'a') as f:
        for i, s in enumerate(J):
            st = {int(a, 16): v for a, v in S[i].items()}
            for a, v in vb.devinit.items(): st.setdefault(a, v)
            spraw = {int(a, 16): v for a, v in SP[i].items()}; stp = dict(spraw)
            for a, v in vb.devinit.items(): stp.setdefault(a, v)
            rec = from_words(s['words'])
            cur, on_pll, tgt, tgt_pll, rec_pll, display = classify(vb, flags, st, rec)
            try:
                toks, miss, khz = generate(vb, lim, st, cur, on_pll, tgt, tgt_pll, display)
            except Exception as e:
                print(f'  {label} скрипт {i}: генератор не применим ({type(e).__name__}: {e})'); continue
            assumed = dict(LAST_GEN.assumed)
            after = dict(st)
            for t in rec:
                if t[0] == 'W': after[t[1]] = t[2]
            pre, post, _ = host_writes(vb, stp, cur, on_pll, tgt, tgt_pll, after)
            C, L = level(vb, cur), level(vb, tgt)
            key = tuple(s['words']); first = key not in seen; seen.add(key)
            # в блок идут только регистры, которых касается генератор или запись (остальное состояние стенду не нужно)
            keep = set(LAST_GEN.touched) | HOST_TOUCHED | {t[1] for t in rec if t[0] == 'W'} | {t[1] for t in toks if t[0] == 'W'}
            keep |= {p + o for p in (0x110000, 0x111000) for o in (0x620, 0x628, 0x630)} | {0x132000, 0x132004, 0x137310, 0x137360}
            cut = lambda d: {a: v for a, v in d.items() if a in keep}
            f.write(f'case {label.replace(" ", "_")}#{i}\n')
            f.write(f'p {tgt:x} {int(on_pll)} {int(tgt_pll)} {int(display)} {int(first)} {int(i in H)} {cur:x} {int(uses_618(vb))}\n')
            f.write('pll ' + ' '.join(f'{lim[k]:x}' for k in ('refclk', 'min_freq', 'max_freq', 'min_in', 'max_in', 'min_m', 'max_m', 'min_n', 'max_n', 'min_p', 'max_p')) + '\n')
            for nm, lv in (('c', C), ('t', L), ('l', low)):
                for k in 'TRM': f.write(f'{k}{nm} {len(lv[k]):x} {hx(lv[k])}\n')
            for nm, d in (('st', cut(st)), ('sp', cut(spraw)), ('dv', cut(vb.devinit)), ('sa', cut(after)), ('as', assumed)):
                f.write(f'{nm} {len(d):x} ' + ' '.join(f'{a:x} {v & 0xffffffff:x}' for a, v in sorted(d.items())) + '\n')
            f.write(f'xr {len(s["words"]):x} {hx(s["words"])}\n')
            w = to_words(toks); f.write(f'xp {len(w):x} {hx(w)}\n')
            f.write(f'hp {len(pre):x} ' + ' '.join(f'{a:x} {v & 0xffffffff:x}' for a, v in pre) + '\n')
            f.write(f'hq {len(post):x} ' + ' '.join(f'{a:x} {v & 0xffffffff:x}' for a, v in post) + '\n')
            f.write('end\n'); n += 1
    print(f'  {label}: блоков для стенда {n}')


def main():
    a = [x for x in sys.argv[1:] if not x.startswith('--')]
    if not a: sys.exit(__doc__ or 'см. шапку файла')
    if a[0] == 'states': cmd_states(*a[1:5])
    elif a[0] == 'check': cmd_check(a[1], a[2], a[3], a[4], a[5], '--detail' in sys.argv)
    elif a[0] == 'hostcheck': cmd_hostcheck(*a[1:7])
    elif a[0] == 'cases': cmd_cases(*a[1:8])
    elif a[0] == 'emit':
        mg = load('memgen2'); cp = load('core-predict')
        vb0 = mg.Vbios(a[1], 0); vb = mg.Vbios(a[1], mg.ramcfg_index(vb0.rom, int(a[2], 0)))
        st = {int(k, 16): v for k, v in json.load(open(a[6])).items()}
        toks, miss, khz = generate(vb, cp.Rom(a[1]).pll(0x132000), st, int(a[3]), a[4] == 'pll', int(a[5]), want_pll(mem_flags(vb), int(a[5])), '--display' in sys.argv)
        print(' '.join(f'0x{x:08x},' for x in to_words(toks)))
    else: sys.exit('неизвестный режим')

main()
