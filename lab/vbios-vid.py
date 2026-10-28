#!/usr/bin/env python3
# VID (напряжение) из записей драйвера NVIDIA в регистры GPIO 0xe104/0xe108/0xe280/0xe284: по таблице GPIO из DCB VBIOS
# (разбор как в nouveau nvkm/subdev/bios/gpio.c, раскладка регистров как в nvkm/subdev/gpio/nv50.c: 8 линий на регистр,
# 4 бита на линию, бит 0 — выход) находим линии VID0..VID7 (функции 0x04,0x05,0x06,0x1a,0x73..0x76) и читаем биты.
# Напряжение — по таблице 0x40 (base + step * VID). Только чтение.
# python3 -I lab/vbios-vid.py ROM метка=e104:XXXXXXXX[,e280:XXXXXXXX,...] ...
import sys, struct, re, subprocess, os
rom = open(sys.argv[1], 'rb').read()
rd8 = lambda o: rom[o]; rd16 = lambda o: struct.unpack_from('<H', rom, o)[0]; rd32 = lambda o: struct.unpack_from('<I', rom, o)[0]
dcb = rd16(0x36); ver = rd8(dcb)
assert ver >= 0x30 and rd32(dcb + 6) == 0x4edcbdcb, f'DCB ver {ver:#x}'
hdr = rd8(dcb + 1)
gpio = rd16(dcb + 0x0a) if hdr >= 0x0c else 0
assert gpio, 'нет таблицы GPIO'
gver, ghdr, gcnt, glen = rd8(gpio), rd8(gpio + 1), rd8(gpio + 2), rd8(gpio + 3)
VID = {0x04: 0, 0x05: 1, 0x06: 2, 0x1a: 3, 0x73: 4, 0x74: 5, 0x75: 6, 0x76: 7}
lines = {}
for e in range(gcnt):
    d = gpio + ghdr + e * glen
    if gver < 0x41:
        info = rd32(d); line, func, log0, log1 = info & 0x1f, (info >> 8) & 0xff, (info >> 27) & 3, (info >> 29) & 3
    else:
        info, info1 = rd32(d), rd8(d + 4); line, func, log0, log1 = info & 0x3f, (info >> 8) & 0xff, (info1 >> 4) & 3, (info1 >> 6) & 3
    if func in VID: lines[VID[func]] = (line, log0, log1)
print(f'{os.path.basename(sys.argv[1])}: DCB {ver:#x} @ {dcb:#x}, GPIO таблица {gver:#x} ({gcnt} записей по {glen}); линии VID:',
      ', '.join(f'VID{b}=линия {l} (log0 {g0:#x}, log1 {g1:#x})' for b, (l, g0, g1) in sorted(lines.items())) or 'нет (PWM?)')
vt = subprocess.run([sys.executable, '-I', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'vbios-volt.py'), '--text', sys.argv[1]], capture_output=True, text=True).stdout
m = re.search(r'base (\d+) мкВ, step (-?\d+) мкВ/VID, vidmask (0x[0-9a-f]+), max (\d+)', vt)
base, step, vidmask, vmax = int(m[1]), int(m[2]), int(m[3], 16), int(m[4])
REG = {0xe104: 0, 0xe108: 1, 0xe280: 2, 0xe284: 3}
for arg in sys.argv[2:]:
    label, vals = arg.split('=', 1)
    regs = {}
    for kv in vals.split(','):
        k, v = kv.split(':'); regs[int(k, 16)] = int(v, 16)
    vid, miss, bits = 0, [], []
    for b, (line, log0, log1) in sorted(lines.items()):
        if not (vidmask >> b) & 1: continue
        reg = [0xe104, 0xe108, 0xe280, 0xe284][line >> 3]; shift = (line & 7) << 2
        if reg not in regs: miss.append(f'VID{b}@{reg:x}'); continue
        out = (regs[reg] >> shift) & 1
        state = 1 if out == (log1 & 1) else 0
        bits.append(f'VID{b}={state}'); vid |= state << b
    uv = min(base + step * vid, vmax)
    print(f'  {label}: VID {vid:#04x} ({" ".join(bits)}){" — нет значений " + " ".join(miss) if miss else ""} → {uv/1e6:.4f} В')
