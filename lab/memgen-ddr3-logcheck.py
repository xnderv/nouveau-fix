#!/usr/bin/env python3
# Compare the DDR3 memory scripts the lab driver built on real hardware with NVIDIA's recorded scripts (26 Nov 2026).
# The driver prints each distinct built script once into the kernel log (lab_mem_gen_dump of them). This tool takes them
# out of the log and compares each with the recorded NVIDIA scripts in lab/memgen-ddr3-cases.txt (five GF108 DDR3
# boards): does it match one word for word, and if not, which one is nearest and which register writes differ.
# Read-only.
#   journalctl -k -b | python3 lab/memgen-ddr3-logcheck.py -        or        python3 lab/memgen-ddr3-logcheck.py LOGFILE
#   optional: --board LABEL (GT630M, Quadro600, GT630-ASUS, nvc1#2, nvc1#6): compare with that board's recordings only
# In the 0x132000 words bits 16-17 (PLL lock flags, set by the hardware) are not compared. A script that differs from a
# recording only by the frame wait and the display pause is reported as such: NVIDIA leaves them out when no display is
# active (at its driver start, on a GPU that drives no screen), the lab driver always has them at run time.
# Сверка скриптов памяти DDR3, собранных драйвером на железе, с записями NVIDIA; только чтение.
import sys, re, os, difflib

HERE = os.path.dirname(os.path.abspath(__file__))


def tokens(w):
    i, t = 0, []
    while i < len(w):
        h = w[i]; n, op = h >> 16, h & 0xffff
        if n == 0 or i + n > len(w): break
        a = w[i + 1:i + n]
        if op == 0x21: t += [('W', a[k], a[k + 1]) for k in range(0, len(a) - 1, 2)]
        else: t.append(('op', op, tuple(a)))
        i += n
    return t


def norm(t):
    if t[0] == 'W' and t[1] == 0x132000: return ('W', t[1], t[2] & ~0x00030000)
    return t


def nodisp(t):
    """the script without the frame wait and the display pause before the memory stop"""
    return [x for x in t if not (x[0] == 'op' and x[1] == 0x14) and x != ('W', 0x611200, 0x00003300)]


def show(t):
    if t[0] == 'W': return f'{t[1]:06x}={t[2]:08x}'
    return '[op %02x %s]' % (t[1], ' '.join(f'{x:x}' for x in t[2]))


def main():
    a = [x for x in sys.argv[1:]]
    board = None
    if '--board' in a: k = a.index('--board'); board = a[k + 1]; del a[k:k + 2]
    if not a: sys.exit('usage: memgen-ddr3-logcheck.py LOGFILE|- [--board LABEL]')
    rec = []; name = None
    for line in open(os.path.join(HERE, 'memgen-ddr3-cases.txt')):
        if line.startswith('case '): name = line.split()[1]
        elif line.startswith('xr '):
            p = line.split(); w = [int(x, 16) for x in p[2:]]
            if board is None or name.rsplit('#', 1)[0] == board: rec.append((name, [norm(t) for t in tokens(w)]))
    f = sys.stdin if a[0] == '-' else open(a[0], errors='replace')
    scripts = []; cur = None
    for line in f:
        m = re.search(r'LAB gen (built \S+): (\d+) host writes before the script, (\d+) script words', line)
        if m:
            cur = {'name': m.group(1), 'n': int(m.group(3)), 'w': []}; scripts.append(cur); continue
        m = re.search(r'LAB gen scr (\d+):((?: [0-9a-f]{8})+)', line)
        if m and cur is not None and int(m.group(1)) == len(cur['w']):
            cur['w'] += [int(x, 16) for x in m.group(2).split()]
    if not scripts: print('no built scripts in this log (no "LAB gen built ..." lines)'); return
    seen = {}
    for s in scripts:
        if len(s['w']) != s['n']:
            print(f"{s['name']}: the log has {len(s['w'])} of {s['n']} words - log truncated, skipped"); continue
        key = tuple(s['w'])
        if key in seen: seen[key] += 1; continue
        seen[key] = 1
        t = [norm(x) for x in tokens(s['w'])]
        same = [n for n, r in rec if r == t]
        if same:
            print(f"{s['name']}: {s['n']} words - MATCHES NVIDIA's recorded script {same[0]} word for word" + (f' (and {len(same) - 1} more)' if len(same) > 1 else '')); continue
        same = [n for n, r in rec if nodisp(r) == nodisp(t)]
        if same:
            print(f"{s['name']}: {s['n']} words - matches NVIDIA's recorded script {same[0]} word for word except the frame wait and "
                  f"the display pause (one of the two was made with no display active)"); continue
        A = [show(x) for x in t]; best = None
        for n, r in rec:
            B = [show(x) for x in r]; ratio = difflib.SequenceMatcher(None, A, B, autojunk=False).ratio()
            if best is None or ratio > best[0]: best = (ratio, n, B)
        if best is None: print(f"{s['name']}: {s['n']} words - no recordings to compare with"); continue
        print(f"{s['name']}: {s['n']} words - no exact match; nearest recorded script {best[1]} (similarity {best[0]:.3f}), differences:")
        for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, A, best[2], autojunk=False).get_opcodes():
            if tag != 'equal': print(f"     built:    {' '.join(A[i1:i2]) or '-'}\n     recorded: {' '.join(best[2][j1:j2]) or '-'}")
    print(f'distinct built scripts in the log: {len(seen)}')


main()
