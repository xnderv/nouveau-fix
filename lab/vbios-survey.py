#!/usr/bin/env python3
# Сводка по пачке образов VBIOS (только чтение файлов): для каждого образа — устройство PCI, версия, таблица уровней
# (BIT 'P' perf 0x40: частота узла, биты 14–15 частоты, байты записи уровня), rammap/ramcfg и тайминги (v0x10).
# Вход: каталоги и/или архивы .tar (как их собирает браузер: index.csv + *.rom). Выход: JSON на каждый образ и CSV-сводка.
#   python3 -I lab/vbios-survey.py ВЫХОД_КАТАЛОГ ВХОД [ВХОД ...]
#   python3 -I lab/vbios-survey.py --text ОБРАЗ.rom   — сводка одного образа текстом (её печатает tools/card-report.sh)
import sys, os, re, struct, json, tarfile, csv, io, hashlib

DOM = {0: 'hubk06', 1: 'hubk01', 2: 'copy', 3: 'gpc', 4: 'rop', 5: 'mem', 6: 'vdec', 7: 'host', 10: 'pmu', 11: 'hubk07'}


def legacy_image(b):
    """Первый образ x86 (55 AA, PCIR код 0) — именно в нём BIT."""
    off = 0
    while off + 0x1a < len(b) and b[off] == 0x55 and b[off + 1] == 0xaa:
        p = off + struct.unpack_from('<H', b, off + 0x18)[0]
        if b[p:p + 4] != b'PCIR':
            break
        ven, dev = struct.unpack_from('<HH', b, p + 4)
        ln = struct.unpack_from('<H', b, p + 0x10)[0] * 512
        code, last = b[p + 0x14], b[p + 0x15] & 0x80
        if code == 0:
            return off, ven, dev
        if last or not ln:
            break
        off += ln
    return 0, None, None


def parse(b):
    r = {}
    base, ven, dev = legacy_image(b)
    r['pci'] = f'{ven:04x}:{dev:04x}' if ven is not None else None
    bit = b.find(b'\xff\xb8BIT', base)
    if bit < 0:
        r['err'] = 'нет BIT'
        return r
    r8 = lambda o: b[o]
    r16 = lambda o: struct.unpack_from('<H', b, o)[0]
    r32 = lambda o: struct.unpack_from('<I', b, o)[0]
    # подсистема (производитель платы) — по смещению 0x54 образа; строки — артикул, номер платы; признак правки
    sv, sd = r16(base + 0x54), r16(base + 0x56)
    r['subsys'] = f'{sv:04x}:{sd:04x}'
    strs = [s.decode() for s in re.findall(rb'[\x20-\x7e]{6,}', b[base:base + 0x400])]
    r['strings'] = [s.strip() for s in strs if not s.startswith(('IBM VGA', 'VIDEO', 'Chip Rev', 'DPMI'))][:6]
    low = b.lower()
    r['modified'] = [w for w in ('nibitor', 'modified', 'kepler bios tweaker', 'mod by', 'unlocked', 'oc bios', 'flashed') if w.encode() in low]
    n, esz = r8(bit + 10), r8(bit + 9)
    ent = {}
    for i in range(n):
        e = bit + 12 + i * esz
        ent[chr(r8(e))] = (r8(e + 1), r16(e + 2), r16(e + 4))
    # смещения в BIT отсчитываются от начала образа (nouveau читает так же, образ в памяти с 0)
    A = lambda o: base + o
    if 'i' in ent:
        o = A(ent['i'][2])
        v = r32(o)
        r['version'] = f'{v >> 24 & 0xff:02x}.{v >> 16 & 0xff:02x}.{v >> 8 & 0xff:02x}.{v & 0xff:02x}.{r8(o + 4):02x}'
    if 'P' not in ent:
        r['err'] = 'нет BIT P'
        return r
    pv, pl, po = ent['P']
    po = A(po)
    if pv != 2:
        r['err'] = f'BIT P версии {pv}'
        return r
    ptr = lambda k: A(r32(po + 4 * k)) if r32(po + 4 * k) else 0
    perf, rammap, timing = ptr(0), ptr(1), ptr(2)
    # таблица уровней
    if perf and r8(perf) == 0x40:
        hdr, ln, ssz, snr, cnt = r8(perf + 1), r8(perf + 2), r8(perf + 3), r8(perf + 4), r8(perf + 5)
        lv = []
        for i in range(cnt):
            e = perf + hdr + i * (ln + snr * ssz)
            if r8(e) == 0xff:
                continue
            d = {'id': f'{r8(e):02x}', 'raw': b[e:e + ln].hex(), 'dom': {}}
            for s in range(snr):
                w = r16(e + ln + s * ssz)
                if w:
                    d['dom'][DOM.get(s, str(s))] = [w & 0x3fff, w >> 14]
            lv.append(d)
        r['perf'] = {'ver': '40', 'len': ln, 'snr': snr, 'ssz': ssz, 'levels': lv}
    elif perf:
        r['perf'] = {'ver': f'{r8(perf):02x}'}
        r['err'] = (f'таблица уровней по указателю {perf:#x} не найдена (версия {r8(perf):#04x}): похоже на сырой образ ПЗУ, '
                    f'а не рабочую копию из nouveau (debugfs) / perf table not found: looks like a raw ROM image')
    # rammap + ramcfg
    if rammap and r8(rammap) in (0x10, 0x11):
        ver, hdr, cnt, ln, snr, ssz = r8(rammap), r8(rammap + 1), r8(rammap + 5), r8(rammap + 2), r8(rammap + 4), r8(rammap + 3)
        ents = []
        for i in range(cnt):
            e = rammap + hdr + i * (ln + snr * ssz)
            ents.append({'mhz': [r16(e), r16(e + 2)], 'raw': b[e:e + ln].hex(),
                         'cfg': [b[e + ln + s * ssz:e + ln + (s + 1) * ssz].hex() for s in range(snr)]})
        r['rammap'] = {'ver': f'{ver:02x}', 'len': ln, 'snr': snr, 'ssz': ssz, 'entries': ents}
    # тепловая таблица (BIT P v2 + 0x10, как nouveau bios/therm.c): пороги секции 0 и обороты вентилятора
    therm = ptr(4)
    if therm:
        th = {}
        hdr, ln, cnt = r8(therm + 1), r8(therm + 2), r8(therm + 3)
        sect = 0
        for i in range(cnt):
            e = therm + hdr + i * ln
            k, v = r8(e), struct.unpack_from('<h', b, e + 1)[0]
            if k == 0x00:
                sect = v
            names = {0x04: 'crit', 0x07: 'down_clock', 0x08: 'fan_boost', 0x32: 'shutdown'}
            if k in names and sect == 0:
                th[names[k]] = (v & 0xff0) >> 4
            if k == 0x22:
                th['fan_min'], th['fan_max'] = v & 0xff, (v >> 8) & 0xff
            if k == 0x24:
                th['fan_trips'] = th.get('fan_trips', 0) + 1
        th['ver'] = f'{r8(therm):02x}'
        r['therm'] = th
    if timing and r8(timing) == 0x10:
        hdr, cnt, ln = r8(timing + 1), r8(timing + 2), r8(timing + 3)
        r['timing'] = {'ver': '10', 'len': ln, 'entries': [b[timing + hdr + i * ln:timing + hdr + (i + 1) * ln].hex() for i in range(cnt)]}
    elif timing:
        r['timing'] = {'ver': f'{r8(timing):02x}'}
    return r


def inputs(paths):
    for p in paths:
        if os.path.isdir(p):
            for root, _, fs in os.walk(p):
                for f in sorted(fs):
                    fp = os.path.join(root, f)
                    if f.lower().endswith(('.rom', '.bin')):
                        yield f, open(fp, 'rb').read(), {}
                    elif f.endswith('.tar'):
                        yield from inputs([fp])
        elif p.endswith('.tar'):
            with tarfile.open(p) as t:
                meta = {}
                if 'index.csv' in t.getnames():
                    for row in csv.DictReader(io.TextIOWrapper(t.extractfile('index.csv'), 'utf-8')):
                        meta[row['file']] = row
                for m in t.getmembers():
                    if m.name.lower().endswith('.rom'):
                        yield m.name, t.extractfile(m).read(), meta.get(m.name, {})
        else:
            yield os.path.basename(p), open(p, 'rb').read(), {}


def text(name, data):
    """Человекочитаемая сводка одного образа (для tools/card-report.sh): plain ASCII + English, its readers are testers."""
    r = parse(data)
    out = [f'file:      {name} ({len(data)} bytes, sha256 {hashlib.sha256(data).hexdigest()[:16]}…)',
           f'device:    {r.get("pci")}   subsystem: {r.get("subsys")}   VBIOS: {r.get("version")}',
           f'strings:   {" | ".join(r.get("strings", []))}',
           f'modified:  {", ".join(r["modified"]) if r.get("modified") else "no marks found"}']
    if r.get('err'):
        out.append(f'error:     {r["err"]}')
    perf = r.get('perf', {})
    if perf.get('levels'):
        doms = []
        for l in perf['levels']:
            for k in l['dom']:
                if k not in doms:
                    doms.append(k)
        out.append(f'\nperformance levels (table {perf["ver"]}; MHz/flag, flag = bits 14-15):')
        out.append('  lvl  b1 b2 b0b b0c  ' + ' '.join(f'{d:>10s}' for d in doms))
        for l in perf['levels']:
            raw = bytes.fromhex(l['raw'])
            cells = ' '.join(f'{(str(l["dom"][d][0]) + "/" + str(l["dom"][d][1])) if d in l["dom"] else "-":>10s}' for d in doms)
            out.append(f'  {l["id"]}   {raw[1]:02x} {raw[2]:02x} {raw[0x0b]:02x}  {raw[0x0c]:02x}   {cells}')
    rm = r.get('rammap')
    if rm:
        out.append(f'\nmemory map (rammap {rm["ver"]}, {rm["snr"]} straps):')
        for e in rm['entries']:
            used = [i for i, c in enumerate(e['cfg']) if bytes.fromhex(c)[1:2] != b'\xff' and any(bytes.fromhex(c))]
            out.append(f'  {e["mhz"][0]:4d}-{e["mhz"][1]:4d} MHz  entry {e["raw"]}  straps with data: {used}')
            for i in used:
                out.append(f'      ramcfg[{i}] {e["cfg"][i]}')
    tm = r.get('timing')
    if tm and tm.get('entries'):
        out.append(f'\nmemory timings (table {tm["ver"]}):')
        for i, e in enumerate(tm['entries']):
            if any(bytes.fromhex(e)):
                out.append(f'  {i:2d}: {e}')
    if r.get('therm'):
        out.append(f'\nthermal table: {r["therm"]}')
    return '\n'.join(out) + '\n'


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == '--text':
        for p in sys.argv[2:]:
            sys.stdout.write(text(os.path.basename(p), open(p, 'rb').read()))
        return
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    allr, seen = [], set()
    for name, data, meta in inputs(sys.argv[2:]):
        h = hashlib.sha256(data).hexdigest()
        if h in seen:
            continue
        seen.add(h)
        r = parse(data)
        r.update({'file': name, 'sha256': h, 'size': len(data), 'meta': {k: meta.get(k) for k in ('manufacturer', 'model', 'version', 'clocks', 'memory')} if meta else None})
        allr.append(r)
    json.dump(allr, open(os.path.join(out, 'survey.json'), 'w'), ensure_ascii=False)
    print(f'образов (без повторов): {len(allr)}; с ошибкой разбора: {sum(1 for r in allr if r.get("err"))}')


if __name__ == '__main__':
    main()
