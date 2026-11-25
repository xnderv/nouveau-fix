#!/usr/bin/env python3
# СВЕРКА СОСТОЯНИЯ, часть 1 (на любой машине): какие значения держит драйвер NVIDIA в регистрах блоков памяти, шины XBAR,
# тактов памяти и кэша L2 — по записи mmiotrace. Учитываются записи хоста, чтения хоста (значение, которое NVIDIA увидела)
# и записи, которые выполняют скрипты памяти PMU (текст скриптов — из lab/trace-memscr.py). Для каждого скрипта памяти
# сохраняются два состояния: за 25 мс до пуска и через 60 мс после него (после прямых записей «после скрипта»).
# Выход: КАТАЛОГ/addrs.txt — список адресов для lab/memstate-dump.py; КАТАЛОГ/nvidia-state.json — состояния.
# Только чтение записи.   python3 -I lab/trace-memstate.py ЗАПИСЬ[.xz] СКРИПТЫ.json КАТАЛОГ
import sys, os, json, subprocess, collections

BLOCKS = [(0x100000, 0x101000, 'PFB'), (0x10f000, 0x110000, 'FBPA'), (0x110000, 0x112000, 'FBPA раздел'),
          (0x13b000, 0x13f000, 'XBAR'), (0x132000, 0x132200, 'PLL памяти'), (0x137000, 0x137400, 'такты'),
          (0x17e000, 0x17f000, 'кэш L2'), (0x00e100, 0x00e300, 'GPIO')]
SINGLE = {0x001548: 'флаг смены тактов', 0x022680: '0x022680', 0x02241c: '0x02241c', 0x610300: 'дисплей 0x610300',
          0x611200: 'пауза дисплея', 0x00e9e0: 'такт дисплея'}
# Не читать при снимке: порты шаблонов обучения (чтение сдвигает указатель), команды памяти, запуск сброса TLB, порты таблиц
# кэша с индексом, линии I2C, счётчики тактов, доступ к предохранителям.
SKIP = set(range(0x10f918, 0x10f928, 4)) | {0x10f968, 0x10f96c, 0x10f310, 0x10f314, 0x100cb8, 0x100cbc, 0x00e180, 0x00e274,
                                            0x022400, 0x13d834, 0x13d874, 0x13d8b4, 0x13d8f4,
                                            0x100f04}   # на GF108 под nouveau чтение 0x100f04 — ошибка шины (отчёт тестировщика 25.11)
SKIP |= set(range(0x17ea44, 0x17ea5c, 4)) | set(range(0x1373b0, 0x1373d0, 4))


def unit(a):
    for lo, hi, n in BLOCKS:
        if lo <= a < hi: return n
    return SINGLE.get(a)


def script_writes(w):
    out = []; i = 0
    while i < len(w):
        h = w[i]; n = h >> 16; op = h & 0xffff; a = w[i + 1:i + n]
        if n == 0 or op == 0x16: break
        if op == 0x21: out += list(zip(a[0::2], a[1::2]))
        i += n
    return out


def main():
    trace, scr, outdir = sys.argv[1:4]
    os.makedirs(outdir, exist_ok=True)
    cat = ['xz', '-dc', trace] if trace.endswith('.xz') else ['cat', trace]
    p = subprocess.Popen(cat, stdout=subprocess.PIPE); bar = None
    for raw in p.stdout:
        if raw.startswith(b'MAP '):
            f = raw.split()
            if int(f[5], 16) == 0x1000000: bar = int(f[3], 16); break
    p.kill()
    if bar is None: sys.exit('в записи нет строки MAP с BAR0 (16 МБ)')
    scripts = sorted(json.load(open(scr)), key=lambda s: s['t'])
    ev = []                                   # (время, порядок, вид, адрес, значение)
    p = subprocess.Popen(cat, stdout=subprocess.PIPE)
    for raw in p.stdout:
        if raw[:2] not in (b'W ', b'R '): continue
        f = raw.split()
        try: a = int(f[4], 16) - bar; v = int(f[5], 16); t = float(f[2])
        except (ValueError, IndexError): continue
        if 0 <= a < 0x1000000 and unit(a): ev.append((t, 0, chr(raw[0]), a, v))
    for s in scripts:
        for k, (a, v) in enumerate(script_writes(s['words'])):
            if unit(a): ev.append((s['t'] + 1e-6 * (k + 1), 1, 'S', a, v))
    ev.sort()
    st = {}; info = collections.defaultdict(lambda: {'host': 0, 'script': 0, 'read': 0}); moments = []
    marks = sorted([(s['t'] - 0.025, 'до', i) for i, s in enumerate(scripts)] + [(s['t'] + 0.060, 'после', i) for i, s in enumerate(scripts)])
    mi = 0

    def level():
        if (st.get(0x137360, 0) & 3) == 2:
            c = st.get(0x132004, 0); r = st.get(0x137330, 0); P, N, M = (c >> 16) & 0x3f, (c >> 8) & 0xff, c & 0xff
            ref = 3240000 // (((r >> 8 if st.get(0x137320, 0) & 0x100 else r) & 0x3f) + 2) if r & 0x80000000 else 1620000
            return f'{ref * N // M // P // 1000 if M and P else 0} МГц, PLL'
        if st.get(0x1373f0, 0) & 2: return 'PLL (GDDR5)'
        if 0x137310 not in st: return 'делитель, частота не известна (0x137310 в записи ещё не встречался)'
        return f'{3240 // (((st[0x137310] >> 8) & 0x3f) + 2)} МГц, делитель'

    for t, _, k, a, v in ev:
        while mi < len(marks) and marks[mi][0] <= t:
            mt, what, i = marks[mi]; mi += 1
            moments.append({'t': round(mt, 6), 'script': i, 'nwords': scripts[i]['nwords'], 'when': what, 'memory': level(),
                            'state': {'%06x' % x: y for x, y in sorted(st.items())}})
        if k == 'R':
            info[a]['read'] += 1
            if a not in st: st[a] = v          # значение, которое NVIDIA прочитала до первой своей записи
        else:
            st[a] = v; info[a]['script' if k == 'S' else 'host'] += 1
    while mi < len(marks):
        mt, what, i = marks[mi]; mi += 1
        moments.append({'t': round(mt, 6), 'script': i, 'nwords': scripts[i]['nwords'], 'when': what, 'memory': level(),
                        'state': {'%06x' % x: y for x, y in sorted(st.items())}})
    addrs = sorted(a for a in info if a not in SKIP)
    with open(os.path.join(outdir, 'addrs.txt'), 'w') as f:
        f.write('# адреса для lab/memstate-dump.py: регистры, которые драйвер NVIDIA сам пишет или читает (BAR0 %#x)\n' % bar)
        for a in addrs:
            i = info[a]; f.write('%06x  # %s; записей хоста %d, из скриптов %d, чтений %d\n' % (a, unit(a), i['host'], i['script'], i['read']))
    json.dump({'bar0': '%#x' % bar, 'moments': moments,
               'regs': {'%06x' % a: dict(unit=unit(a), **info[a]) for a in sorted(info)}}, open(os.path.join(outdir, 'nvidia-state.json'), 'w'))
    print(f'BAR0 {bar:#x}; регистров {len(info)}, в списке для снимка {len(addrs)}; скриптов памяти {len(scripts)}')
    for m in moments:
        print(f'  {m["t"]:10.3f} с  скрипт {m["script"]:2d} ({m["nwords"]} слов), {m["when"]:5s}: память {m["memory"]}')


if __name__ == '__main__':
    if len(sys.argv) < 4: print(open(__file__).read().split('\nimport')[0]); sys.exit(1)
    main()
