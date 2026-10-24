#!/usr/bin/env python3
# Таблицы памяти VBIOS (BIT P: rammap, ramcfg по ремешкам, timing v0x10) — только чтение файла образа.
# python3 lab/vbios-mem.py ПУТЬ_К_vbios.rom
import sys, struct
b = open(sys.argv[1], 'rb').read()
r8 = lambda o: b[o]; r16 = lambda o: struct.unpack_from('<H', b, o)[0]; r32 = lambda o: struct.unpack_from('<I', b, o)[0]
bit = b.find(b'\xff\xb8BIT'); n, esz = r8(bit + 10), r8(bit + 9)
ent = {}
for i in range(n):
    e = bit + 12 + i * esz
    ent[chr(r8(e))] = (r8(e + 1), r16(e + 2), r16(e + 4))
print('BIT:', {k: (v[0], hex(v[2])) for k, v in ent.items()})
pv, pl, po = ent['P']
print('P table pointers:', [hex(r32(po + 4 * i)) for i in range(pl // 4)])
rammap = r32(po + 4); timing = r32(po + 8)
# rammap
ver, hdr, cnt, ln, snr, ssz = r8(rammap), r8(rammap + 1), r8(rammap + 5), r8(rammap + 2), r8(rammap + 4), r8(rammap + 3)
print(f'\nrammap @{rammap:#x} ver {ver:#x} hdr {hdr} cnt {cnt} len {ln} snr {snr} ssz {ssz}')
print('  header', b[rammap:rammap + hdr].hex(' '))
for i in range(cnt):
    e = rammap + hdr + i * (ln + snr * ssz)
    print(f'  запись {i}: МГц {r16(e)}..{r16(e + 2)}  {b[e:e + ln].hex(" ")}')
    for s in range(snr):
        d = e + ln + s * ssz
        print(f'     ramcfg {s:2d}: {b[d:d + ssz].hex(" ")}')
# timing
ver, hdr, cnt, ln = r8(timing), r8(timing + 1), r8(timing + 2), r8(timing + 3)
print(f'\ntiming @{timing:#x} ver {ver:#x} hdr {hdr} cnt {cnt} len {ln}')
for i in range(cnt):
    e = timing + hdr + i * ln
    raw = b[e:e + ln]
    print(f'  timing {i:2d}: {raw.hex(" ")}')
    print(f'      dwords: ' + ' '.join(f'{struct.unpack_from("<I", raw, k)[0]:08x}' for k in range(0, ln - ln % 4, 4)))
