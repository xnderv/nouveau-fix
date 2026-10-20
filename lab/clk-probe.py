#!/usr/bin/env python3
# ТОЛЬКО ЧТЕНИЕ регистров тактирования карты (блок 0x137000): для ядра, ROP, hubk07, hubk06, hubk01
# показывает источник (делитель/PLL), коэффициенты PLL, опорный делитель PLL и итоговые делители.
# Ничего не записывает. Запуск: sudo python3 ~/nouveau-fix/lab/clk-probe.py [метка]
import mmap, os, struct, sys, glob

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

print('Метка:', sys.argv[1] if len(sys.argv) > 1 else '-')
for a in (0x00e800, 0x00e804, 0x00e820, 0x00e824):
    print(f'  SPPLL R[{a:06x}] = {rd(a):08x}')
ssel = rd(0x137100)
print(f'  0x137100 (выбор PLL, бит = узел) = {ssel:08x}')
names = {0: 'ядро gpc', 1: 'ROP', 2: 'hubk07', 7: 'hubk06', 8: 'hubk01'}
for idx, nm in names.items():
    print(f'--- idx {idx:02x} {nm}: {"PLL" if ssel & (1 << idx) else "делитель"}')
    if idx <= 7:
        pll = 0x137000 + idx * 0x20 if idx < 7 else 0x1370e0
        ctrl, coef = rd(pll), rd(pll + 4)
        P, N, M = (coef >> 16) & 0x3f, (coef >> 8) & 0xff, coef & 0xff
        print(f'    PLL  R[{pll:06x}] ctrl={ctrl:08x} coef={coef:08x}  (N={N} M={M} P={P})  +08={rd(pll+8):08x} +0c={rd(pll+0xc):08x} +10={rd(pll+0x10):08x}')
        print(f'    опора PLL: dsrc R[{0x137120+idx*4:06x}]={rd(0x137120+idx*4):08x}  dctl R[{0x137140+idx*4:06x}]={rd(0x137140+idx*4):08x}')
    print(f'    делитель: dsrc R[{0x137160+idx*4:06x}]={rd(0x137160+idx*4):08x}  ddiv R[{0x1371d0+idx*4:06x}]={rd(0x1371d0+idx*4):08x}')
    print(f'    итоговый mdiv R[{0x137250+idx*4:06x}]={rd(0x137250+idx*4):08x}')
