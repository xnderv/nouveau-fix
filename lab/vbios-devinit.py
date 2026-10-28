#!/usr/bin/env python3
# Скрипты инициализации VBIOS (devinit, BIT 'I'): статический проход по опкодам и список записей регистров.
# Только чтение файлов образов. Раскладка опкодов — по открытому коду nouveau (nvkm/subdev/bios/init.c), класс Г.
# Проход линейный: условия не вычисляются (все ветви перечисляются), jump/sub/sub_direct раскрываются, повторы не
# размножаются; значения, зависящие от ремешка памяти (ram_restrict), даются по всем ремешкам.
#   python3 -I lab/vbios-devinit.py --text ОБРАЗ.rom [--range 0x020000-0x020200 ...]   — записи одного образа
#   python3 -I lab/vbios-devinit.py --corpus КАТАЛОГ [--range ...] [--pci 10de:1200]    — регистр → значения по корпусу
import sys, os, re, glob, json, struct, argparse, collections

def legacy_image(b):
    off = 0
    while off + 0x1a < len(b) and b[off] == 0x55 and b[off + 1] == 0xaa:
        p = off + struct.unpack_from('<H', b, off + 0x18)[0]
        if b[p:p + 4] != b'PCIR': break
        ven, dev = struct.unpack_from('<HH', b, p + 4)
        ln = struct.unpack_from('<H', b, p + 0x10)[0] * 512
        code, last = b[p + 0x14], b[p + 0x15] & 0x80
        if code == 0: return off, ven, dev
        if last or not ln: break
        off += ln
    return 0, None, None

class Rom:
    def __init__(self, b):
        self.b = b
        self.base, self.ven, self.dev = legacy_image(b)
        self.bit = b.find(b'\xff\xb8BIT', self.base)
        self.ent = {}
        if self.bit >= 0:
            n, esz = b[self.bit + 10], b[self.bit + 9]
            for i in range(n):
                e = self.bit + 12 + i * esz
                self.ent[chr(b[e])] = (b[e + 1], self.r16(e + 2), self.r16(e + 4))   # версия, длина, смещение
    def r8(self, o): return self.b[o]
    def r16(self, o): return struct.unpack_from('<H', self.b, o)[0]
    def r32(self, o): return struct.unpack_from('<I', self.b, o)[0]
    def A(self, o): return self.base + o
    def ramcfg_count(self):
        if 'M' in self.ent:
            ver, ln, off = self.ent['M']
            if ver == 1 and ln >= 5: return self.r8(self.A(off) + 2)
            if ver == 2 and ln >= 3: return self.r8(self.A(off) + 0)
        return 0
    def init_tables(self):
        if 'I' not in self.ent: return None
        ver, ln, off = self.ent['I']; o = self.A(off)
        t = {}
        for name, k in (('script', 0), ('macro_index', 2), ('macro', 4), ('condition', 6), ('io_condition', 8), ('io_flag_condition', 10), ('function', 12), ('xlat', 16)):
            t[name] = self.r16(o + k) if ln >= k + 2 else 0
        return t
    def scripts(self):
        t = self.init_tables()
        if not t or not t['script']: return []
        out, i = [], 0
        while True:
            p = self.r16(self.A(t['script']) + i * 2)
            if not p: break
            out.append(p); i += 1
            if i > 64: break
        return out

# длины опкодов фиксированной длины (без записи регистров или с ней); переменные разбираются отдельно
FIXED = {0x33: 2, 0x36: 1, 0x37: 11, 0x38: 1, 0x39: 2, 0x3a: 3, 0x3b: 2, 0x3c: 2, 0x47: 9, 0x48: 9, 0x4b: 9,
         0x4f: 5, 0x51: 5, 0x52: 4, 0x53: 3, 0x56: 3, 0x57: 3, 0x59: 7, 0x5a: 7, 0x5b: 3, 0x5c: 3, 0x5e: 6, 0x5f: 22,
         0x62: 5, 0x63: 1, 0x65: 13, 0x66: 1, 0x67: 1, 0x68: 1, 0x69: 5, 0x6b: 2, 0x6d: 3, 0x6e: 13, 0x6f: 2, 0x71: 1,
         0x72: 1, 0x73: 9, 0x74: 3, 0x75: 2, 0x76: 2, 0x77: 7, 0x78: 6, 0x79: 7, 0x7a: 9, 0x8c: 1, 0x8d: 1, 0x8e: 1,
         0x90: 9, 0x92: 1, 0x96: 17, 0x97: 13, 0x9a: 7, 0xa9: 2, 0xaa: 1}
NAMES = {0x32: 'io_restrict_prog', 0x33: 'repeat', 0x34: 'io_restrict_pll', 0x36: 'end_repeat', 0x37: 'copy', 0x38: 'not',
         0x39: 'io_flag_condition', 0x3a: 'generic_condition', 0x3b: 'io_mask_or', 0x3c: 'io_or', 0x47: 'andn_reg',
         0x48: 'or_reg', 0x49: 'idx_addr_latched', 0x4a: 'io_restrict_pll2', 0x4b: 'pll2', 0x4c: 'i2c_byte',
         0x4d: 'zm_i2c_byte', 0x4e: 'zm_i2c', 0x4f: 'tmds', 0x50: 'zm_tmds_group', 0x51: 'cr_idx_adr_latch', 0x52: 'cr',
         0x53: 'zm_cr', 0x54: 'zm_cr_group', 0x56: 'condition_time', 0x57: 'ltime', 0x58: 'zm_reg_sequence',
         0x59: 'pll_indirect', 0x5a: 'zm_reg_indirect', 0x5b: 'sub_direct', 0x5c: 'jump', 0x5e: 'i2c_if',
         0x5f: 'copy_nv_reg', 0x62: 'zm_index_io', 0x63: 'compute_mem', 0x65: 'reset', 0x66: 'configure_mem',
         0x67: 'configure_clk', 0x68: 'configure_preinit', 0x69: 'io', 0x6b: 'sub', 0x6d: 'ram_condition',
         0x6e: 'nv_reg', 0x6f: 'macro', 0x71: 'done', 0x72: 'resume', 0x73: 'strap_condition', 0x74: 'time',
         0x75: 'condition', 0x76: 'io_condition', 0x77: 'zm_reg16', 0x78: 'index_io', 0x79: 'pll', 0x7a: 'zm_reg',
         0x87: 'ram_restrict_pll', 0x8c: 'reset_begun', 0x8d: 'reset_end', 0x8e: 'gpio', 0x8f: 'ram_restrict_zm_reg_group',
         0x90: 'copy_zm_reg', 0x91: 'zm_reg_group', 0x92: 'reserved', 0x96: 'xlat', 0x97: 'zm_mask_add', 0x98: 'auxch',
         0x99: 'zm_auxch', 0x9a: 'i2c_long_if', 0xa9: 'gpio_ne', 0xaa: 'reserved'}

OPSTAT = collections.Counter()   # статистика опкодов по всем проходам (сверка со спецификацией NVIDIA)

def walk(rom, start, writes, visited, depth=0, script=0, cond=0):
    """Линейный проход одного скрипта от start (смещение в образе от начала файла уже с base)."""
    o = start
    r8, r16, r32 = rom.r8, rom.r16, rom.r32
    rc = rom.ramcfg_count()
    t = rom.init_tables() or {}
    W = lambda **kw: writes.append(dict(script=script, off=o, cond=cond, **kw))
    steps = 0
    while o < len(rom.b) and steps < 20000:
        steps += 1
        if o in visited: return 'loop'
        visited.add(o)
        op = r8(o)
        OPSTAT[op] += 1
        if op == 0x71: return 'done'
        elif op == 0x7a: W(op='zm_reg', reg=r32(o + 1), val=r32(o + 5)); o += 9
        elif op == 0x6e: W(op='nv_reg', reg=r32(o + 1), mask=r32(o + 5), val=r32(o + 9)); o += 13
        elif op == 0x91:
            reg, n = r32(o + 1), r8(o + 5); o += 6
            for i in range(n): W(op='zm_reg_group', reg=reg, val=r32(o), idx=i); o += 4
        elif op == 0x58:
            reg, n = r32(o + 1), r8(o + 5); o += 6
            for i in range(n): W(op='zm_reg_sequence', reg=reg + 4 * i, val=r32(o)); o += 4
        elif op == 0x8f:
            reg, incr, num = r32(o + 1), r8(o + 5), r8(o + 6); o += 7
            for i in range(num):
                for j in range(rc): W(op='ram_restrict_zm_reg_group', reg=reg + incr * i, val=r32(o), strap=j); o += 4
        elif op == 0x87:
            typ = r8(o + 1); o += 2
            for j in range(rc): W(op='ram_restrict_pll', reg=typ, val=r32(o), strap=j); o += 4
        elif op == 0x32:
            n, reg = r8(o + 6), r32(o + 7); port, idx, mask, shift = r16(o + 1), r8(o + 3), r8(o + 4), r8(o + 5); o += 11
            for i in range(n): W(op='io_restrict_prog', reg=reg, val=r32(o), sel=i, port=port, index=idx, mask=mask, shift=shift); o += 4
        elif op == 0x34:
            n, reg = r8(o + 7), r32(o + 8); o += 12
            for i in range(n): W(op='io_restrict_pll', reg=reg, val=r16(o) * 10, sel=i); o += 2
        elif op == 0x4a:
            n, reg = r8(o + 6), r32(o + 7); o += 11
            for i in range(n): W(op='io_restrict_pll2', reg=reg, val=r32(o), sel=i); o += 4
        elif op == 0x79: W(op='pll', reg=r32(o + 1), val=r16(o + 5) * 10); o += 7
        elif op == 0x4b: W(op='pll2', reg=r32(o + 1), val=r32(o + 5)); o += 9
        elif op == 0x5f: W(op='copy_nv_reg', reg=r32(o + 14), mask=r32(o + 18), src=r32(o + 1), shift=r8(o + 5), smask=r32(o + 6), sxor=r32(o + 10)); o += 22
        elif op == 0x97: W(op='zm_mask_add', reg=r32(o + 1), mask=r32(o + 5), add=r32(o + 9)); o += 13
        elif op == 0x47: W(op='andn_reg', reg=r32(o + 1), mask=r32(o + 5)); o += 9
        elif op == 0x48: W(op='or_reg', reg=r32(o + 1), mask=r32(o + 5)); o += 9
        elif op == 0x5a: W(op='zm_reg_indirect', reg=r32(o + 1), ptr=r16(o + 5), val=r32(rom.A(r16(o + 5)))); o += 7
        elif op == 0x77: W(op='zm_reg16', reg=r32(o + 1), val=r16(o + 5)); o += 7
        elif op == 0x96: W(op='xlat', reg=r32(o + 8), mask=r32(o + 12), src=r32(o + 1)); o += 17
        elif op == 0x90: W(op='copy_zm_reg', reg=r32(o + 5), src=r32(o + 1)); o += 9
        elif op == 0x49:
            creg, dreg, mask, data, n = r32(o + 1), r32(o + 5), r32(o + 9), r32(o + 13), r8(o + 17); o += 18
            for i in range(n): W(op='idx_addr_latched', reg=dreg, val=r8(o + 1), creg=creg, iaddr=r8(o)); o += 2
        elif op == 0x6f:
            m = r8(o + 1); mt = t.get('macro')
            if mt: W(op='macro', reg=r32(rom.A(mt) + m * 8), val=r32(rom.A(mt) + m * 8 + 4), macro=m)
            o += 2
        elif op == 0x65: W(op='reset', reg=r32(o + 1), val=r32(o + 5), val2=r32(o + 9)); o += 13
        elif op == 0x5c:   # jump: продолжаем с цели
            o = rom.A(r16(o + 1)); continue
        elif op == 0x5b:   # sub_direct: подпрограмма, потом дальше
            tgt = rom.A(r16(o + 1)); o += 3
            walk(rom, tgt, writes, visited, depth + 1, script, cond)
        elif op == 0x6b:   # sub: по таблице функций
            idx = r8(o + 1); ft = t.get('function'); o += 2
            if ft:
                tgt = r16(rom.A(ft) + idx * 2)
                if tgt: walk(rom, rom.A(tgt), writes, visited, depth + 1, script, cond)
        elif op in (0x75, 0x76, 0x39, 0x3a, 0x6d, 0x73, 0x56): cond += 1; o += FIXED.get(op, 2) if op != 0x3a else 3
        elif op in (0x54,): n = r8(o + 1); o += 2 + 2 * n
        elif op == 0x50: n = r8(o + 2); o += 3 + 2 * n
        elif op == 0x4c: n = r8(o + 3); o += 4 + 3 * n
        elif op == 0x4d: n = r8(o + 3); o += 4 + 2 * n
        elif op == 0x4e: n = r8(o + 3); o += 4 + n
        elif op == 0x51: n = r8(o + 4); o += 5 + n
        elif op == 0x98: n = r8(o + 5); o += 6 + 2 * n
        elif op == 0x99: n = r8(o + 5); o += 6 + n
        elif op in FIXED: o += FIXED[op]
        else:
            writes.append(dict(script=script, off=o, op='UNKNOWN', opcode=op)); return 'unknown 0x%02x' % op
    return 'end'

def parse_file(path):
    b = open(path, 'rb').read()
    rom = Rom(b)
    r = dict(file=os.path.basename(path), pci=f'{rom.ven:04x}:{rom.dev:04x}' if rom.ven is not None else None,
             ramcfg_count=rom.ramcfg_count(), scripts=[], writes=[], status=[])
    if rom.bit < 0: r['status'].append('нет BIT'); return r
    for i, s in enumerate(rom.scripts()):
        visited = set()
        st = walk(rom, rom.A(s), r['writes'], visited, 0, i)
        r['scripts'].append(dict(index=i, ptr=s, status=st))
    return r

def in_ranges(reg, ranges):
    return not ranges or any(a <= reg < z for a, z in ranges)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--text'); ap.add_argument('--corpus'); ap.add_argument('--range', action='append', default=[])
    ap.add_argument('--pci'); ap.add_argument('--json')
    a = ap.parse_args()
    ranges = []
    for s in a.range:
        x, y = s.split('-'); ranges.append((int(x, 16), int(y, 16)))
    if a.text:
        r = parse_file(a.text)
        print(f"{r['file']} pci {r['pci']} ramcfg {r['ramcfg_count']} скриптов {len(r['scripts'])}: " + ', '.join(f"#{s['index']}@{s['ptr']:04x} {s['status']}" for s in r['scripts']))
        for w in r['writes']:
            if w['op'] == 'UNKNOWN': print(f"  !! неизвестный опкод 0x{w['opcode']:02x} в скрипте {w['script']} @ {w['off']:05x}"); continue
            if not in_ranges(w['reg'], ranges): continue
            extra = {k: v for k, v in w.items() if k not in ('script', 'off', 'cond', 'op', 'reg', 'val', 'mask')}
            print(f"  s{w['script']} {w['off']:05x} c{w['cond']:<2} {w['op']:<24} {w['reg']:06x}" + (f" = {w['val']:08x}" if 'val' in w else '') + (f" mask {w['mask']:08x}" if 'mask' in w else '') + (f"  {extra}" if extra else ''))
        return
    if a.corpus:
        files = sorted(glob.glob(os.path.join(a.corpus, '*.rom')))
        per_reg = collections.defaultdict(lambda: collections.defaultdict(set))   # reg -> value-key -> set(files)
        n_ok = 0; statuses = collections.Counter()
        for f in files:
            r = parse_file(f)
            if a.pci and r['pci'] != a.pci: continue
            n_ok += 1
            for s in r['scripts']: statuses[s['status']] += 1
            for w in r['writes']:
                if w['op'] == 'UNKNOWN' or not in_ranges(w['reg'], ranges): continue
                key = w['op'] + ':' + (f"{w['val']:08x}" if 'val' in w else '') + (f"/m{w['mask']:08x}" if 'mask' in w else '') + (f"/s{w['strap']}" if 'strap' in w else '')
                per_reg[w['reg']][key].add(r['file'])
        print(f'образов: {n_ok}; статусы скриптов: {dict(statuses)}')
        for reg in sorted(per_reg):
            vals = per_reg[reg]
            items = sorted(vals.items(), key=lambda kv: -len(kv[1]))
            print(f"{reg:06x}: " + '; '.join(f"{k}×{len(v)}" for k, v in items[:6]) + (f" … ещё {len(items)-6}" if len(items) > 6 else ''))
        if a.json: json.dump({f'{k:06x}': {kk: sorted(vv) for kk, vv in v.items()} for k, v in per_reg.items()}, open(a.json, 'w'), ensure_ascii=False, indent=0)

if __name__ == '__main__':
    main()
