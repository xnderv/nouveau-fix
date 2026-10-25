#!/usr/bin/env python3
# «ПЕРЕБРОСИТЬ КОСТИ» ДЕЛИТЕЛЮ ЯДРА (25.10, опыт к гипотезе «черты»). Делитель ядра 0x1371d0 (поле A, биты 0–5: делит на A+2)
# на 1–2 мкс ставится на другое деление и сразу возвращается. Делается на 0f, когда ядро работает от своего PLL, а делитель
# простаивает и ядро не питает (0x137100 бит 0 = 1, проверяется до и после).
# Зачем: если делитель меняет деление «по концу счёта» (способ 2), то за время на чужом делении его положение относительно
# опоры PLL (по модулю 4 тиков) сдвигается — сессия может стать плохой. Если запись выравнивает его по общей черте
# (способ 3), последняя запись вернёт прежнее положение — сессия останется хорошей.
#   ПОЛЕ 04 (÷6, 540 МГц — такое деление карта даёт другим узлам) — сдвиг на 2 тика за круг: положение 0 ↔ 2;
#   ПОЛЕ 03 (÷5, 648 МГц) — сдвиг на 1 тик за круг: любое из 4 положений;
#   ПОЛЕ 06 (÷8), 0a (÷12), 0e (÷16), 1e (÷32) — кратно 4: по модели положение не сдвинется — это КОНТРОЛЬ (испортится —
#   модель неверна).
# Пишется ровно один регистр (0x1371d0), два раза подряд: «поле A = ПОЛЕ», затем исходное значение; остальные биты те же.
# Второй аргумент B — толкнуть не рабочее поле A, а поле B (биты 8–13, «вторая дорожка»: у ядра выключена битом 8 в 0x137160,
# ядро её не использует). Опыт к гипотезе «линии»: если линию выравнивания задаёт счётчик поля B, толчок сдвинет её, и при
# следующей записи делитель встанет по сдвинутой линии — хорошая сессия может стать плохой.
# До и после: регулятор выключается (lab_gov=0) и возвращается, уровень ставится 0f, потом 03. Ключи lab_nv_div_late и
# lab_nv_divb должны быть 0, тест (night.sh/hangtest.sh) не должен идти. Перезагрузка всё возвращает как было.
# Запуск: sudo python3 ~/Home/nouveau-fix/lab/div-kick.py [ПОЛЕ] [A|B]      (по умолчанию 04 A)
import mmap, os, struct, sys, glob, time, subprocess

KICK = int(sys.argv[1], 16) if len(sys.argv) > 1 else 0x04
if not 0x02 <= KICK <= 0x3e:
    sys.exit('ПОЛЕ — шестнадцатеричное 02…3e (делит на ПОЛЕ+2)')
FIELD = (sys.argv[2].upper() if len(sys.argv) > 2 else 'A')
if FIELD not in ('A', 'B'):
    sys.exit('Второй аргумент — A (рабочее поле, биты 0–5) или B (вторая дорожка, биты 8–13)')
SHIFT = 0 if FIELD == 'A' else 8
if os.geteuid() != 0:
    sys.exit('Нужен root: sudo python3 ~/Home/nouveau-fix/lab/div-kick.py [ПОЛЕ]')

PRM = '/sys/module/nouveau/parameters'
prm = lambda p: open(f'{PRM}/{p}').read().strip()
def setp(p, v):
    with open(f'{PRM}/{p}', 'w') as f:
        f.write(str(v))
for p in ('lab_nv_div_late', 'lab_nv_divb'):
    if prm(p) != '0':
        sys.exit(f'{p} = {prm(p)} — нужен 0 (опыт только на обычном делителе), ничего не делаю')
busy = subprocess.run(['pgrep', '-f', '^bash .*/lab/(night|hangtest)\\.sh'], capture_output=True, text=True).stdout.split()
if busy:
    sys.exit(f'Идёт тест (pid {" ".join(busy)}) — сначала дождись конца или останови его')
PSF = (glob.glob('/sys/kernel/debug/dri/*/pstate') or [None])[0]
if not PSF:
    sys.exit('Нет /sys/kernel/debug/dri/*/pstate (debugfs) — не могу поставить уровень')

dev = None
for d in glob.glob('/sys/bus/pci/devices/*'):
    try:
        if open(d + '/vendor').read().strip() == '0x10de' and open(d + '/class').read().startswith('0x03'):
            dev = d
            break
    except OSError:
        pass
if not dev:
    sys.exit('Видеокарта NVIDIA не найдена')
fd = os.open(dev + '/resource0', os.O_RDWR | os.O_SYNC)
bar = mmap.mmap(fd, 16 << 20, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)
rd = lambda a: struct.unpack_from('<I', bar, a)[0]
def wr(a, v): struct.pack_into('<I', bar, a, v)

def ac():
    return next((l[4:].strip() for l in open(PSF) if l.startswith('AC:')), '?')
def pstate(lv):
    with open(PSF, 'w') as f:
        f.write(lv)

log = []
def say(s):
    line = f'{time.strftime("%T")} {s}'
    print(line); sys.stdout.flush(); log.append(line)

DIV, MUX = 0x1371d0, 0x137100
gov0 = prm('lab_gov')
say(f'делитель ядра {rd(DIV):08x}, переключатель {rd(MUX):08x}, режим: {ac()}, lab_gov={gov0}, '
    f'тайм-аутов с загрузки {prm("lab_mux_timeouts")}')
setp('lab_gov', 0)
try:
    pstate('0f'); time.sleep(2)
    m0, d0 = rd(MUX), rd(DIV)
    say(f'на 0f: режим {ac()}; переключатель {m0:08x}, делитель {d0:08x}')
    if not m0 & 1:
        raise SystemExit('ядро не на PLL (0x137100 бит 0 = 0) — делитель сейчас питает ядро, не трогаю')
    if not d0 & 0x80000000:
        raise SystemExit(f'делитель {d0:08x} выключен (бит 31 = 0) — не тот случай, не трогаю')
    src = rd(0x137160)
    if FIELD == 'B' and src & 0x100:
        raise SystemExit(f'источник 0x137160 = {src:08x}: бит 8 стоит — поле B сейчас рабочее, не трогаю')
    kick = (d0 & ~(0x3f << SHIFT)) | (KICK << SHIFT)
    t0 = time.perf_counter_ns()
    wr(DIV, kick)
    wr(DIV, d0)
    t1 = time.perf_counter_ns()
    d1, m1 = rd(DIV), rd(MUX)
    dt = (t1 - t0) / 1000
    circ = dt * 3240 / (KICK + 2)
    say(f'ТОЛЧОК поля {FIELD}: делитель {d0:08x} -> {kick:08x} (÷{KICK + 2}) -> {d0:08x} за {dt:.2f} мкс '
        f'(≈ {circ:.0f} кругов по ÷{KICK + 2}); после: делитель {d1:08x}, переключатель {m1:08x}'
        + ('' if d1 == d0 else '  ⚠ ДЕЛИТЕЛЬ НЕ ВЕРНУЛСЯ') + ('' if m1 & 1 else '  ⚠ ЯДРО УШЛО С PLL'))
finally:
    pstate('03'); time.sleep(2)
    setp('lab_gov', gov0)
    say(f'вернул: режим {ac()}, lab_gov={prm("lab_gov")}, делитель {rd(DIV):08x}, переключатель {rd(MUX):08x}')
    res = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'results')
    out = os.path.join(res, f'div-kick-{time.strftime("%Y%m%d-%H%M%S")}-{KICK:02x}{"" if FIELD == "A" else "-B"}.txt')
    try:
        with open(out, 'w') as f:
            f.write('\n'.join(log) + '\n')
        if os.environ.get('SUDO_UID'):
            os.chown(out, int(os.environ['SUDO_UID']), int(os.environ.get('SUDO_GID', os.environ['SUDO_UID'])))
        print(f'журнал: {os.path.normpath(out)}')
    except OSError as e:
        print(f'журнал не записан: {e}')
