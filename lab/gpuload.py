#!/usr/bin/env python3
# ТОЛЬКО ЧТЕНИЕ: загрузка графического ядра по флагу «занят» (регистр 0x40060c, бит 0 —
# тот же, по которому nouveau ждёт простоя ядра). Опрос 200 раз в секунду, раз в секунду печатает % занятости.
# Читаются только 0x400700 (nouveau читает его перед 0x40060c) и 0x40060c — оба существуют.
# Запуск: sudo python3 ~/Home/nouveau-fix/lab/gpuload.py [секунд]
import mmap, os, struct, sys, glob, time

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
rd = lambda a: struct.unpack_from('<I', bar, a)[0]
secs = int(sys.argv[1]) if len(sys.argv) > 1 else 20
for s in range(secs):
    busy = n = 0
    end = time.monotonic() + 1.0
    while time.monotonic() < end:
        rd(0x400700)
        busy += rd(0x40060c) & 1
        n += 1
        time.sleep(0.005)
    pct = 100 * busy // max(n, 1)
    print(f'{time.strftime("%T")} занято {pct:3d}%  ' + '#' * (pct // 4), flush=True)
