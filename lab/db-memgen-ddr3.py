#!/usr/bin/env python3
# ПРОГОН ГЕНЕРАТОРА DDR3 (lab/memgen-ddr3.py) ПО ЗАПИСЯМ БАЗЫ (25.11, оформлен 26.11). Для каждой записи Fermi DDR3 с одним
# образом VBIOS и одним ремешком: распаковка записи во временный файл, выборка скриптов памяти, записей хоста вокруг них
# и состояния регистров перед каждым скриптом; затем сверка генератора (check, hostcheck). Промежуточные файлы кладутся
# в кеш (ОПИСЬ/ddr3gen), повторный прогон записи не распаковывает. Только чтение базы; письма (.eml) не читаются;
# участники обезличены (метки вида nvc1#2), пути базы не печатаются.
#   python3 -I lab/db-memgen-ddr3.py [МЕТКА ...] [--cases ФАЙЛ] [--lim N]
#       без меток — все записи Fermi DDR3 со скриптами; --cases — дописать блоки для стенда на C (memgen-ddr3-ctest.sh)
# Каталоги: ОПИСЬ = $MEMSURVEY или ~/Home/nouveau-archive/mem-survey; БАЗА = $TRACEDB или ~/Home/nouveau-archive/nouveau_vbios_trace
import json, os, sys, subprocess, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.environ.get('MEMSURVEY') or os.path.expanduser('~/Home/nouveau-archive/mem-survey')
DB = os.environ.get('TRACEDB') or os.path.expanduser('~/Home/nouveau-archive/nouveau_vbios_trace')
W = os.path.join(OUT, 'ddr3gen'); os.makedirs(W, exist_ok=True)
CHIP = {'nvc1': 'GF108', 'nvd7': 'GF117', 'nvd9': 'GF119'}


def opener(rel):
    f, _, mem = rel.partition(':'); p = os.path.join(DB, f)
    with open(p, 'rb') as h: m = h.read(6)
    if not mem: return ['xz', '-dc', p] if m.startswith(b'\xfd7zXZ') else ['cat', p]
    if m.startswith(b'\xfd7zXZ'): return ['tar', '-xOJf', p, mem]
    if m.startswith(b'BZh'): return ['tar', '-xOjf', p, mem]
    return ['sh', '-c', 'tar -xOzf "$0" "$1" | (xz -dc 2>/dev/null || cat)', p, mem]


def run(*a):
    return subprocess.run(['python3', '-I', os.path.join(HERE, a[0])] + list(a[1:]), capture_output=True, text=True)


def main():
    argv = sys.argv[1:]; cases = None; lim = 14
    if '--cases' in argv: k = argv.index('--cases'); cases = argv[k + 1]; del argv[k:k + 2]
    if '--lim' in argv: k = argv.index('--lim'); lim = int(argv[k + 1]); del argv[k:k + 2]
    S = json.load(open(OUT + '/scripts.json')); inv = json.load(open(OUT + '/inventory.json')); key = json.load(open(OUT + '/inventory-key.json'))
    labs = argv or [l for l, d in sorted(S.items()) if d.get('gen') == 'Fermi' and d.get('type') == 'DDR3' and d.get('scripts')]
    for lab in labs:
        tag = lab.replace('#', '_'); scr, host, st = (f'{W}/{tag}-{x}.json' for x in ('scr', 'host', 'st'))
        dd = os.path.dirname(os.path.join(DB, key[lab].split(':')[0]))
        roms = [os.path.join(dd, x) for x in sorted(os.listdir(dd)) if not x.endswith('.eml') and (x.lower().endswith(('.rom', '.bin')) or 'vbios' in x.lower())]
        raw = sorted({(int(s, 16) >> 2) & 0xf for s in inv[lab].get('strap', [])})
        if len(roms) != 1 or len(raw) != 1:
            print(f'## {lab}: пропуск (образов VBIOS {len(roms)}, ремешков {len(raw)})'); continue
        if not all(os.path.exists(x) for x in (scr, host, st, st.replace('.json', '-pre.json'))):
            with tempfile.NamedTemporaryFile(dir=W, suffix='.txt', delete=False) as f:
                tr = f.name; subprocess.run(opener(key[lab]), stdout=f, stderr=subprocess.DEVNULL)
            try:
                bar0 = inv[lab]['bar0']
                run('trace-memscr.py', tr, bar0, scr)
                if not os.path.exists(scr) or not json.load(open(scr)):
                    print(f'## {lab}: скрипты из записи не выбраны'); continue
                run('trace-memhost.py', tr, bar0, scr, host)
                run('memgen-ddr3.py', 'states', tr, bar0, scr, st)
            finally:
                os.remove(tr)
        name = f"{lab} ({CHIP.get(inv[lab]['chip'], inv[lab]['chip'])})"
        for mode, extra in (('check', []), ('hostcheck', [host])):
            r = run('memgen-ddr3.py', mode, name, roms[0], str(raw[0]), scr, st, *extra)
            out = [l for l in (r.stdout + r.stderr).strip().split('\n') if 'снятие настроек' not in l]
            out = [l if 'Error' not in l and 'File "' not in l else '   (ошибка разбора: генератор к этой записи не применим)' for l in out]
            print('\n'.join(l[:300] for l in out[:lim] + (['     …'] + out[-1:] if len(out) > lim else [])))
        if cases:
            r = run('memgen-ddr3.py', 'cases', lab, roms[0], str(raw[0]), scr, st, host, cases)
            print((r.stdout.strip() or r.stderr.strip().split('\n')[-1])[:300])


main()
