#!/usr/bin/env python3
# ТОЛЬКО ЧТЕНИЕ теплового блока PTHERM (0x020000) и делителей ядра: датчик, пороги, аппаратное тепловое замедление (тест Д).
# Поля — по rnndb (envytools ptherm.xml); 0x20008 бит 15 = FORCE_TEMP подтверждён и кодом nouveau (g84_sensor_setup снимает
# его на картах «с безумными значениями по умолчанию»). Ничего не записывает.
# Запуск: sudo python3 ~/Home/nouveau-fix/lab/therm-probe.py [метка]            — снимок с расшифровкой
#         sudo python3 ~/Home/nouveau-fix/lab/therm-probe.py --watch СЕК [метка] — раз в 0,1 с печатать изменения
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
f = lambda v, lo, hi: (v >> lo) & ((1 << (hi - lo + 1)) - 1)

# пороги (I2C_SLAVE 0x20400 + …). На GF114 nouveau их НЕ пишет (gt215_therm: программный опрос раз в секунду, его 90/95/105/135 —
# только в hwmon); в регистрах — значения загрузки (devinit VBIOS). Снимок 24.10 18:59: CRIT 104 (гист. 10), T2 102, T6 99, T8 96, T10 97.
THRS = [(0x20480, 'CRIT', 'аппаратное замедление, делитель CRIT'), (0x20484, 'CRIT_HYST', ''),
        (0x204c4, 'T1', ''), (0x204c0, 'T2', 'аппаратное замедление, делитель T2; NVIDIA читала 0x66 = 102'),
        (0x20418, 'T3', ''), (0x20414, 'T4', ''),
        (0x204dc, 'T5', ''), (0x204d8, 'T6', ''), (0x204e4, 'T7', ''), (0x204e0, 'T8', ''), (0x204ec, 'T9', ''), (0x204e8, 'T10', '')]
CLK = {0: 'ядро gpc', 1: 'ROP', 2: 'hubk07', 7: 'hubk06', 8: 'hubk01'}

def snapshot():
    c0, c1, raw = rd(0x20000), rd(0x20004), rd(0x20008)
    print(f'  датчик 0x20400 = {rd(0x20400)} °C;  0x20008 = {raw:08x}: сырое {f(raw,0,14)}, FORCE_TEMP {f(raw,15,15)}, '
          f'навязанная {f(raw,22,29)} °C, включён {f(raw,31,31)};  0x2000c = {rd(0x2000c):08x}')
    st = ['CRIT', 'T1', 'T2', 'T3', 'T4', 'вход0', 'вход1', 'вход2']
    print(f'  CTRL_0 0x20000 = {c0:08x}: сработали {[n for i, n in enumerate(st) if c0 >> (20 + i) & 1] or "ничего"}')
    print(f'  окна датчика: STATUS_1 0x20404 = {rd(0x20404):08x}, STATUS_0 0x20408 = {rd(0x20408):08x}, '
          f'EN_0 0x2040c = {rd(0x2040c):08x}, EN_1 0x20410 = {rd(0x20410):08x} (NVIDIA пишет EN_0 = 0x79, EN_1 = 0x3f)')
    en = {0: 'вход0', 1: 'вход1', 2: 'вход2', 3: 'CRIT', 4: 'T4', 5: 'T2', 6: 'T5', 7: 'T7', 8: 'T9', 12: 'b12', 16: 'b16', 20: 'b20'}
    print(f'  CTRL_1 0x20004 = {c1:08x}: включены (аппаратное замедление) {[n for b, n in en.items() if c1 >> b & 1]}')
    for a, n, note in THRS:
        print(f'    порог {n:9} 0x{a:05x} = {rd(a):3d}  {note}')
    c5 = rd(0x20074)
    print(f'  FSRM_CFG_5 0x20074 = {c5:08x}: делитель CRIT {f(c5,0,2)}, T2 {f(c5,4,6)}, T4 {f(c5,8,10)}; '
          f'ТЕКУЩИЙ {f(c5,24,26)}; FORCE_ALT_DIV {f(c5,31,31)}')
    print(f'  0x20060 = {rd(0x20060):08x} (ALT_DIV {f(rd(0x20060),0,5)}, ALT_FSMR {f(rd(0x20060),8,15)});  0x20064 = {rd(0x20064):08x};  '
          f'0x20110 = {rd(0x20110):08x};  0x20114 = {rd(0x20114):08x};  0x20138 = {rd(0x20138):08x}')
    for i in range(4):
        s = rd(0x201e0 + 4 * i)
        print(f'  FSRM[{i}] 2/3/4 = {rd(0x20160+4*i):08x} {rd(0x20180+4*i):08x} {rd(0x201a0+4*i):08x}; статус {s:08x}: '
              f'делитель {f(s,0,5)}, FSRM {f(s,8,15)}, тепловая защита {f(s,19,19)}')
    print(f'  0x137100 (PLL по узлам) = {rd(0x137100):08x}')
    for i, n in CLK.items():
        print(f'    {n:9}: 0x{0x137160+4*i:06x} = {rd(0x137160+4*i):08x}  делитель 0x{0x1371d0+4*i:06x} = {rd(0x1371d0+4*i):08x}  '
              f'пост 0x{0x137250+4*i:06x} = {rd(0x137250+4*i):08x}')

def keyregs():
    k = {'темп': rd(0x20400), 'CTRL_0': rd(0x20000), 'ST1': rd(0x20404), 'ST0': rd(0x20408), 'SENSOR': rd(0x20008),
         'CFG_5': rd(0x20074), '137100': rd(0x137100)}
    for i in range(4):
        k[f'FSRM{i}'] = rd(0x201e0 + 4 * i)
    for i in CLK:
        k[f'{0x137160+4*i:06x}'] = rd(0x137160 + 4 * i)
        k[f'{0x1371d0+4*i:06x}'] = rd(0x1371d0 + 4 * i)
    return k

args = sys.argv[1:]
if args[:1] == ['--watch']:
    secs = float(args[1]); label = args[2] if len(args) > 2 else '-'
    print(f'Метка: {label}; наблюдаю {secs} с, печатаю изменения')
    prev = keyregs(); t0 = time.time()
    print(f'{time.strftime("%T")} ' + ' '.join(f'{k}={v:x}' if k != 'темп' else f'{k}={v}' for k, v in prev.items()))
    while time.time() - t0 < secs:
        time.sleep(0.1)
        cur = keyregs()
        ch = [f'{k}: {prev[k]:x} -> {v:x}' if k != 'темп' else f'{k}: {prev[k]} -> {v}' for k, v in cur.items() if v != prev[k]]
        if ch:
            print(f'{time.strftime("%T")}.{int(time.time()*1000)%1000:03d} ' + '; '.join(ch)); sys.stdout.flush()
        prev = cur
else:
    print('Метка:', args[0] if args else '-', '  время', time.strftime('%T'))
    snapshot()
