#!/usr/bin/env python3
# ИСТОЧНИКИ ТАКТА УЗЛОВ В ЗАПИСЯХ NVIDIA (31.10): какие коды источника (биты 0–1 регистров 0x137160 + idx·4) драйвер NVIDIA
# пишет на Fermi и Kepler, по узлам. Вопрос: где и когда используется код 2 (nouveau: «100 МГц»), который на GF108 стоит у
# hubk01 на 0f. Только чтение; участники базы — обезличенные номера (lab/trace-vbios.py). Класс Д.
#   python3 -I lab/db-clk-src.py [нижний чип, верхний чип в hex, по умолчанию c0 11f]
import collections, importlib.util, multiprocessing as mp, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
s = importlib.util.spec_from_file_location('tv', os.path.join(HERE, 'trace-vbios.py'))
tv = importlib.util.module_from_spec(s); s.loader.exec_module(tv)

def scan(job):
    chip, who, i, path = job
    base, writes, mux = None, collections.Counter(), collections.Counter()
    last_mux = None
    try:
        for raw in tv.stream(path):
            if raw.startswith(b'MAP '):
                f = raw.split()
                if base is None and len(f) > 5 and int(f[5], 16) == 0x1000000:
                    base = int(f[3], 16)
                continue
            if base is None or not raw.startswith(b'W '):
                continue
            f = raw.split()
            if len(f) < 6:
                continue
            a = int(f[4], 16) - base
            if a == 0x137100:
                last_mux = int(f[5], 16)
            elif 0x137160 <= a < 0x1371d0:
                v = int(f[5], 16)
                writes[(f'{(a - 0x137160) // 4:02x}', v & 3, v & 0x100 and 1, f'{v:#x}', f'{last_mux:#x}' if last_mux is not None else '-')] += 1
    except Exception as e:
        return chip, who, i, None, str(e)[:60]
    return chip, who, i, dict(writes), None

if __name__ == '__main__':
    lo, hi = (int(x, 16) for x in (sys.argv[1:3] if len(sys.argv) > 2 else ('c0', '11f')))
    jobs = [(chip, who, i, os.path.join(tv.DB, t)) for chip, who, trs, vbs in tv.boards(lo, hi) for i, t in enumerate(trs)]
    with mp.get_context('fork').Pool(4) as pool:
        res = pool.map(scan, jobs)
    code2 = []; per = collections.defaultdict(collections.Counter); bad = 0
    for chip, who, i, w, err in res:
        if w is None:
            bad += 1; continue
        for (idx, code, lane, v, m), n in w.items():
            per[(chip[:4] if chip[:4] != 'nv10' else chip, idx)][code] += n
            if code == 2:
                code2.append((chip, who, i, idx, v, m, n))
    print(f'записей {len(jobs)}, не прочитано {bad}')
    print('коды источника в записях NVIDIA (чип, узел idx): {код: записей в регистр}')
    for k in sorted(per): print('  ', k, dict(sorted(per[k].items())))
    print('код 2 — где и при каком 0x137100 (последняя запись переключателя перед ним):')
    for c in sorted(code2): print('  ', c)
