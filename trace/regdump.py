#!/usr/bin/env python3
# ТОЛЬКО ЧТЕНИЕ: снимок регистров тактирования, памяти, PMU и дисплея GTX 560 Ti.
# Порты данных PMU (0x10a180-0x10a1ff) пропускаются: их чтение сдвигает внутренний указатель.
# Запуск: sudo python3 regdump.py МЕТКА ФАЙЛ
import mmap, os, struct, sys, glob, time

RANGES = [
    (0x000000, 0x000010, 'PMC id'),
    (0x00e800, 0x00e840, 'SPPLL базовые генераторы'),
    (0x020000, 0x020100, 'PTHERM'),
    (0x100700, 0x100800, 'PFB'),
    (0x10a000, 0x10a180, 'PMU falcon'),
    (0x10a200, 0x10a800, 'PMU io/очереди'),
    (0x10f000, 0x10fc00, 'PFB память, тайминги'),
    (0x132000, 0x132200, 'MPLL генератор памяти'),
    (0x137000, 0x137400, 'PCLOCK все узлы'),
    (0x610000, 0x610100, 'PDISP ядро'),
    (0x611200, 0x611210, 'PDISP 0x611200'),
    (0x61c140, 0x61c150, 'PDISP 0x61c140'),
]

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
label = sys.argv[1] if len(sys.argv) > 1 else '-'
out = open(sys.argv[2], 'a') if len(sys.argv) > 2 else sys.stdout
out.write(f'### {label} {time.strftime("%F %T")}\n')
for lo, hi, name in RANGES:
    out.write(f'## {name}\n')
    for a in range(lo, hi, 4):
        v = struct.unpack_from('<I', bar, a)[0]
        out.write(f'{a:06x} {v:08x}\n')
out.close()
