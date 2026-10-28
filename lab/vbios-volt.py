#!/usr/bin/env python3
# Таблица напряжений VBIOS (BIT P v2 → +0x0c; версии таблицы 0x40/0x30/0x20/0x12 по nouveau nvkm/subdev/bios/volt.c, класс Г)
# и связь с таблицей уровней (байт 2 записи уровня — индекс напряжения). Только чтение файлов.
#   python3 -I lab/vbios-volt.py --text ОБРАЗ.rom          — таблица одного образа
#   python3 -I lab/vbios-volt.py --corpus КАТАЛОГ [--pci 10de:1200]   — распределение по корпусу
import sys, os, glob, struct, argparse, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from importlib import util as _u
_s = _u.spec_from_file_location('vd', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'vbios-devinit.py')); vd = _u.module_from_spec(_s); _s.loader.exec_module(vd)

def volt_table(rom):
    if 'P' not in rom.ent: return None
    pv, pl, po = rom.ent['P']; po = rom.A(po)
    off = rom.r32(po + 0x0c) if pv == 2 else (rom.r32(po + 0x10) if pv == 1 else 0)
    if not off: return None
    v = rom.A(off); ver = rom.r8(v)
    t = dict(ver=ver, off=off)
    if ver == 0x12: hdr, cnt, ln = 5, rom.r8(v + 2), rom.r8(v + 1)
    elif ver == 0x20: hdr, cnt, ln = rom.r8(v + 1), rom.r8(v + 2), rom.r8(v + 3)
    elif ver in (0x30, 0x40, 0x50): hdr, cnt, ln = rom.r8(v + 1), rom.r8(v + 3), rom.r8(v + 2)
    else: return t
    t.update(hdr=hdr, cnt=cnt, len=ln)
    if ver == 0x40:   # таблица «по диапазону»: напряжение = base + step·VID (step знаковый), не выше max; записи таблицы не используются
        step = struct.unpack_from('<h', rom.b, v + 8)[0]
        t.update(base=rom.r32(v + 4), step=step, vidmask=rom.r8(v + 0xb), max=rom.r32(v + 0xe), raw_hdr=rom.b[v:v + hdr].hex())
        t['vids'] = {vid: min(t['base'] + step * vid, t['max']) if step < 0 else min(t['base'] + step * vid, t['max']) for vid in range(t['vidmask'] + 1)}
    ents = []
    for i in range(cnt):
        e = v + hdr + i * ln
        if ver in (0x40, 0x50):
            w = rom.r32(e); ents.append(dict(uv=w & 0x1fffff, vid=(w >> 23) & 0xff, raw=rom.b[e:e + ln].hex()))
        elif ver == 0x30: ents.append(dict(uv=rom.r8(e) * 10000, vid=rom.r8(e + 1) >> 2))
        else: ents.append(dict(uv=rom.r8(e) * 10000, vid=rom.r8(e + 1)))
    t['entries'] = ents
    return t

def vmap_table(rom):
    """карта напряжений (BIT P v2 → +0x20; nouveau vmap.c): индекс из записи уровня → диапазон мкВ (min, max) и коэффициенты"""
    if 'P' not in rom.ent: return None
    pv, pl, po = rom.ent['P']
    if pv != 2 or pl < 0x24: return None
    off = rom.r32(rom.A(po) + 0x20)
    if not off: return None
    v = rom.A(off); ver = rom.r8(v)
    if ver not in (0x10, 0x20): return dict(ver=ver)
    hdr, cnt, ln = rom.r8(v + 1), rom.r8(v + 3), rom.r8(v + 2)
    ents = []
    for i in range(cnt):
        e = v + hdr + i * ln
        if ver == 0x10: ents.append(dict(min=rom.r32(e), max=rom.r32(e + 4), arg=[rom.r32(e + 8), rom.r32(e + 12), rom.r32(e + 16)]))
        else: ents.append(dict(mode=rom.r8(e), link=rom.r8(e + 1), min=rom.r32(e + 2), max=rom.r32(e + 6), arg=[rom.r32(e + 10 + 4 * k) for k in range(6)]))
    return dict(ver=ver, off=off, hdr=hdr, cnt=cnt, len=ln, entries=ents)

def perf_volt_index(rom):
    """индекс напряжения (байт 2 записи) по уровням из таблицы BIT P 0x40"""
    if 'P' not in rom.ent: return {}
    pv, pl, po = rom.ent['P']; perf = rom.A(rom.r32(rom.A(po) + 0))
    ver = rom.r8(perf)
    if ver != 0x40: return {}
    hdr, ln, cnt, snr, ssz = rom.r8(perf + 1), rom.r8(perf + 2), rom.r8(perf + 3), rom.r8(perf + 4), rom.r8(perf + 5)
    out = {}
    for i in range(cnt):
        e = perf + hdr + i * (ln + snr * ssz)
        lid = rom.r8(e)
        if lid == 0xff: continue
        out[f'{lid:02x}'] = rom.r8(e + 2)
    return out

def describe(path):
    rom = vd.Rom(open(path, 'rb').read())
    t = volt_table(rom); pvi = perf_volt_index(rom); vm = vmap_table(rom)
    return rom, t, pvi, vm

def main():
    ap = argparse.ArgumentParser(); ap.add_argument('--text'); ap.add_argument('--corpus'); ap.add_argument('--pci')
    a = ap.parse_args()
    if a.text:
        rom, t, pvi, vm = describe(a.text)
        print(f"{os.path.basename(a.text)} pci {rom.ven:04x}:{rom.dev:04x}: таблица напряжений ver {t and t.get('ver') and hex(t['ver'])} @ {t and t.get('off') and hex(t['off'])}")
        if t and t.get('ver') == 0x40:
            print(f"  base {t['base']} мкВ, step {t['step']} мкВ/VID, vidmask {t['vidmask']:#x}, max {t['max']} мкВ → VID 0..{t['vidmask']}: {t['vids'][0]}…{t['vids'][t['vidmask']]} мкВ")
        if vm and 'entries' in vm:
            print(f"  карта напряжений ver {vm['ver']:#x}, записей {vm['cnt']}: " + '; '.join(f"{i}: {e['min']}–{e['max']} мкВ arg {e['arg'][:3]}" for i, e in enumerate(vm['entries'])))
        print('  индекс карты по уровням:', pvi, '→', {k: (f"{vm['entries'][v]['min']}–{vm['entries'][v]['max']}" if vm and 'entries' in vm and v < len(vm['entries']) else '?') for k, v in pvi.items()})
        return
    if a.corpus:
        vers = collections.Counter(); hdrs = collections.Counter(); lv = collections.defaultdict(collections.Counter); vmaps = collections.Counter(); vmver = collections.Counter()
        n = 0
        for f in sorted(glob.glob(os.path.join(a.corpus, '*.rom'))):
            rom, t, pvi, vm = describe(f)
            if a.pci and rom.ven is not None and f'{rom.ven:04x}:{rom.dev:04x}' != a.pci: continue
            n += 1
            if not t or 'ver' not in t: vers['нет'] += 1; continue
            vers[hex(t['ver'])] += 1
            if t['ver'] == 0x40: hdrs[(t['base'], t['step'], t['vidmask'], t['max'])] += 1
            if vm and 'entries' in vm:
                vmver[(vm['ver'], vm['cnt'])] += 1
                vmaps[tuple((e['min'], e['max']) for e in vm['entries'])] += 1
                for k, v in pvi.items():
                    lv[k][(vm['entries'][v]['min'], vm['entries'][v]['max']) if v < len(vm['entries']) else '?'] += 1
        print(f'образов: {n}; версии таблицы напряжений: {dict(vers)}; карта напряжений (версия, записей): {dict(vmver)}')
        print('заголовки 0x40 (base, step, vidmask, max) × плат:', dict(hdrs))
        print('карты напряжений (min–max мкВ по записям) × плат:'); [print('  ', k, '×', v) for k, v in vmaps.most_common(8)]
        for k in sorted(lv): print(f'уровень {k}: ' + ', '.join(f'{uv}×{c}' for uv, c in lv[k].most_common(6)))

if __name__ == '__main__':
    main()
