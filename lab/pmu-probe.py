#!/usr/bin/env python3
# ТОЛЬКО ЧТЕНИЕ регистров видеокарты: что видит микроконтроллер PMU (часы, входы/выходы),
# в каком он состоянии, и чем сейчас тактируется память. Ничего не записывает.
# Запуск: sudo python3 ~/Home/nouveau-fix/lab/pmu-probe.py
import mmap, os, struct, sys, time, glob

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

fd = os.open(dev + '/resource0', os.O_RDONLY | os.O_SYNC)
bar = mmap.mmap(fd, 16 << 20, mmap.MAP_SHARED, mmap.PROT_READ)

def rd(a):
    return struct.unpack_from('<I', bar, a)[0]

print('Карта:', os.path.basename(dev))
t1 = rd(0x10a02c); time.sleep(0.1); t2 = rd(0x10a02c)
print(f'PMU таймер (0x10a02c):       {t1:08x} -> {t2:08x} через 0,1 с  =>',
      'ИДЁТ' if t1 != t2 else 'СТОИТ (PMU не видит своих часов)')
p = [rd(0x10a7c4) for _ in range(3)]
print('PMU вход PPWR_INPUT (0x10a7c4):', ' '.join(f'{v:08x}' for v in p),
      '  (в журнале драйвера после сценария было 0ccf3730)')
o = rd(0x10a7c0)
print(f'PMU выход PPWR_OUTPUT (0x10a7c0): {o:08x}   бит FB_PAUSE (0x4) = {"1" if o & 4 else "0"}')
cpu = rd(0x10a100)
print(f'PMU CPUCTL (0x10a100):       {cpu:08x}   {"ОСТАНОВЛЕН" if cpu & 0x10 else "работает"}')
print(f'PMU очередь команд H/T (0x10a4a0/0x10a4b0): {rd(0x10a4a0):08x} / {rd(0x10a4b0):08x}')
print(f'PMU очередь ответов H/T (0x10a4c8/0x10a4cc): {rd(0x10a4c8):08x} / {rd(0x10a4cc):08x}')
print(f'PMU ctxsw (0x10a128):         {rd(0x10a128):08x}')
print(f'Память: MPLL ctrl/coef (0x132000/0x132004): {rd(0x132000):08x} / {rd(0x132004):08x}')
print(f'Память: источник (0x1373f0): {rd(0x1373f0):08x}  (бит 1 = от MPLL, иначе от делителя)')
print(f'Память: делитель (0x137300/0x137310): {rd(0x137300):08x} / {rd(0x137310):08x}')
