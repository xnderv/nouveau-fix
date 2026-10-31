#!/usr/bin/env python3
# СВЕРКА ЯДРА ПО БАЗЕ (30.10): для каждой платы Fermi с записью NVIDIA (internal vbios repo) — что NVIDIA выставила на узлах
# ядра на каждом уровне, и какие правила это объясняют. Вопросы (docs/2026-10-30/core-map.md, раздел 5):
#   1 — делитель или PLL: флаг таблицы уровней (биты 14–15), окно −2…+3 МГц (nouveau gt215), «ближе» (nouveau gf100);
#   2 — коэффициенты PLL: NVIDIA против gt215_pll_calc, какое M из нескольких точных решений;
#   3 — напряжение: фьюз speedo (0x0212cc) → карта напряжений VBIOS → ступень VID против VID NVIDIA;
#   4 — делители на уровнях без PLL: раскладка GPC (основной /2 + пост-делитель) и PMU.
# Два прохода:
#   python3 -I lab/db-core-check.py scan ВЫХОД.json [чипы c0 df] — читает записи (4 параллельно), сохраняет устоявшиеся
#       состояния тактовых регистров (пауза записей > 50 мс), VID, speedo и образ VBIOS из записи; участники обезличены
#   python3 -I lab/db-core-check.py report ВЫХОД.json             — сопоставляет с VBIOS платы и печатает ответы
# Класс Д (чужие записи) + В (VBIOS) + Г (логика nouveau). Пути и адреса участников не выводятся и не сохраняются.
import collections, glob, json, os, re, subprocess, sys, importlib.util
from multiprocessing import Pool

HERE = os.path.dirname(os.path.abspath(__file__))
def _load(name, file):
    s = importlib.util.spec_from_file_location(name, os.path.join(HERE, file)); m = importlib.util.module_from_spec(s)
    s.loader.exec_module(m); return m
tv = _load('tv', 'trace-vbios.py')
cp = _load('cp', 'core-predict.py')
EXTRACTED = os.path.expanduser('~/Home/nouveau-archive/trace-vbios/2026-10-30-fermi')
GAP = 0.05
NODES = [(0x00, 'gpc', 3), (0x01, 'rop', 4), (0x02, 'hubk07', 11), (0x07, 'hubk06', 0), (0x08, 'hubk01', 1),
         (0x09, 'copy', 2), (0x0c, 'pmu', 10), (0x0e, 'vdec', 6)]
VID = (0x00e104, 0x00e108, 0x00e280, 0x00e284)
# эталоны с известным ответом (не из базы): наша запись try7 и запись Q0AL; образ Q0AL собран из его записи
EXTRA = {('nvce', 'наша'): (os.path.join(os.path.dirname(HERE), 'results/trace-try7/mmiotrace-full.txt.xz'),
                            os.path.expanduser('~/Home/nouveau-archive/vbios.rom')),
         ('nvce', 'Q0AL'): (os.path.expanduser('~/Home/stand-2011/q0al-gtx560/round1/out/out-20261029-170414/mmiotrace.txt.xz'),
                            os.path.expanduser('~/Home/stand-2011/q0al-gtx560/round1/rom/gtx560-from-trace.rom'))}

def streams(path):
    """[(метка члена, поток)]: .xz (в том числе xz внутри xz), простой текст, .tar.gz (каждый член с mmio/trace)."""
    if path.endswith('.tar.gz'):
        names = subprocess.run(['tar', '-tzf', path], capture_output=True, text=True).stdout.split('\n')
        out = []
        for i, m in enumerate(n for n in names if n and (re.search(r'mmio|trace', os.path.basename(n).lower()) or n.endswith('.xz'))):
            head = subprocess.run(f"tar -xOzf '{path}' '{m}' | head -c 6", shell=True, capture_output=True).stdout
            cmd = f"tar -xOzf '{path}' '{m}'" + (" | xz -dc" if head.startswith(b'\xfd7zXZ') else '')
            out.append((f'член {i}', subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout))
        return out
    return [('', tv.stream(path))]

def is_clk(a):
    return 0x137000 <= a < 0x137400 or a in (0x00e800, 0x00e804, 0x00e820, 0x00e824) or a in VID

def replay(stream):
    bar, regs, wrote, last, snaps, speedo = None, {}, collections.Counter(), None, collections.Counter(), None
    mem = {'PROM': {}, 'VRAM': {}}; base = 0
    def snap():
        snaps[json.dumps({f'{a:06x}': v for a, v in sorted(regs.items()) if 0x137000 <= a < 0x137400 or a in VID
                          or a in (0x00e804, 0x00e824)}, sort_keys=True)] += 1
    for raw in stream:
        c0 = raw[:2]
        if raw.startswith(b'MAP '):
            f = raw.split()
            if bar is None and len(f) > 5 and int(f[5], 16) == 0x1000000:
                bar = int(f[3], 16)
            continue
        if bar is None or c0 not in (b'W ', b'R '):
            continue
        f = raw.split()
        if len(f) < 6:
            continue
        a = int(f[4], 16) - bar
        if not (is_clk(a) or a == 0x0212cc or a == 0x001700 or 0x300000 <= a < 0x400000 or 0x700000 <= a < 0x800000):
            continue
        w, v, t = int(f[1]), int(f[5], 16), float(f[2])
        if c0 == b'R ':
            if a == 0x0212cc:
                speedo = v
            elif 0x300000 <= a < 0x400000 or 0x700000 <= a < 0x800000:
                m, o = (mem['PROM'], a - 0x300000) if a < 0x400000 else (mem['VRAM'], base + a - 0x700000)
                for i in range(w):
                    m.setdefault(o + i, (v >> (8 * i)) & 0xff)
            elif a not in regs:
                regs[a] = v
            continue
        if a == 0x001700:
            base = v << 16
            continue
        if last is not None and t - last > GAP:
            snap()
        last = t
        regs[a] = v
        wrote[a] += 1
    snap()
    img = tv.image(mem)
    return {'snaps': snaps, 'speedo': speedo, 'wrote_hub_pll': wrote[0x1370e4], 'image_version': tv.version(img[1]) if img else None,
            'image_src': img[0] if img else None}

def scan_one(job):
    chip, who, i, path = job
    out = []
    try:
        for member, st in streams(path):
            r = replay(st)
            r.update(chip=chip, who=who, trace=f'{i}{(" " + member) if member else ""}')
            out.append(r)
    except Exception as e:
        out.append({'chip': chip, 'who': who, 'trace': str(i), 'error': repr(e)[:200]})
    return out

def scan(outp, lo, hi):
    jobs = [(chip, who, i, os.path.join(tv.DB, t)) for chip, who, trs, vbs in tv.boards(lo, hi) for i, t in enumerate(trs)]
    jobs += [(c, w, 0, tr) for (c, w), (tr, rom) in EXTRA.items() if lo <= int(c[2:], 16) <= hi]
    res = []
    with Pool(4) as pool:
        for part in pool.imap_unordered(scan_one, jobs):
            for r in part:
                r['snaps'] = dict(r.get('snaps', {}))
                print(f"{r['chip']} {r['who']} запись {r['trace']}: состояний {len(r['snaps'])}, speedo {r.get('speedo')}, "
                      f"образ {r.get('image_version')} ({r.get('image_src')}){' ОШИБКА ' + r['error'] if 'error' in r else ''}", flush=True)
                res.append(r)
    json.dump(res, open(outp, 'w'), ensure_ascii=False)
    print('записано', len(res), 'записей')

# ---------- разбор ----------
def sppll(regs, src):
    c = regs.get(0x00e824 if src & 0x100 else 0x00e804, 0)
    N, M = (c >> 8) & 0xff, c & 0xff
    return 27000 * N // M if M else 0

def path_div(regs, idx, sbase, cbase, use_ctl):
    s = regs.get(sbase + idx * 4, 0)
    if s & 3 == 0:
        return 108000 if (s & 0x30000) == 0x30000 else 27000
    if s & 3 == 2:
        return 100000
    if s & 3 == 3:
        vco, c, d = sppll(regs, s), regs.get(cbase + idx * 4, 0), 2
        if use_ctl and c & 0x80000000:
            d = ((c >> 8 if s & 0x100 else c) & 0x3f) + 2
        return vco * 2 // d
    return 0

def node(regs, idx):
    """('P'|'D', частота кГц, коэффициенты или делители, опора PLL)."""
    sel, sctl = regs.get(0x137100, 0) & (1 << idx), regs.get(0x137250 + idx * 4, 0)
    if sel:
        pll = 0x137000 + idx * 0x20 if idx < 7 else 0x1370e0
        ctrl, coef = regs.get(pll, 0), regs.get(pll + 4, 0)
        P, N, M = (coef >> 16) & 0x3f, (coef >> 8) & 0xff, coef & 0xff
        ref = path_div(regs, min(idx, 7), 0x137120, 0x137140, True)
        src = ref * N // M // P if ctrl & 1 and M and P else 0
        out = src * 2 // (((sctl >> 8) & 0x3f) + 2) if sctl & 0x80000000 else src
        return 'P', out, f'{coef:08x}', ref
    src = path_div(regs, idx, 0x137160, 0x1371d0, idx <= 2)
    out = src * 2 // ((sctl & 0x3f) + 2) if sctl & 0x80000000 else src
    return 'D', out, f'{regs.get(0x1371d0 + idx * 4, 0) if idx <= 2 else 0:08x}/{sctl:08x}', None

def board_rom(chip, who, image_version):
    if (chip, who) in EXTRA:
        return EXTRA[(chip, who)][1], 'эталон'
    for c, w, trs, vbs in tv.boards(0xc0, 0xdf):
        if (c, w) != (chip, who):
            continue
        cands = [os.path.join(tv.DB, v) for v in vbs] + sorted(glob.glob(os.path.join(EXTRACTED, f'{chip}-{who}-*.rom')))
        cands = [p for p in cands if os.path.exists(p)]
        for p in cands:
            if image_version and tv.version(open(p, 'rb').read()) == image_version:
                return p, 'версия как в записи'
        return (cands[0], 'версия не сверена') if cands else (None, 'образа нет')
    return None, 'плата не найдена'

def volt_info(romp):
    """Таблица напряжений (base/step/vidmask/max), карта напряжений (min, max, arg0..2), индекс карты по уровням и линии VID
    из таблицы GPIO — тем же разбором, что lab/vbios-volt.py и lab/vbios-vid.py (класс В по коду nouveau, Г)."""
    import ast, struct
    vt = subprocess.run([sys.executable, '-I', os.path.join(HERE, 'vbios-volt.py'), '--text', romp], capture_output=True, text=True).stdout
    m = re.search(r'base (\d+) мкВ, step (-?\d+) мкВ/VID, vidmask (0x[0-9a-f]+), max (\d+)', vt)
    lm = re.search(r'индекс карты по уровням: (\{[^}]*\})', vt)
    if not m or not lm:
        return None
    vmap = {int(i): (int(a), int(b), int(c0), int(c1), int(c2)) for i, a, b, c0, c1, c2 in
            re.findall(r'(\d+): (\d+)–(\d+) мкВ arg \[(\d+), (\d+), (\d+)\]', vt)}
    rom = open(romp, 'rb').read()
    rd8 = lambda o: rom[o]; rd16 = lambda o: struct.unpack_from('<H', rom, o)[0]; rd32 = lambda o: struct.unpack_from('<I', rom, o)[0]
    dcb = rd16(0x36); hdr = rd8(dcb + 1); gpio = rd16(dcb + 0x0a) if hdr >= 0x0c else 0
    lines = {}
    if gpio:
        gver, ghdr, gcnt, glen = rd8(gpio), rd8(gpio + 1), rd8(gpio + 2), rd8(gpio + 3)
        VIDF = {0x04: 0, 0x05: 1, 0x06: 2, 0x1a: 3, 0x73: 4, 0x74: 5, 0x75: 6, 0x76: 7}
        for e in range(gcnt):
            d = gpio + ghdr + e * glen
            if gver < 0x41:
                info = rd32(d); line, func, log1 = info & 0x1f, (info >> 8) & 0xff, (info >> 29) & 3
            else:
                info, info1 = rd32(d), rd8(d + 4); line, func, log1 = info & 0x3f, (info >> 8) & 0xff, (info1 >> 6) & 3
            if func in VIDF:
                lines[VIDF[func]] = (line, log1)
    return dict(base=int(m[1]), step=int(m[2]), vidmask=int(m[3], 16), vmax=int(m[4]), vmap=vmap,
                lvl={int(k, 16): v for k, v in ast.literal_eval(lm[1]).items()}, lines=lines)

def vid_uv(vi, regs):
    vid = 0
    for b, (line, log1) in vi['lines'].items():
        if not (vi['vidmask'] >> b) & 1:
            continue
        reg = (0x00e104, 0x00e108, 0x00e280, 0x00e284)[line >> 3]
        if reg not in regs:
            return None
        vid |= (1 if ((regs[reg] >> ((line & 7) << 2)) & 1) == (log1 & 1) else 0) << b
    return min(vi['base'] + vi['step'] * vid, vi['vmax'])

def volt_pred(vi, lv, speedo):
    """Расчёт nouveau (nvkm_volt_map, версия 0x10) и выбор ступени VID не ниже (nvkm_volt_set)."""
    idx = vi['lvl'].get(lv)
    if idx is None or idx not in vi['vmap']:
        return None, None
    lo, hi, a0, a1, a2 = vi['vmap'][idx]
    sg = lambda x: x - (1 << 32) if x >= 1 << 31 else x
    tdiv = lambda a, b: (abs(a) // b) * (1 if a >= 0 else -1)
    a0, a1, a2 = sg(a0), sg(a1), sg(a2)
    if (a1 or a2) and speedo is None:
        return None, None
    s = speedo or 0
    r = max(lo, min(hi, tdiv(a0, 10) + tdiv(a1 * s, 10) + tdiv(a2 * s * s, 100000)))
    steps = sorted({min(vi['base'] + vi['step'] * v, vi['vmax']) for v in range(vi['vidmask'] + 1)})
    up = [u for u in steps if u >= r]
    return r, (up[0] if up else None)

def report(inp):
    res = json.load(open(inp))
    q1 = collections.Counter(); q1cases = []; q2 = []; q4 = collections.Counter(); q4cases = []; lvl_seen = collections.Counter()
    boards_used = set(); notes = []; seen_nodes = set(); q3 = []; seen_volt = set(); lag = collections.Counter()
    for r in sorted(res, key=lambda r: (r['chip'], r['who'], r['trace'])):
        if 'error' in r:
            notes.append(f"{r['chip']} {r['who']} запись {r['trace']}: ошибка чтения"); continue
        romp, how = board_rom(r['chip'], r['who'], r.get('image_version'))
        if not romp:
            notes.append(f"{r['chip']} {r['who']}: {how}"); continue
        try:
            rom = cp.Rom(romp); levels = rom.levels(); vi = volt_info(romp)
        except Exception as e:
            notes.append(f"{r['chip']} {r['who']}: VBIOS не разобран ({str(e)[:60]})"); continue
        for sj, cnt in r['snaps'].items():
            regs = {int(k, 16): v for k, v in json.loads(sj).items()}
            if not regs.get(0x00e804):
                continue
            st = {idx: node(regs, idx) for idx, _, _ in NODES}
            for lv, e in levels.items():
                tg = {idx: e['sub'].get(s, 0) for idx, _, s in NODES}
                core = [0x00, 0x07]                            # у GF108/GF117/GF119 частоты ROP в таблице нет
                if not all(tg[i] and abs(st[i][1] - tg[i]) <= 3000 for i in core):
                    continue
                key = (r['chip'], r['who'], lv)
                lvl_seen[key] += 1
                if vi and vi['lines']:
                    nv_uv = vid_uv(vi, regs)
                    calc_uv, step_uv = volt_pred(vi, lv, r.get('speedo'))
                    k3 = (r['chip'], r['who'], lv, nv_uv)
                    if nv_uv and k3 not in seen_volt:
                        seen_volt.add(k3)
                        q3.append((r['chip'], r['who'], lv, r.get('speedo'), calc_uv, step_uv, nv_uv))
                elif not vi or not vi['lines']:
                    notes.append(f"{r['chip']} {r['who']}: линий VID в GPIO нет (напряжение ШИМ?) — вопрос 3 пропущен")
                boards_used.add((r['chip'], r['who']))
                vco = sppll(regs, regs.get(0x137160, 0))
                for idx, name, s in NODES:
                    if idx in (0x09, 0x0c, 0x0e) or not tg[idx]:
                        continue
                    nv_path, nv_out, nv_det, ref = st[idx]
                    flag = e['flag'].get(s)
                    if abs(nv_out - tg[idx]) > 3000:
                        lag[name] += 1                         # узел ещё не пришёл к уровню (hubk07 — вместе с памятью)
                        continue
                    k = (r['chip'], r['who'], lv, idx, nv_path, nv_det)
                    if k in seen_nodes:
                        continue                               # одно и то же состояние узла на уровне считаем один раз
                    seen_nodes.add(k)
                    # кандидатные правила
                    clk0, div0 = cp.calc_div(vco, tg[idx]) if vco else (0, 0)
                    if idx < 7 and vco:
                        clk0, _ = cp.calc_div(clk0, tg[idx])
                    win = 'D' if -2000 <= tg[idx] - clk0 < 3000 else 'P'
                    near = 'D' if clk0 == tg[idx] else None
                    if near is None:
                        lim = rom.pll(0x137000 + idx * 0x20 if idx < 7 else 0x1370e0) if idx <= 7 else None
                        clk1 = cp.gt215_pll_calc(lim, 405000, tg[idx])[0] if lim else (tg[0x07] if idx == 8 else 0)
                        near = 'D' if abs(tg[idx] - clk0) <= abs(tg[idx] - clk1) else 'P'
                    fl = 'P' if flag == 1 else 'D'                 # флаг 1 → PLL; 2 и 0 (старые VBIOS) → делитель
                    for rule, pred in (('флаг', fl), ('окно gt215', win), ('ближе gf100', near)):
                        q1[(rule, pred == nv_path)] += 1
                    if len({fl, win, near, nv_path}) > 1:
                        q1cases.append(f"{r['chip']} {r['who']} ур.{lv:02x} {name:6s} цель {tg[idx]//1000:5d} флаг {flag}: "
                                       f"NVIDIA {nv_path} ({nv_out}), флаг→{fl}, окно→{win}, ближе→{near}, делитель даёт {clk0}")
                    # вопрос 2: коэффициенты
                    if nv_path == 'P' and idx <= 7 and ref:
                        lim = rom.pll(0x137000 + idx * 0x20 if idx < 7 else 0x1370e0)
                        if lim:
                            got, coef = cp.gt215_pll_calc(lim, ref, tg[idx])
                            sols = []
                            for M in range(lim['min_m'], lim['max_m'] + 1):
                                if not (lim['min_in'] <= ref // M <= lim['max_in']):
                                    continue
                                N = round(tg[idx] * M / ref)
                                if lim['min_n'] <= N <= lim['max_n']:
                                    sols.append((abs(ref * N // M - tg[idx]), M, N))
                            best = min(sols)[0] if sols else None
                            exact = [(M, N) for err, M, N in sols if err == best]
                            nvM = int(nv_det, 16) & 0xff
                            pos = ('единственное' if len(exact) == 1 else 'наименьшее M' if nvM == min(m for m, _ in exact)
                                   else 'наибольшее M' if nvM == max(m for m, _ in exact) else 'среднее M' if nvM in [m for m, _ in exact]
                                   else 'не из лучших')
                            q2.append((r['chip'], r['who'], lv, name, tg[idx], nv_det, f'{coef:08x}' if coef else '-', pos,
                                       len(exact), 'да' if coef and f'{coef:08x}' == nv_det else 'нет',
                                       'VBIOS' if idx == 7 and not r.get('wrote_hub_pll') else 'драйвер'))
                    # вопрос 4: делители без PLL
                    if nv_path == 'D' and idx in (0x00, 0x0c):
                        q4[(name, abs(nv_out - tg[idx]) <= 1000)] += 1
                        if idx == 0x00:
                            q4cases.append(f"{r['chip']} {r['who']} ур.{lv:02x} gpc цель {tg[idx]} NVIDIA {nv_out} делители {nv_det}")
    print(f'плат с сопоставленными уровнями: {len(boards_used)}; пар (плата, уровень): {len(lvl_seen)}')
    print('\n== Вопрос 1. Делитель или PLL: сколько узлов объясняет правило (да / нет)')
    for rule in ('флаг', 'окно gt215', 'ближе gf100'):
        print(f'  {rule:12s} да {q1[(rule, True)]:4d}  нет {q1[(rule, False)]:4d}')
    print('  узлы, ещё не пришедшие к частоте уровня в снимке (не считались):', dict(lag))
    print('  случаи, где правила расходятся между собой или с NVIDIA:')
    for c in q1cases:
        print('   ', c)
    print('\n== Вопрос 2. Коэффициенты PLL у NVIDIA (кто ставит; совпадение с gt215_pll_calc; какое M из точных)')
    pos = collections.Counter((x[3], x[7], x[10]) for x in q2)
    for k, n in sorted(pos.items()):
        print(f'  {k[0]:7s} {k[1]:14s} {k[2]:8s} ×{n}')
    for x in q2:
        if x[7] not in ('единственное',) or x[9] == 'нет':
            print(f'   {x[0]} {x[1]} ур.{x[2]:02x} {x[3]:6s} цель {x[4]//1000} NVIDIA {x[5]} nouveau {x[6]} → {x[7]} из {x[8]}, совпало: {x[9]}, ставит {x[10]}')
    print('\n== Вопрос 3. Напряжение: формула VBIOS от speedo → ступень VID не ниже, против VID NVIDIA (мкВ)')
    ok = sum(1 for x in q3 if x[5] == x[6]); unk = sum(1 for x in q3 if x[5] is None)
    print(f'  совпало {ok}, не совпало {len(q3) - ok - unk}, не посчитать (нет speedo / карты) {unk}')
    for x in q3:
        mark = 'да' if x[5] == x[6] else ('?' if x[5] is None else 'НЕТ')
        print(f'   {x[0]} {x[1]} ур.{x[2]:02x} speedo {x[3]} формула {x[4]} → ступень {x[5]}, NVIDIA {x[6]}  {mark}')
    print('\n== Вопрос 4. Узлы на делителях: частота NVIDIA в пределах 1 МГц от таблицы')
    for k, n in sorted(q4.items()):
        print(f'  {k[0]:5s} {"да" if k[1] else "нет"} ×{n}')
    lay = collections.Counter(re.sub(r'^.* делители ', '', c).split('/')[0][-4:] for c in q4cases)
    print('  основной делитель GPC (поля B A) у NVIDIA:', dict(lay))
    print('\n== Замечания')
    for n in notes:
        print('  ', n)

if __name__ == '__main__':
    a = sys.argv[1:]
    if a and a[0] == 'scan':
        lo, hi = (int(a[2], 16), int(a[3], 16)) if len(a) >= 4 else (0xc0, 0xdf)
        scan(a[1], lo, hi)
    elif a and a[0] == 'report':
        report(a[1])
    else:
        print(open(__file__).read().split('\nimport')[0]); sys.exit(1)
