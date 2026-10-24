#!/usr/bin/env python3
# ТЕСТ Д: навязать тепловому датчику температуру на СЕК секунд и вернуть регистр как был. Кристалл не греется.
# ЗАПИСЬ ровно в один регистр — PTHERM 0x20008 (SENSOR_RAW по rnndb): бит 15 FORCE_TEMP, биты 22–29 — навязанная температура;
# остальные биты остаются как были. Тот же бит 15 nouveau снимает при запуске (g84_sensor_setup), так что перезагрузка
# тоже всё возвращает.
# Предел 110 °C: на 135 °C nouveau выключает машину (порог CRIT, nv_poweroff_work). На 90 °C nouveau сам включит вентилятор
# на 100 % — это ожидаемо. Возврат исходного значения — при любом выходе (конец, Ctrl+C, SIGTERM).
# Запуск: sudo python3 ~/Home/nouveau-fix/lab/therm-force.py ТЕМП СЕК
# Рядом в другой вкладке: sudo python3 ~/Home/nouveau-fix/lab/therm-probe.py --watch СЕК+20 метка
import mmap, os, struct, sys, glob, time, signal

if len(sys.argv) != 3:
    sys.exit('Запуск: sudo python3 therm-force.py ТЕМП СЕК   (ТЕМП 30–110 °C, СЕК до 300)')
T, S = int(sys.argv[1]), float(sys.argv[2])
if not 30 <= T <= 110 or not 0 < S <= 300:
    sys.exit('ТЕМП должна быть 30–110 °C, СЕК — до 300')

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

REG = 0x20008
orig = rd(REG)
if orig & (1 << 15):
    sys.exit(f'0x20008 = {orig:08x}: FORCE_TEMP уже стоит — кто-то уже навязывает температуру, ничего не делаю')
new = (orig & ~((0xff << 22) | (1 << 15))) | (T << 22) | (1 << 15)

def restore(*_):
    wr(REG, orig)
    back = rd(REG)
    print(f'{time.strftime("%T")} вернул 0x20008: {back:08x} (было {orig:08x}); датчик {rd(0x20400)} °C'
          + ('' if not back & (1 << 15) else '  ⚠ FORCE_TEMP НЕ СНЯЛСЯ — перезагрузи машину'))
    sys.stdout.flush()
    os._exit(0)

signal.signal(signal.SIGINT, restore)
signal.signal(signal.SIGTERM, restore)
print(f'{time.strftime("%T")} датчик до: {rd(0x20400)} °C; 0x20008 {orig:08x} -> {new:08x} (навязываю {T} °C на {S:g} с)')
sys.stdout.flush()
try:
    wr(REG, new)
    t0 = time.time()
    while time.time() - t0 < S:
        time.sleep(1)
        print(f'{time.strftime("%T")} датчик {rd(0x20400)} °C, CTRL_0 {rd(0x20000):08x}, FSRM_CFG_5 {rd(0x20074):08x}, '
              f'0x137100 {rd(0x137100):08x}'); sys.stdout.flush()
finally:
    restore()
