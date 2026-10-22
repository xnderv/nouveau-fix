#!/usr/bin/env python3
# ЧЁРНЫЙ ЯЩИК для «тихих» зависаний (22.10: два случая без следов в журнале — зависание шины, ядро не паникует).
# Раз в секунду пишет состояние карты в /var/log/gpu-blackbox/current.txt с принудительным сбросом на диск
# (переживает Reset и выключение). В ядре Ubuntu нет CONFIG_PSTORE_PMSG, поэтому канал ramoops из программ
# недоступен; строки самого драйвера при этом пишет ядро в console-ramoops (уровень консоли 7). Только читает карту.
# Строка: время | режим (pstate) | загрузка по прошивке PMU | температура | 0x611200 (вывод) 0x137100 (PLL select)
#         0x1373f0 (память на PLL?) 0x10a4a0/0x10a4b0 (очередь команд PMU) | что переключал регулятор (из dmesg)
import glob, mmap, os, struct, sys, time
P = '/sys/module/nouveau/parameters/'
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
os.makedirs('/var/log/gpu-blackbox', exist_ok=True); out = open('/var/log/gpu-blackbox/current.txt', 'ab', buffering=0)
kfd = os.open('/dev/kmsg', os.O_RDONLY | os.O_NONBLOCK); os.lseek(kfd, 0, os.SEEK_END)
out.write(f'### blackbox start {time.strftime("%F %T")} kernel {os.uname().release} driver {"lab" if rp("lab_gov","")!="" else "stable" if rp("gf114_gov","")!="" else "stock"}\n'.encode())
last_ev = ''
while True:
    ev = []
    while True:
        try: line = os.read(kfd, 8192)   # одна запись журнала ядра за чтение
        except BlockingIOError: break
        except OSError: break
        if not line: break
        s = line.decode(errors='replace')
        if 'LAB gov' in s or 'LAB pstate' in s or 'LAB replay' in s or 'GF114' in s or 'nouveau' in s and ('ERROR' in s or 'fault' in s or 'timeout' in s):
            ev.append(s.split(';', 1)[-1].strip()[:120])
    gr, vid = rp('lab_perf_gr', rp('gf114_load_gr')), rp('lab_perf_vid', rp('gf114_load_vid'))
    t = rp('lab_gov_temp', rp('gf114_temp'))
    line = (f'{time.strftime("%T")} | {ac()} | gr {gr}‰ vid {vid}‰ | {temp()}C/{t} | '
            f'611200={rd(0x611200):08x} 137100={rd(0x137100):08x} 1373f0={rd(0x1373f0):08x} pmuq={rd(0x10a4a0):x}/{rd(0x10a4b0):x}'
            + (' | ' + ' ;; '.join(ev) if ev else '') + '\n')
    out.write(line.encode()); os.fsync(out.fileno())
    time.sleep(1.0)
