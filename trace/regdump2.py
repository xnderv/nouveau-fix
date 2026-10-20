#!/usr/bin/env python3
# ТОЛЬКО ЧТЕНИЕ: расширенный снимок регистров памяти, тактирования, PMU и дисплея GTX 560 Ti.
# Версия 2 (20.10, для памяти): весь блок таймингов 0x10f000-0x10ffff, разделы памяти 0x110000-0x113fff
# (участки, которые трогает скрипт NVIDIA), 0x100b00/0x100c00, 0x13d800, GPIO 0x00e000.
# Порты данных PMU (0x10a180-0x10a1ff) пропускаются: их чтение сдвигает внутренний указатель.
# Запуск: sudo python3 regdump2.py МЕТКА ФАЙЛ
import mmap, os, struct, sys, glob, time

RANGES = [
    (0x000000, 0x000010, 'PMC id'),
    (0x00e000, 0x00e300, 'GPIO / разное (e108, e280 в скрипте)'),
    (0x00e800, 0x00e840, 'SPPLL базовые генераторы'),
    (0x020000, 0x020200, 'PTHERM'),
    (0x100700, 0x100800, 'PFB 0x1007xx'),
    (0x100b00, 0x100b40, 'PFB 0x100b0c'),
    (0x100c00, 0x100c40, 'PFB 0x100c00'),
    (0x10a000, 0x10a180, 'PMU falcon'),
    (0x10a200, 0x10a800, 'PMU io/очереди'),
    (0x10f000, 0x110000, 'PFB память: тайминги, тренировка, REFPLL-зеркало 0x10fe20'),
]
for p in range(4):
    b = 0x110000 + p * 0x1000
    RANGES += [(b + 0x600, b + 0x700, f'раздел {p} 0x{b+0x600:06x}'),
               (b + 0x900, b + 0xa00, f'раздел {p} 0x{b+0x900:06x}')]
RANGES += [
    (0x132000, 0x132200, 'MPLL и REFPLL памяти'),
    (0x137000, 0x137400, 'PCLOCK все узлы'),
    (0x13d800, 0x13d900, '0x13d8f4'),
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
        if 0x10a180 <= a < 0x10a200:
            continue
        v = struct.unpack_from('<I', bar, a)[0]
        out.write(f'{a:06x} {v:08x}\n')
out.close()
