#!/usr/bin/env python3
# КАРТА ЗАПИСЕЙ (28.11.2026): одна опись всех записей драйвера NVIDIA (mmiotrace), какие у нас есть, — частной базы,
# тестировщиков и нашей карты, — в одном виде и с поиском. До неё записи делились на две кучки: база (опись
# db-mem-inventory.py и все утилиты db-*) и «то, что прислали» (папки тестировщиков, разбирались по одной).
#
#   python3 -I lab/recordings-map.py build              — собрать или обновить карту
#   python3 -I lab/recordings-map.py find УСЛОВИЕ ...   — поиск; условия: поле=значение, поле~подстрока, поле>=N, поле<=N
#        например:  find gen=Fermi type=DDR3 'vram>=2048'      find src~sasim      find chip=nvce 'mem_scripts>=1'
#   python3 -I lab/recordings-map.py show МЕТКА         — все поля одной записи
#
# build делает три вещи:
#   1) записи вне базы (источники перечислены в частном файле ОПИСЬ/extra-sources.json: кто, какая плата, где лежат
#      трассы и образ VBIOS) проходит тем же разбором, что и базу, даёт им метки того же вида (чип#номер, номера после
#      номеров базы; метка закрепляется за записью навсегда) и ДОБАВЛЯЕТ их в опись базы: inventory.json,
#      inventory-key.json, types.json, scripts.json. После этого каждая утилита db-* видит их наравне с базой.
#      Копии описи «только база» хранятся рядом (*.base.json). Образ VBIOS и трасса кладутся ссылками в ОПИСЬ/extra/МЕТКА/
#      — утилиты db-* ищут образ в папке трассы;
#   2) для каждой записи дочитывает из трассы то, чего в описи не было: объём видеопамяти (регистры, которые читал сам
#      драйвер NVIDIA), номер чипа, длительность;
#   3) пишет ОПИСЬ/recordings.json (всё, с путями — частный файл) и ОПИСЬ/recordings.md (таблица без путей).
# Только чтение трасс. Письма (.eml) не читаются. Пути базы и имена участников базы не печатаются; тестировщики — по
# именам GitHub. После пересборки описи базы (db-mem-inventory.py, db-mem-types.py, db-mem-scripts.py) — снова build.
import sys, os, json, subprocess, hashlib, collections, struct

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.environ.get('MEMSURVEY') or os.path.expanduser('~/Home/nouveau-archive/mem-survey')
DB = os.environ.get('TRACEDB') or os.path.expanduser('~/Home/nouveau-archive/nouveau_vbios_trace')
FILES = ('inventory', 'inventory-key', 'types', 'scripts')
TYPES = {0: 'DDR2', 1: 'DDR3', 2: 'GDDR3', 3: 'GDDR5', 6: 'HBM2', 8: 'GDDR5X'}
GEN = [('NV3x', range(0x30, 0x40)), ('NV4x', range(0x40, 0x50)), ('NV4x', range(0x60, 0x70)),
       ('Tesla', range(0x50, 0x51)), ('Tesla', range(0x84, 0xa0)), ('Tesla2', range(0xa0, 0xb0)),
       ('Fermi', range(0xc0, 0xe0)), ('Kepler', range(0xe0, 0x100)), ('Kepler', range(0x106, 0x110)),
       ('Maxwell', range(0x110, 0x130)), ('Pascal', range(0x130, 0x140)), ('Volta+', range(0x140, 0x200))]
BLOCKS = [('PFB 100xxx', 0x100000, 0x101000), ('FBPA общий 10fxxx', 0x10f000, 0x110000),
          ('FBPA разделы 110-12f', 0x110000, 0x130000), ('MPLL 132xxx', 0x132000, 0x133000),
          ('такты 137xxx', 0x137000, 0x138000), ('такты Tesla 004xxx', 0x004000, 0x004800),
          ('PMU 10axxx', 0x10a000, 0x10b000)]
VRAM = {0x10f20c: 'bsize', 0x022438: 'parts', 0x02243c: 'fbpas', 0x022554: 'pmask'}
VRAM.update({0x11020c + i * 0x1000: f'p{i}' for i in range(8)})


def J(name): return json.load(open(os.path.join(OUT, name + '.json')))
def gen(n):
    for g, r in GEN:
        if n in r: return g
    return '?'
def block(a):
    for n, lo, hi in BLOCKS:
        if lo <= a < hi: return n
def opener(rel):
    f, _, mem = rel.partition(':'); p = os.path.join(DB, f)        # абсолютный путь (запись вне базы) join оставляет как есть
    with open(p, 'rb') as h: m = h.read(6)
    if not mem: return ['xz', '-dc', p] if m.startswith(b'\xfd7zXZ') else ['cat', p]
    if m.startswith(b'\xfd7zXZ'): return ['tar', '-xOJf', p, mem]
    if m.startswith(b'BZh'): return ['tar', '-xOjf', p, mem]
    return ['sh', '-c', 'tar -xOzf "$0" "$1" | (xz -dc 2>/dev/null || cat)', p, mem]


def parse(w):
    """загрузка в память PMU как скрипт NVIDIA: [[операция, [аргументы]], ...] или None (как db-mem-scripts.py)"""
    i, ops, nw = 0, [], 0
    while i < len(w):
        ln, op = w[i] >> 16, w[i] & 0xffff
        if ln == 0 or i + ln > len(w) + 1 or op > 0xff: return None
        a = w[i + 1:i + ln]
        if op == 0x21 and len(a) % 2: return None
        ops.append([op, a]); nw += len(a) // 2 if op == 0x21 else 0
        if op == 0x16: return ops if nw >= 5 else None
        i += ln
def is_mem(ops):
    return any(0x100000 <= a[k] < 0x101000 or 0x10f000 <= a[k] < 0x130000 or 0x132000 <= a[k] < 0x133000
               for op, a in ops if op == 0x21 for k in range(0, len(a), 2))


def scan(cmd, full):
    """один проход по трассе. full: всё, что нужно описи (как db-mem-inventory.py и db-mem-scripts.py);
    иначе только добавочные поля (объём памяти, номер чипа, длительность)."""
    pr = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    bar0 = None; first = True; lines = 0; t0 = t1 = None; boot0 = None; vram = collections.defaultdict(set)
    host = collections.Counter(); hostregs = collections.defaultdict(set); strap = collections.Counter()
    up = scr = hwsq = other = 0; scrw = collections.Counter(); scrregs = collections.defaultdict(set)
    cur = None; tcur = 0.0; mem = []; h = hashlib.sha1(); hn = 0
    for raw in pr.stdout:
        if hn < (4 << 20): h.update(raw); hn += len(raw)
        if first:
            first = False
            if raw[:4] not in (b'VERS', b'MARK', b'MAP ', b'R 4 ', b'W 4 ', b'PCID', b'R 1 ', b'W 1 '): break
        if bar0 is None:
            if raw.startswith(b'MAP '):
                p = raw.split()
                if len(p) >= 6 and p[5] == b'0x1000000': bar0 = int(p[3], 16)
            continue
        if raw[:2] not in (b'W ', b'R '): continue
        p = raw.split()
        if len(p) < 6: continue
        try: a = int(p[4], 16) - bar0; v = int(p[5], 16); t = float(p[2])
        except ValueError: continue
        if not 0 <= a < 0x1000000: continue
        lines += 1; t1 = t
        if t0 is None: t0 = t
        if raw[0] == 82:                                   # чтение
            if a == 0x101000: strap[v] += 1
            elif a == 0 and boot0 is None: boot0 = v
            elif a in VRAM: vram[VRAM[a]].add(v)
            continue
        if not full: continue
        if a == 0x10a1c4 and cur is not None: cur.append(v); continue
        if cur is not None:
            ops = parse(cur)
            if ops:
                scr += 1
                for op, ar in ops:
                    if op == 0x21:
                        for k in range(0, len(ar), 2):
                            b = block(ar[k])
                            if b: scrw[b] += 1; scrregs[b].add(ar[k])
                if is_mem(ops): mem.append(dict(t=round(tcur - t0, 6), ops=ops))
                else: other += 1
            cur = None
        if a == 0x10a1c0: up += 1; cur = []; tcur = t; continue
        if 0x001400 <= a < 0x001800 or 0x080000 <= a < 0x081000: hwsq += 1
        b = block(a)
        if b: host[b] += 1; hostregs[b].add(a)
    pr.stdout.close(); pr.wait()
    if bar0 is None: return None
    r = dict(bar0=hex(bar0), lines=lines, seconds=round((t1 or 0) - (t0 or 0), 1), boot0=boot0,
             vram={k: sorted(v) for k, v in vram.items()}, sha=h.hexdigest()[:16],
             strap=sorted(f'{k:08x}' for k in strap))
    if full:
        r.update(pmu_uploads=up, pmu_scripts=scr, hwsq_writes=hwsq, host=dict(host), host_regs={k: len(v) for k, v in hostregs.items()},
                 scr_writes=dict(scrw), scr_regs={k: len(v) for k, v in scrregs.items()}, mem=mem, other=other)
    return r


def vram_mib(v):
    """объём, как его считает nouveau (gf100_ram_ctor, gf108_ram_probe_fbp_amount): сумма по контроллерам памяти (FBPA),
    кроме замаскированных; регистры — в МиБ. Проверено по платам с известным объёмом (наша 4x256, GTS 450 2x512 при
    маске первого, GTX 550 Ti 512+256+256, Quadro 600 2x512, ASUS GT 630 2x1024). Если драйвер NVIDIA читал только
    общий регистр, а число контроллеров в записи не видно, объём — нижняя оценка (второе значение False)."""
    pmask = (v.get('pmask') or [0])[0]
    ps = [v[f'p{i}'][0] for i in range(8) if f'p{i}' in v and not pmask >> i & 1]
    if ps: return sum(ps), True
    if 'bsize' in v:
        n = (v.get('fbpas') or [0])[0]
        return v['bsize'][0] * (n - bin(pmask).count('1') if n else 1), bool(n)
    return 0, False


def rom_bytes(p):
    b = open(p, 'rb').read()
    if b[:6] == b'\xfd7zXZ\x00': b = subprocess.run(['xz', '-dc', p], capture_output=True).stdout
    i = b.find(b'\x55\xaa')
    return b[i:] if i >= 0 else None
def rom_info(p, straps):
    """тип памяти по таблице M0203 (как db-mem-types.py) и версия VBIOS"""
    out = dict(type='?', bios='')
    b = rom_bytes(p)
    if not b: return out
    bit = b.find(b'\xff\xb8BIT'); r16 = lambda o: struct.unpack_from('<H', b, o)[0]
    if bit >= 0:
        ent = {chr(b[bit + 12 + i * b[bit + 9]]): (b[bit + 13 + i * b[bit + 9]], r16(bit + 14 + i * b[bit + 9]), r16(bit + 16 + i * b[bit + 9])) for i in range(b[bit + 10])}
        if 'M' in ent and ent['M'][0] == 2 and ent['M'][1] >= 5:
            t = r16(ent['M'][2] + 3)
            if t and t + 5 <= len(b) and b[t] == 0x10:
                m = {}
                for i in range(b[t + 3]): e = b[t + b[t + 1] + i * b[t + 2]]; m.setdefault(e >> 4, e & 0x0f)
                found = {TYPES.get(m[s], f'код {m[s]}') for s in straps if s in m}
                out['type'] = '/'.join(sorted(found)) or '?'
        if 'i' in ent and ent['i'][2] + 5 <= len(b):
            o = ent['i'][2]; out['bios'] = '%02x.%02x.%02x.%02x.%02x' % (b[o + 3], b[o + 2], b[o + 1], b[o], b[o + 4])
    return out


def discover(src):
    """трассы источника: обычные файлы и .xz под его корнями; копия .xz рядом с распакованным файлом пропускается"""
    seen = []
    for root in src['roots']:
        root = os.path.expanduser(root)
        for r, ds, fs in os.walk(root):
            ds.sort()
            for f in sorted(fs):
                low = f.lower()
                if 'mmiotrace' not in low or low.endswith(('.eml', '.tar.xz', '.tar.gz', '.log', '.sh', '.py')): continue
                p = os.path.join(r, f)
                if low.endswith('.xz') and os.path.exists(p[:-3]): continue
                if os.path.getsize(p) < 1 << 20: continue
                seen.append(p)
    return seen


def build():
    for f in FILES:                                         # копии «только база» — один раз
        b = os.path.join(OUT, f + '.base.json')
        if not os.path.exists(b):
            json.dump(J(f), open(b, 'w'), indent=1 if f != 'scripts' else None, ensure_ascii=False)
    inv, key, types, scripts = (json.load(open(os.path.join(OUT, f + '.base.json'))) for f in FILES)
    for lab in inv: inv[lab].setdefault('src', 'база')
    sources = J('extra-sources')
    cpath = os.path.join(OUT, 'recordings-cache.json')
    cache = json.load(open(cpath)) if os.path.exists(cpath) else {}
    reg_path = os.path.join(OUT, 'extra-labels.json')      # sha записи -> метка: закрепляется навсегда
    reg = json.load(open(reg_path)) if os.path.exists(reg_path) else {}
    nmax = collections.Counter()
    for lab in list(inv) + list(reg.values()):
        c, n = lab.split('#'); nmax[c] = max(nmax[c], int(n))
    meta = {}
    def cached(path, cmd, full):
        st = os.stat(os.path.join(DB, path.partition(':')[0])); k = f'{path}|{st.st_size}|{int(st.st_mtime)}|{int(full)}'
        if k not in cache or (cache[k] and not any(x.startswith('p') and x[1:].isdigit() or x == 'fbpas' for x in cache[k]['vram']) and 'v2' not in cache[k]):
            cache[k] = scan(cmd, full)
            if cache[k]: cache[k]['v2'] = 1
            json.dump(cache, open(cpath, 'w'))
        return cache[k]
    # 1) записи вне базы
    shas = {}
    for src in sources:
        for p in discover(src):
            r = cached(p, opener(p), True)
            if not r or r['boot0'] is None and not r['strap']: continue
            if r['sha'] in shas: continue                   # та же запись в другой папке
            shas[r['sha']] = p
            n = ((r['boot0'] or 0) >> 20) & 0x1ff
            chip = src.get('chip') or f'nv{n:02x}'
            if r['sha'] not in reg:
                nmax[chip] += 1; reg[r['sha']] = f'{chip}#{nmax[chip]}'
            lab = reg[r['sha']]
            d = os.path.join(OUT, 'extra', lab.replace('#', '_')); os.makedirs(d, exist_ok=True)
            link = os.path.join(d, 'mmiotrace.txt' + ('.xz' if p.endswith('.xz') else ''))
            for l, tgt in ((link, p), (os.path.join(d, 'vbios.rom'), os.path.expanduser(src['rom']) if src.get('rom') else None)):
                if os.path.islink(l): os.remove(l)
                if tgt: os.symlink(tgt, l)
            straps = {(int(s, 16) >> 2) & 0xf for s in r['strap']}
            ri = rom_info(os.path.expanduser(src['rom']), straps) if src.get('rom') else dict(type='?', bios='')
            g = gen(int(chip[2:], 16))
            inv[lab] = {k: r[k] for k in ('bar0', 'lines', 'pmu_uploads', 'pmu_scripts', 'hwsq_writes', 'strap', 'host', 'host_regs', 'scr_writes', 'scr_regs')}
            inv[lab].update(chip=chip, gen=g, src=src['src'], card=src.get('card', ''))
            key[lab] = link
            types[lab] = dict(chip=chip, gen=g, type=ri['type'], note='' if src.get('rom') else 'нет образа', scripts=r['pmu_scripts'])
            if r['pmu_scripts']: scripts[lab] = dict(chip=chip, gen=g, type=ri['type'], scripts=r['mem'], other=r['other'])
            meta[lab] = dict(path=p, rom=src.get('rom', ''), bios=ri['bios'], note=src.get('note', ''))
            print(f"{lab:10} {src['src']:14} {src.get('card', '')[:28]:28} {ri['type']:6} скриптов памяти {len(r['mem']):>3}", flush=True)
    json.dump(reg, open(reg_path, 'w'), indent=1)
    for f, d in zip(FILES, (inv, key, types, scripts)):
        json.dump(d, open(os.path.join(OUT, f + '.json'), 'w'), indent=1 if f != 'scripts' else None, ensure_ascii=False)
    # 2) добавочные поля для всех записей, 3) карта
    recs = []
    for lab in sorted(inv, key=lambda l: (l.split('#')[0], int(l.split('#')[1]))):
        r = inv[lab]
        x = cached(key[lab], opener(key[lab]), lab in meta) or {}
        sc = scripts.get(lab, {}).get('scripts', [])
        m = meta.get(lab, {})
        roms = 1 if m.get('rom') else 0
        if lab not in meta:
            d = os.path.dirname(os.path.join(DB, key[lab].split(':')[0]))
            roms = len([f for f in os.listdir(d) if not f.endswith('.eml') and (f.lower().endswith(('.rom', '.bin')) or 'vbios' in f.lower())])
        recs.append(dict(label=lab, src=r.get('src', 'база'), card=r.get('card', ''), chip=r['chip'], gen=r['gen'],
                         type=types.get(lab, {}).get('type', '?'), vram=vram_mib(x.get('vram', {}))[0], vram_exact=int(vram_mib(x.get('vram', {}))[1]),
                         strap=','.join(sorted({str((int(s, 16) >> 2) & 0xf) for s in r['strap']})),
                         minutes=round(x.get('seconds', 0) / 60, 1), lines=r['lines'], pmu_scripts=r['pmu_scripts'],
                         mem_scripts=len(sc), mem_distinct=len({json.dumps(s['ops']) for s in sc}), vbios=roms,
                         bios=m.get('bios', ''), note=m.get('note', ''), path=m.get('path', key[lab])))
    json.dump(recs, open(os.path.join(OUT, 'recordings.json'), 'w'), indent=1, ensure_ascii=False)
    with open(os.path.join(OUT, 'recordings.md'), 'w') as f:
        f.write('# Карта записей драйвера NVIDIA (собирает lab/recordings-map.py build)\n\n'
                f'Всего записей: {len(recs)} (база {sum(1 for r in recs if r["src"] == "база")}, вне базы {sum(1 for r in recs if r["src"] != "база")}). '
                'Столбцы: память — МиБ по регистрам, которые читал драйвер NVIDIA (пусто — не читал; «≥» — нижняя оценка: число контроллеров памяти в записи не видно); набор — номер набора настроек '
                'памяти по ремешку; скрипты — скриптов памяти всего / разных; VBIOS — сколько образов лежит при записи.\n\n'
                '| метка | откуда | плата | поколение | чип | тип памяти | память | набор | минут | скрипты | VBIOS |\n|---|---|---|---|---|---|---|---|---|---|---|\n')
        for r in recs:
            f.write(f"| {r['label']} | {r['src']} | {r['card']} | {r['gen']} | {r['chip']} | {r['type']} | {('' if r['vram_exact'] else '≥ ') + str(r['vram']) if r['vram'] else ''} | {r['strap']} | "
                    f"{r['minutes']} | {r['mem_scripts']} / {r['mem_distinct']} | {r['vbios']} |\n")
    by = collections.Counter((r['gen'], r['type'], 'база' if r['src'] == 'база' else 'вне базы') for r in recs if r['mem_scripts'])
    print(f'карта: {len(recs)} записей -> recordings.json, recordings.md')
    for (g, t, s), n in sorted(by.items()): print(f'  со скриптами памяти: {g} {t} {s}: {n}')


def match(r, cond):
    for op in ('>=', '<=', '~', '='):
        if op in cond:
            k, v = cond.split(op, 1)
            if k not in r: sys.exit(f'нет поля {k}; поля: ' + ', '.join(r))
            x = r[k]
            if op == '~': return v.lower() in str(x).lower()
            if op == '=': return str(x).lower() == v.lower()
            try: return (float(x) >= float(v)) if op == '>=' else (float(x) <= float(v))
            except ValueError: return False
    sys.exit(f'не понял условие {cond}')


def main():
    a = sys.argv[1:]
    if not a: sys.exit(__doc__ or 'build | find УСЛОВИЕ... | show МЕТКА')
    if a[0] == 'build': return build()
    recs = J('recordings')
    if a[0] == 'show':
        for r in recs:
            if r['label'] == a[1]:
                for k, v in r.items():
                    if k != 'path' or r['src'] != 'база': print(f'{k:13} {v}')
        return
    if a[0] == 'find':
        hit = [r for r in recs if all(match(r, c) for c in a[1:])]
        print(f"{'метка':10} {'откуда':14} {'плата':30} {'покол.':7} {'тип':6} {'МиБ':>6} {'набор':5} {'мин':>6} {'скрипты':>9} VBIOS")
        for r in hit:
            print(f"{r['label']:10} {r['src']:14} {r['card'][:30]:30} {r['gen']:7} {r['type']:6} {(('' if r['vram_exact'] else '>=') + str(r['vram'])) if r['vram'] else '':>6} {r['strap']:5} {r['minutes']:>6} "
                  f"{str(r['mem_scripts']) + '/' + str(r['mem_distinct']):>9} {r['vbios']}")
        print(f'найдено: {len(hit)} из {len(recs)}')
        return
    sys.exit('build | find УСЛОВИЕ... | show МЕТКА')


main()
