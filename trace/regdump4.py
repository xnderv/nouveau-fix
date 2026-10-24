#!/usr/bin/env python3
# ТОЛЬКО ЧТЕНИЕ, версия 4 (24.10): диапазоны regdump3 (проверены под работающим NVIDIA в записи 1, без блока PMU)
# плюс отдельные регистры, которые сам драйвер NVIDIA пишет или читает вокруг смены частот (записи try1/try2):
# замедлитель PTHERM (скобка), кросс-бар PXBAR, 0x001548, 0x00e9e0, 0x022680/0x02241c, 0x020130/0x020144.
# Только адреса, к которым обращается NVIDIA (FSRM_STATUS 0x0201e0/e4 — тысячи раз читал наш драйвер), без «дыр»
# (чтение дыры = ошибка шины).
# 24.10, после зависания записи 3: блоки памяти PFB (0x100700…, 0x10f000…0x10fc00) и PDISP 0x610000… больше НЕ читаются.
# В 0x10f000…0x10fc00 лежат порты шаблонов тренировки памяти 0x10f918…0x10f924, 0x10f968/96c: чтение сдвигает их
# внутренний указатель (известно с 20.10, lab/regsnap.py их пропускает). Все четыре прежних прогона под NVIDIA зависли после
# снимков с этим диапазоном; в записи 3 — через 1,5 с после снимка на 03, как только пошла нагрузка. Для частот этот блок не нужен.
# Запуск: sudo python3 regdump4.py МЕТКА ФАЙЛ
import mmap, os, struct, sys, glob, time

RANGES = [
    (0x000000, 0x000010, 'PMC id'),
    (0x00e800, 0x00e840, 'SPPLL базовые генераторы'),
    (0x020000, 0x020100, 'PTHERM'),
    (0x132000, 0x132200, 'MPLL генератор памяти'),
    (0x137000, 0x137400, 'PCLOCK все узлы'),
    (0x611200, 0x611210, 'PDISP 0x611200'),
]
SINGLE = [
    ('PTHERM замедлитель FSRM 2/3/4 и статус (0 = GPC, 1 = hubk06)',
     [0x020130, 0x020144, 0x020160, 0x020164, 0x020180, 0x020184, 0x0201a0, 0x0201a4, 0x0201e0, 0x0201e4]),
    ('PXBAR кросс-бар', [0x13b054, 0x13b0d4, 0x13c054, 0x13c0d4, 0x13c154, 0x13c1d4, 0x13c844,
                         0x13e014, 0x13e054, 0x13ec14]),
    ('прочее вокруг смены частот', [0x001548, 0x00e9e0, 0x02241c, 0x022680]),
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
for name, regs in SINGLE:
    out.write(f'## {name}\n')
    for a in regs:
        v = struct.unpack_from('<I', bar, a)[0]
        out.write(f'{a:06x} {v:08x}\n')
out.close()
