#!/usr/bin/env python3
# ТОЛЬКО ЧТЕНИЕ: напряжение ядра и памяти, которое карта РЕАЛЬНО выставила через линии GPIO (VID),
# и скорость линии PCIe — в сравнении с тем, что писал драйвер NVIDIA 390 на этой карте (запись 20.10).
# Линии из таблицы GPIO этого VBIOS: VID_0 = 17, VID_1 = 2, VID_2 = 5, VID_3 = 6, VID_4 = 7, MEM_VOLTAGE = 23.
# Таблица напряжений VBIOS: 1 212 500 мкВ − VID × 12 500. NVIDIA: 03/07 — VID 21 = 0,950 В; 0f — VID 11 = 1,075 В;
# MEM_VOLTAGE после первого подъёма памяти — 1 и больше не снимается; PCIe: 0f — 5 GT/s (gen2), 03/07 — 2,5 GT/s (gen1).
# Запуск: sudo python3 ~/nouveau-fix/lab/voltcheck.py
import glob, mmap, os, struct, subprocess, sys
dev = next((d for d in glob.glob('/sys/bus/pci/devices/*')
            if open(d + '/vendor').read().strip() == '0x10de' and open(d + '/class').read().startswith('0x03')), None)
if not dev: sys.exit('Видеокарта NVIDIA не найдена')
fd = os.open(dev + '/resource0', os.O_RDONLY | os.O_SYNC)
bar = mmap.mmap(fd, 16 << 20, mmap.MAP_SHARED, mmap.PROT_READ)
rd = lambda a: struct.unpack_from('<I', bar, a)[0]
regs = [0xe104, 0xe108, 0xe280, 0xe284]
v = {r: rd(r) for r in regs}
nib = lambda line: (v[regs[line >> 3]] >> ((line & 7) * 4)) & 0xf
vid_lines = [17, 2, 5, 6, 7]
vid = sum(((nib(l) & 1) << i) for i, l in enumerate(vid_lines))
uv = 1212500 - vid * 12500
ps = next((l.strip() for f in glob.glob('/sys/kernel/debug/dri/*/pstate') for l in open(f) if l.startswith('AC')), '?')
print(f'режим карты: {ps}')
print(f'GPIO: 0xe104={v[0xe104]:08x} 0xe108={v[0xe108]:08x} 0xe280={v[0xe280]:08x} 0xe284={v[0xe284]:08x}')
print(f'ядро: VID {vid} (0b{vid:05b}) -> {uv/1e6:.3f} В; линии VID_0..4 = ' + ' '.join(f'{nib(l):x}' for l in vid_lines)
      + f'; MEM_VOLTAGE (линия 23) = {nib(23):x} -> {"высокое" if nib(23) & 1 else "низкое"}')
nv = {'0f': (0x27240740, 0x74000072, 1.075, '5 GT/s'), '07': (0x72740240, 0x74000076, 0.950, '2.5 GT/s'), '03': (0x72740240, 0x74000076, 0.950, '2.5 GT/s')}
import re
m = re.search(r'memory (\d+) MHz', ps); mem = int(m.group(1)) if m else 0
mode = '0f' if mem > 1000 else '07' if mem > 200 else '03' if mem else '?'
try:
    lnk = subprocess.run(['lspci', '-vv', '-s', os.path.basename(dev)], capture_output=True, text=True).stdout
    lnk = re.search(r'LnkSta:\s*Speed ([\d.]+GT/s)', lnk); lnk = lnk.group(1) if lnk else '?'
except Exception: lnk = '?'
print(f'PCIe сейчас: {lnk}')
if mode in nv:
    e104, e280, volt, pcie = nv[mode]
    ok_v = abs(uv / 1e6 - volt) < 0.001
    ok_g = (v[0xe104] & 0x33333333) == (e104 & 0x33333333)   # биты 0,1 каждой линии (бит 2 — чтение состояния)
    print(f'NVIDIA в режиме {mode}: {volt:.3f} В, 0xe104={e104:08x}, PCIe {pcie}')
    print(f'  напряжение ядра: {"✅ совпадает" if ok_v else "❌ НЕ совпадает"}; биты GPIO (управляющие): {"✅ совпадают" if ok_g else "❌ отличаются"}; '
          f'PCIe: {"✅ совпадает" if lnk.startswith(pcie.split()[0]) else "❌ отличается (у NVIDIA " + pcie + ")"}')
