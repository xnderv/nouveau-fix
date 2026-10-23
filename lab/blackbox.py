#!/usr/bin/env python3
# ЧЁРНЫЙ ЯЩИК для «тихих» зависаний (22.10: два случая без следов в журнале — зависание шины, ядро не паникует).
# Раз в секунду пишет состояние карты в /var/log/gpu-blackbox/current.txt с принудительным сбросом на диск
# (переживает Reset и выключение). В ядре Ubuntu нет CONFIG_PSTORE_PMSG, поэтому канал ramoops из программ
# недоступен; строки самого драйвера при этом пишет ядро в console-ramoops (уровень консоли 7). Только читает карту.
# Строка: время | режим (pstate) | загрузка по прошивке PMU | температура | 0x611200 (вывод) 0x137100 (PLL select)
#         0x1373f0 (память на PLL?) 0x10a4a0/0x10a4b0 (очередь команд PMU) | gr700 (0x400700, состояние GR)
#         eng0 (0x002640, GR глазами FIFO) fifo (0x002100, прерывания FIFO) | что переключал регулятор (из dmesg)
# Версия 3 (23.10): снимок по зависанию. Два зависания 23.10 выглядели как gr=1000‰ подряд, ядро живо.
# Если загрузка GR >= 999‰ держится HANG_SEC секунд подряд или в журнале ядра появилось
# «failed to idle channel»/«SCHED_ERROR»/«runl», один раз пишется /var/log/gpu-blackbox/hang-ДАТА.txt:
# последние строки ящика и снимок регистров GR/FIFO/памяти (только те адреса, что читает сам nouveau или
# писал драйвер NVIDIA в записи 20.10 — без «дыр», каждое чтение дыры под nouveau = ошибка шины).
import glob, mmap, os, struct, sys, time
P = '/sys/module/nouveau/parameters/'
LOG = '/var/log/gpu-blackbox'
HANG_SEC = 5          # секунд подряд gr >= 999‰ до снимка
REARM_SEC = 600       # не чаще одного снимка в 10 минут
def rp(n, d='-'):
    try: return open(P + n).read().strip()
    except OSError: return d
ps = (glob.glob('/sys/kernel/debug/dri/*/pstate') or [None])[0]
def ac():
    try:
        for l in open(ps):
            if l.startswith('AC'): return l.strip()[4:]
    except Exception: pass
    return '?'
hw = next((h for h in glob.glob('/sys/class/hwmon/hwmon*') if 'nouveau' in open(h + '/name').read()), None)
def temp():
    try: return int(open(hw + '/temp1_input').read()) // 1000
    except Exception: return -1
dev = next((d for d in glob.glob('/sys/bus/pci/devices/*')
            if open(d + '/vendor').read().strip() == '0x10de' and open(d + '/class').read().startswith('0x03')), None)
fd = os.open(dev + '/resource0', os.O_RDONLY | os.O_SYNC)
bar = mmap.mmap(fd, 16 << 20, mmap.MAP_SHARED, mmap.PROT_READ)
rd = lambda a: struct.unpack_from('<I', bar, a)[0]

# Регистры снимка: GR (gr/gf100.c: intr, trap, wait_idle, ctxctl), FIFO (fifo/gf100.c: intr, engine status,
# runlist), по GPC (0x502090 — ловушка GPC, GF114 = 2 GPC), память (regsnap.py — из записи NVIDIA 20.10).
SNAP = [
    ('PMC',  [0x000200, 0x000100, 0x000140]),
    ('GR',   [0x400100, 0x400108, 0x400110, 0x400118, 0x400500, 0x40060c, 0x400700, 0x400704, 0x400708,
              0x404000, 0x404200, 0x404490, 0x404494, 0x40449c, 0x404600, 0x405840, 0x40601c, 0x407020,
              0x408030, 0x409800, 0x409804, 0x409808, 0x40980c, 0x409810, 0x409814, 0x409b00, 0x409c18, 0x409c20]),
    ('GPC',  [0x502090 + g * 0x8000 for g in range(2)]),   # GF114: 2 GPC (0x512090 — ошибка PRIVRING 23.10)
    ('FIFO', [0x002100, 0x002140, 0x002254, 0x00252c, 0x00254c, 0x00256c, 0x00258c, 0x00259c, 0x0025a0,
              0x0025a4, 0x002628, 0x002630, 0x002a00]
             + [0x0025a8 + e * 4 for e in range(6)] + [0x002640 + e * 4 for e in range(6)]   # движки 6,7 нет (TIMEOUT 23.10)
             + [0x002800 + u * 0x10 + r for u in range(3) for r in (0, 4, 8, 0xc)]),
    ('XBAR', [0x13b054, 0x13b0d4, 0x13c054, 0x13c0d4, 0x13c154, 0x13c1d4, 0x13c844, 0x13e014, 0x13e054, 0x13ec14,
              0x00e9e0, 0x001548, 0x137360, 0x1371d0, 0x1371d4, 0x1371d8, 0x409614, 0x409c00, 0x400504]),   # PXBAR + делители, которые NVIDIA пишет вокруг смены частот (запись 20.10)
    ('MEM',  [0x100760, 0x100764, 0x100768, 0x10f050, 0x10f090, 0x10f200, 0x10f210, 0x10f290, 0x10f294,
              0x10f298, 0x10f29c, 0x10f2a0, 0x10f300, 0x10f310, 0x10f314, 0x10f330, 0x10f338, 0x10f340,
              0x10f344, 0x10f348, 0x10f400, 0x10f410, 0x10f420, 0x10f430, 0x10f444, 0x10f468, 0x10f604,
              0x10f610, 0x10f614, 0x10f628, 0x10f62c, 0x10f630, 0x10f634, 0x10f640, 0x10f644, 0x10f800,
              0x10f808, 0x10f824, 0x10f828, 0x10f830, 0x10f870, 0x10f910, 0x10f914, 0x10f988, 0x10f98c,
              0x10f990, 0x10f998, 0x10fb04, 0x10fb08, 0x132000, 0x132004, 0x132020, 0x132024, 0x132100,
              0x137300, 0x137310, 0x137320, 0x137330, 0x137340, 0x137360, 0x137390, 0x1373ec, 0x1373f0,
              0x1373f8, 0x611200]),
]
def snapshot(reason, tail):
    name = f'{LOG}/hang-{time.strftime("%Y%m%d-%H%M%S")}.txt'
    with open(name, 'wb', buffering=0) as f:
        f.write(f'### снимок по зависанию {time.strftime("%F %T")}: {reason}\n'.encode())
        f.write(('## последние строки ящика\n' + ''.join(tail)).encode())
        for grp, regs in SNAP:
            f.write(f'## {grp}\n'.encode())
            for a in regs:
                try: v = f'{rd(a):08x}'
                except Exception as e: v = f'err {e}'
                f.write(f'{a:06x} {v}\n'.encode())
        os.fsync(f.fileno())
    return name

os.makedirs(LOG, exist_ok=True); out = open(f'{LOG}/current.txt', 'ab', buffering=0)
kfd = os.open('/dev/kmsg', os.O_RDONLY | os.O_NONBLOCK); os.lseek(kfd, 0, os.SEEK_END)
out.write(f'### blackbox start {time.strftime("%F %T")} kernel {os.uname().release} driver {"lab" if rp("lab_gov","")!="" else "stable" if rp("gf114_gov","")!="" else "stock"} v3\n'.encode())
tail, busy, last_snap = [], 0, -float(REARM_SEC)   # -REARM: иначе первые 10 мин после загрузки снимок не делается (ошибка 23.10)
while True:
    ev, trig = [], ''
    while True:
        try: line = os.read(kfd, 8192)   # одна запись журнала ядра за чтение
        except BlockingIOError: break
        except OSError: break
        if not line: break
        s = line.decode(errors='replace')
        if 'LAB gov' in s or 'LAB pstate' in s or 'LAB replay' in s or 'GF114' in s or 'nouveau' in s and ('ERROR' in s or 'fault' in s or 'timeout' in s):
            ev.append(s.split(';', 1)[-1].strip()[:120])
        if 'failed to idle channel' in s or 'SCHED_ERROR' in s or 'runl' in s:
            trig = s.split(';', 1)[-1].strip()[:80]
    gr, vid = rp('lab_perf_gr', rp('gf114_load_gr')), rp('lab_perf_vid', rp('gf114_load_vid'))
    t = rp('lab_gov_temp', rp('gf114_temp'))
    line = (f'{time.strftime("%T")} | {ac()} | gr {gr}‰ vid {vid}‰ | {temp()}C/{t} | '
            f'611200={rd(0x611200):08x} 137100={rd(0x137100):08x} 1373f0={rd(0x1373f0):08x} pmuq={rd(0x10a4a0):x}/{rd(0x10a4b0):x} | '
            f'gr700={rd(0x400700):08x} eng0={rd(0x002640):08x} fifo={rd(0x002100):08x} xbar={rd(0x13c054):x}/{rd(0x13c844):x}/{rd(0x13ec14):x} e9e0={rd(0x00e9e0):08x} 1548={rd(0x001548):08x}'
            + (' | ' + ' ;; '.join(ev) if ev else '') + '\n')
    out.write(line.encode()); os.fsync(out.fileno())
    tail = (tail + [line])[-15:]
    try: busy = busy + 1 if int(gr) >= 999 else 0
    except ValueError: busy = 0
    if (busy >= HANG_SEC or trig) and time.monotonic() - last_snap > REARM_SEC:   # >=: GR мог быть занят ещё до подъёма
        try:
            name = snapshot(trig or f'gr >= 999‰ {HANG_SEC} с подряд', tail)
            out.write(f'{time.strftime("%T")} | СНИМОК {name}\n'.encode()); os.fsync(out.fileno())
        except Exception as e:
            out.write(f'{time.strftime("%T")} | снимок не удался: {e}\n'.encode())
        last_snap = time.monotonic()
    time.sleep(1.0)
