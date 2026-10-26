#!/usr/bin/env python
# -*- coding: utf-8 -*-
# ТОЛЬКО ЧТЕНИЕ. То же, что regdump4.py (те же диапазоны и регистры), но для Ubuntu 10.04: Python 2.6 не знает f-строк.
# Запуск: sudo python regdump-lucid.py МЕТКА ФАЙЛ
import mmap, os, struct, sys, glob, time

RANGES = [
    (0x000000, 0x000010, 'PMC id'),
    (0x00e800, 0x00e840, 'SPPLL'),
    (0x020000, 0x020100, 'PTHERM'),
    (0x132000, 0x132200, 'MPLL'),
    (0x137000, 0x137400, 'PCLOCK'),
    (0x611200, 0x611210, 'PDISP 0x611200'),
]
SINGLE = [
    ('PTHERM FSRM', [0x020130, 0x020144, 0x020160, 0x020164, 0x020180, 0x020184, 0x0201a0, 0x0201a4, 0x0201e0, 0x0201e4]),
    ('PXBAR', [0x13b054, 0x13b0d4, 0x13c054, 0x13c0d4, 0x13c154, 0x13c1d4, 0x13c844, 0x13e014, 0x13e054, 0x13ec14]),
    ('misc', [0x001548, 0x00e9e0, 0x02241c, 0x022680]),
]

dev = None
for d in glob.glob('/sys/bus/pci/devices/*'):
    try:
        if open(d + '/vendor').read().strip() == '0x10de' and open(d + '/class').read().startswith('0x03'):
            dev = d
            break
    except (IOError, OSError):
        pass
if not dev:
    sys.exit('NVIDIA GPU not found')
fd = os.open(dev + '/resource0', os.O_RDONLY | os.O_SYNC)
bar = mmap.mmap(fd, 16 << 20, mmap.MAP_SHARED, mmap.PROT_READ)
label = len(sys.argv) > 1 and sys.argv[1] or '-'
out = len(sys.argv) > 2 and open(sys.argv[2], 'a') or sys.stdout
out.write('### %s %s\n' % (label, time.strftime('%Y-%m-%d %H:%M:%S')))
for lo, hi, name in RANGES:
    out.write('## %s\n' % name)
    for a in range(lo, hi, 4):
        out.write('%06x %08x\n' % (a, struct.unpack_from('<I', bar, a)[0]))
for name, regs in SINGLE:
    out.write('## %s\n' % name)
    for a in regs:
        out.write('%06x %08x\n' % (a, struct.unpack_from('<I', bar, a)[0]))
out.close()
