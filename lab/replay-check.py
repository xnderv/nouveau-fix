#!/usr/bin/env python3
# Offline check of the recorded memory scripts kept in the lab driver (fb/ramgf100.c), no hardware needed.
#
#   1. Every script array (lab_*_scr*) is run through a port of the driver's interpreter in its "check only" mode
#      (lab_interp with build=false): the script must parse, use only operations the interpreter knows, release the
#      video memory stop it takes, and fit into the PMU script memory (the driver refuses a step above 480 memx words).
#      The word count is computed exactly as the driver computes it (lab_est_cmd), so it can be compared with the
#      "~N слов" figure of a kernel log.
#   2. With a recording (memscr.json from lab/trace-memscr.py, memhost.json from lab/trace-memhost.py) and a list
#      ARRAY=script[,script...] / ARRAY=pre:N / ARRAY=post:N: the arrays in the driver must equal the recording word
#      for word.
#
#   python3 -I lab/replay-check.py [ramgf100.c or 0002 patch]
#   python3 -I lab/replay-check.py SRC --rec memscr.json memhost.json lab_gf116_scrB=2,4 lab_gf116_preB=pre:2 ...
import json, os, re, sys

LIMIT = 480


def arrays(path):
    src = open(path, errors='replace').read()
    if src.startswith('--- ') or '\n+++ b/' in src:            # a patch: keep the added lines only
        src = '\n'.join(l[1:] for l in src.split('\n') if l.startswith('+') and not l.startswith('+++'))
    out = {}
    for m in re.finditer(r'static const u32 (lab_\w+)\[\] = \{(.*?)\};', src, re.S):
        body = re.sub(r'/\*.*?\*/', '', m.group(2), flags=re.S)
        out[m.group(1)] = [int(x, 16) for x in re.findall(r'0x[0-9a-fA-F]+', body)]
    return out


def interp(w, op34=1, syncwait=1, unit=250):
    """Port of lab_interp(build=false). Returns (error or None, stats)."""
    est = {'m': 0, 'sz': 0, 'total': 0}
    st = dict(wr=0, wait=0, delay=0, sync=0, sync_ns=0, skip=0, frame=0)

    def cmd(m, size):
        if est['sz'] + size >= 64 or (est['m'] and est['m'] != m):
            if est['m']:
                est['total'] += 1 + est['sz']
            est['m'] = 0
            est['sz'] = 0
        est['sz'] += size
        est['m'] = m

    i, blocked = 0, False
    while i < len(w):
        h = w[i]
        n, op = h >> 16, h & 0xffff
        a = w[i + 1:i + n]
        if n == 0 or i + n > len(w):
            return f'parse failure at word {i} ({h:08x})', st
        if op == 0x21:
            for _ in range((n - 1) // 2):
                cmd(3, 2)
                st['wr'] += 1
        elif op in (0x2e, 0x13):
            cmd(5, 1)
            st['delay'] += 1
        elif op in (0x00, 0x01):
            pass
        elif op == 0x15:
            cmd(4, 4)
            st['wait'] += 1
        elif op == 0x14:
            if a[0] == 0:
                cmd(6, 1)
                est['total'] += 1 + est['sz']
                est['m'] = 0
                est['sz'] = 0
                st['frame'] += 1
        elif op == 0x20:
            if a[0] == 1 and not blocked:
                cmd(1, 0)
                blocked = True
            elif a[0] == 0 and blocked:
                cmd(2, 0)
                blocked = False
        elif op == 0x16:
            break
        elif op == 0x34:
            if op34 and a[0] == 0x0a:
                cmd(4, 4)
                st['wait'] += 1
            else:
                st['skip'] += 1
        elif op == 0x3a:
            if syncwait and a[0] and unit:
                cmd(5, 1)
                st['sync'] += 1
                st['sync_ns'] += a[0] * unit
            else:
                st['skip'] += 1
        elif op == 0x39:
            if syncwait:
                unit = a[0]
            else:
                st['skip'] += 1
        else:
            return f'unknown operation {op:04x} at word {i}', st
        i += n
    if blocked:
        return 'the script does not release the video memory stop', st
    if est['m']:
        est['total'] += 1 + est['sz']
    st['words'] = est['total']
    return None, st


def main():
    args = sys.argv[1:]
    rec = None
    if '--rec' in args:
        k = args.index('--rec')
        rec, args = args[k + 1:], args[:k]
    src = args[0] if args else os.path.expanduser('~/Home/nouveau-build/lab-vbios-src/nouveau/nvkm/subdev/fb/ramgf100.c')
    A = arrays(src)
    bad = 0
    scr = sorted(n for n in A if re.search(r'_scr', n))
    print(f'{len(A)} arrays, {len(scr)} scripts')
    for n in scr:
        err, st = interp(A[n])
        if err or st['words'] > LIMIT:
            bad += 1
        print(f"  {n:24} {len(A[n]):4} words: " + (f'FAIL: {err}' if err else
              f"{st['wr']:3} writes, {st['wait']} waits, {st['delay']:2} delays, {st['sync']} strobe waits ({st['sync_ns']} ns), "
              f"{st['frame']} frame wait, skipped {st['skip']}; ~{st['words']} memx words" + ('' if st['words'] <= LIMIT else f' - ABOVE {LIMIT}')))
    if rec:
        S = json.load(open(rec[0]))
        H = {h['i']: h for h in json.load(open(rec[1]))}
        flat = lambda p: [x for q in p for x in q]
        for spec in rec[2:]:
            name, what = spec.split('=')
            if name not in A:
                print(f'  {name}: NOT in the source')
                bad += 1
                continue
            if what.startswith(('pre:', 'post:')):
                kind, ids = what.split(':')
                refs = [(f'{kind} of script {j}', flat(H[int(j)][kind])) for j in ids.split(',')]
            else:
                refs = [(f'script {j}', S[int(j)]['words']) for j in what.split(',')]
            for label, ref in refs:
                ok = A[name] == ref
                bad += not ok
                print(f'  {name:24} = recording, {label}: ' + ('yes' if ok else 'NO'))
    print('RESULT: ' + ('all checks passed' if not bad else f'{bad} FAILED'))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
