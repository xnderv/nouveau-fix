#!/usr/bin/env python3
# ТОЛЬКО ЧТЕНИЕ, версия 2: снимок ТОЛЬКО тех регистров, которые сам драйвер NVIDIA пишет при смене
# частоты памяти на этой карте (скрипты и прямые записи из записи 20.10), плюс регистры частоты памяти.
# Сплошные диапазоны больше не читаем: в них есть «дыры», и под nouveau каждое чтение дыры —
# ошибка шины с прерыванием (20.10 это вызвало сильное торможение). Эти адреса существуют наверняка.
# Порты шаблонов тренировки (0x10f918-0x10f924, 0x10f968/96c) не читаются: чтение сдвигает указатель.
# Запуск: sudo python3 ~/nouveau-fix/lab/regsnap.py МЕТКА ФАЙЛ
import mmap, os, struct, sys, glob, time

REGS = [
    0x100760, 0x100764, 0x100768, 0x10f050, 0x10f090, 0x10f200, 0x10f210, 0x10f290,
    0x10f294, 0x10f298, 0x10f29c, 0x10f2a0, 0x10f300, 0x10f310, 0x10f314, 0x10f330,
    0x10f338, 0x10f340, 0x10f344, 0x10f348, 0x10f400, 0x10f410, 0x10f420, 0x10f430,
    0x10f444, 0x10f468, 0x10f604, 0x10f610, 0x10f614, 0x10f628, 0x10f62c, 0x10f630,
    0x10f634, 0x10f640, 0x10f644, 0x10f800, 0x10f808, 0x10f824, 0x10f828, 0x10f830,
    0x10f870, 0x10f910, 0x10f914, 0x10f988, 0x10f98c, 0x10f990, 0x10f998, 0x10fb04,
    0x10fb08, 0x132000, 0x132004, 0x132020, 0x132024, 0x132100, 0x137300, 0x137310,
    0x137320, 0x137330, 0x137340, 0x137360, 0x137390, 0x1373ec, 0x1373f0, 0x1373f8,
    0x611200
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
out.write('## регистры памяти из скриптов NVIDIA\n')
for a in REGS:
    v = struct.unpack_from('<I', bar, a)[0]
    out.write(f'{a:06x} {v:08x}\n')
out.close()
