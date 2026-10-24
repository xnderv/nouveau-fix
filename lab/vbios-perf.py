#!/usr/bin/env python3
# Таблица производительности VBIOS (BIT P, версия 0x40) целиком, включая биты 14-15 частоты узла и байты записи уровня,
# которые nouveau отбрасывает. Только чтение файла образа: python3 lab/vbios-perf.py ПУТЬ_К_vbios.rom
import sys, struct
b = open(sys.argv[1], 'rb').read()
r8 = lambda o: b[o]; r16 = lambda o: struct.unpack_from('<H', b, o)[0]; r32 = lambda o: struct.unpack_from('<I', b, o)[0]
bit = b.find(b'\xff\xb8BIT')
n, esz = r8(bit + 10), r8(bit + 9)
P = None
for i in range(n):
    e = bit + 12 + i * esz
    if chr(r8(e)) == 'P': P = (r8(e + 1), r16(e + 2), r16(e + 4))
print('BIT P', P)
perf = r32(P[2])
ver, hdr, ln, ssz, snr, cnt = r8(perf), r8(perf + 1), r8(perf + 2), r8(perf + 3), r8(perf + 4), r8(perf + 5)
print(f'perf @{perf:#x} ver {ver:#x} hdr {hdr} len {ln} ssz {ssz} snr {snr} cnt {cnt}')
print('header:', b[perf:perf + hdr].hex(' '))
dom = {0: 'hubk06', 1: 'hubk01', 2: 'copy', 3: 'gpc', 4: 'rop', 5: 'mem', 6: 'vdec', 10: 'pmu', 11: 'hubk07'}
for i in range(cnt):
    e = perf + hdr + i * (ln + snr * ssz)
    print(f'\nуровень {r8(e):02x}: запись {b[e:e + ln].hex(" ")}')
    for s in range(snr):
        d = e + ln + s * ssz
        w = r16(d)
        print(f'  {s:2d} {dom.get(s, "?"):7s} {b[d:d + ssz].hex(" ")}  частота {w & 0x3fff:5d} МГц, биты 14-15 = {w >> 14}')
