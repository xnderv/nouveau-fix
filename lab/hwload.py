#!/usr/bin/env python3
# АППАРАТНЫЕ СЧЁТЧИКИ ЗАГРУЗКИ (как у NVIDIA): счётчики контроллера PMU 0x10a504..0x10a57c.
# Настраиваются ТОЧНО теми значениями, что пишет драйвер NVIDIA 390 на этой карте (запись 20.10, 35.532 с):
#   счётчик 1: маска 0x00000070 (видео: PVLD, PPDEC, PPPP), режим 2
#   счётчик 3: маска 0x00180001 (графика GR + копирование PCOPY0/1), режим 2
#   счётчик 4: маска 0x00000080 (запросы к памяти, раздел 0), режим 2
#   счётчик 5: маска 0x20000000 (шина PCIe), режим 2
#   счётчик 7: режим 3 — тикает всегда, это «полное время» для процентов
# nouveau эти счётчики не использует (в его коде PMU их нет). Пишутся только эти 9 регистров настройки;
# в конце исходные значения возвращаются. Для сравнения рядом — наш старый способ (выборка флага 0x40060c).
# Запуск: sudo python3 ~/Home/nouveau-fix/lab/hwload.py [секунд]
import mmap, os, struct, sys, glob, time

CFG = [(0x10a514, 0x00000070), (0x10a51c, 2), (0x10a534, 0x00180001), (0x10a53c, 2),
       (0x10a544, 0x00000080), (0x10a54c, 2), (0x10a554, 0x20000000), (0x10a55c, 2), (0x10a57c, 3)]
CNT = {'видео': 1, 'графика': 3, 'память': 4, 'PCIe': 5, 'всего': 7}

dev = None
for d in glob.glob('/sys/bus/pci/devices/*'):
    try:
        if open(d + '/vendor').read().strip() == '0x10de' and open(d + '/class').read().startswith('0x03'):
            dev = d; break
    except OSError:
        pass
if not dev:
    sys.exit('Видеокарта NVIDIA не найдена')
fd = os.open(dev + '/resource0', os.O_RDWR | os.O_SYNC)
bar = mmap.mmap(fd, 16 << 20, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)
rd = lambda a: struct.unpack_from('<I', bar, a)[0]
def wr(a, v): struct.pack_into('<I', bar, a, v)
cnt = lambda i: rd(0x10a508 + i * 0x10) & 0x7fffffff

orig = [(a, rd(a)) for a, _ in CFG]
print('Было: ' + ' '.join(f'{a:06x}={v:08x}' for a, v in orig))
for a, v in CFG:
    wr(a, v)
print('Стало: ' + ' '.join(f'{a:06x}={rd(a):08x}' for a, _ in CFG), flush=True)
secs = int(sys.argv[1]) if len(sys.argv) > 1 else 20
prev = {k: cnt(i) for k, i in CNT.items()}
try:
    for s in range(secs):
        busy = n = 0
        end = time.monotonic() + 1.0
        while time.monotonic() < end:
            rd(0x400700); busy += rd(0x40060c) & 1; n += 1
            time.sleep(0.01)
        now = {k: cnt(i) for k, i in CNT.items()}
        d = {k: (now[k] - prev[k]) & 0x7fffffff for k in CNT}
        prev = now
        tot = max(d['всего'], 1)
        pc = {k: 100 * d[k] // tot for k in CNT if k != 'всего'}
        print(f'{time.strftime("%T")} счётчики: графика {pc["графика"]:3d}%  память {pc["память"]:3d}%  видео {pc["видео"]:3d}%  PCIe {pc["PCIe"]:3d}%'
              f'  | выборка флага {100 * busy // max(n, 1):3d}%  | тиков за 1 с: {d["всего"]}', flush=True)
finally:
    for a, v in orig:
        wr(a, v)
    print('Настройки счётчиков возвращены как были.')
