#!/usr/bin/env python3
# ВНУТРЕННИЕ СИГНАЛЫ ЧИПА ПО СЧЁТЧИКАМ PCOUNTER (28.11.2026). Только чтение.
# В чипах Fermi есть блок наблюдения PCOUNTER (0x180000–0x1bffff; описание — envytools, docs/hw/pcounter): в каждом
# его «домене» 16 регистров SIG_STATUS показывают текущие уровни внутренних сигналов активности (по 32 сигнала в
# регистре). Домены есть у центральной части графического блока (HUB, 8 штук), у каждой части GPC и у каждого раздела
# памяти (PART). Имена известны у малой части сигналов; утилита имён не знает и работает с номерами.
# Зачем: при зависании «быстрые хаб и шина над памятью 135 МГц» графический блок перестаёт забирать команды. Сигнал,
# который под нагрузкой переключается, а при зависании замер в одном положении, показывает место остановки.
#
# ИТОГ ПЕРВОГО ЗАПУСКА (28.11, наша GF114, results/hang-20261128-1208): без настройки прибор почти ничего не показывает.
#   В доменах HUB и PART стоят один-два неизменных бита и один бит (11), который под нагрузкой переключается во всех
#   доменах сразу; сигналы частей блока идут через переключатели (MUX) самих частей, которые надо сначала выбрать
#   записью — это уже не «только чтение». Домены GPC не читаются: каждое чтение даёт ошибку шины (значение 0, а не
#   признак ошибки, поэтому проба их пропустила). Снимок под нагрузкой с этими ошибочными чтениями совпал с зависанием
#   на 2-й секунде (обычно 12–34 с) — возможно, сам его и вызвал. Из сценария стоянки прибор убран. Домены GPC читать
#   нельзя; пользоваться прибором дальше — только после разбора переключателей, отдельным решением.
#
#   sudo python3 -I lab/sigsnap.py probe            — один раз на живой карте в покое: какие домены читаются. Пустые
#                                                      адреса дают в журнале ядра строку об ошибке шины (безвредно);
#                                                      список рабочих доменов пишется в results/sigsnap-domains.json
#   sudo python3 -I lab/sigsnap.py snap [N=400]     — N чтений всех рабочих доменов; на каждый регистр строка:
#                                                      домен регистр  биты_всегда_1  биты_менявшиеся
#   python3 -I lab/sigsnap.py diff ПОКОЙ НАГРУЗКА ЗАВИСАНИЕ   — сигналы, которые под нагрузкой менялись, а при
#                                                      зависании стоят; и те, что стоят в положении, какого нет в покое
import glob, json, mmap, os, struct, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
LIST = os.path.join(os.path.dirname(HERE), 'results', 'sigsnap-domains.json')


def card():
    for d in glob.glob('/sys/bus/pci/devices/*'):
        try:
            if open(d + '/vendor').read().strip() == '0x10de' and open(d + '/class').read().startswith('0x03'):
                return d
        except OSError:
            pass


def open_bar():
    dev = card()
    if not dev: sys.exit('Карта NVIDIA не найдена.')
    try:
        fd = os.open(dev + '/resource0', os.O_RDONLY | os.O_SYNC)
        bar = mmap.mmap(fd, 16 << 20, mmap.MAP_SHARED, mmap.PROT_READ)
    except OSError as e:
        sys.exit(f'Не могу открыть регистры карты ({e}). Нужен sudo.')
    return lambda a: struct.unpack_from('<I', bar, a)[0]


def domains(rd):
    """все домены по описанию envytools (gf100_pcounter.xml): имя -> базовый адрес"""
    ngpc = rd(0x409604) & 0x1f
    nprt = rd(0x022438) & 0x1f
    out = {}
    for d in range(8): out[f'HUB{d}'] = 0x1b0000 + d * 0x200
    # домены GPC (0x180000 + g * 0x1000 + d * 0x200) не читаются: ошибка шины на каждом чтении (28.11) — исключены
    for p in range(nprt):
        for d in range(8): out[f'PART{p}.{d}'] = 0x1a0000 + p * 0x1000 + d * 0x200
    return out


def bad(v):
    return (v & 0xfff00000) == 0xbad00000


def probe(rd):
    chip = (rd(0) >> 20) & 0x1ff
    if not 0xc0 <= chip < 0xe0: sys.exit('Утилита написана для Fermi.')
    if not rd(0x000200) & 0x10000000: sys.exit('Блок PCOUNTER выключен (бит 28 регистра 0x000200).')
    ok = {}
    for name, base in domains(rd).items():
        v = [rd(base + 4 * i) for i in range(16)]
        if any(bad(x) for x in v):
            print(f'{name:9} {base:06x}: не читается ({v[0]:08x})')
            continue
        ok[name] = base
        print(f'{name:9} {base:06x}: ' + ' '.join(f'{x:08x}' for x in v))
    os.makedirs(os.path.dirname(LIST), exist_ok=True)
    json.dump(dict(chip=chip, domains=ok), open(LIST, 'w'), indent=1)
    print(f'рабочих доменов {len(ok)} -> {LIST}')


def snap(rd, n):
    try: doms = json.load(open(LIST))['domains']
    except OSError: sys.exit('Сначала: sudo python3 -I lab/sigsnap.py probe (на живой карте в покое)')
    regs = [(name, i, base + 4 * i) for name, base in doms.items() for i in range(16)]
    ones = [0xffffffff] * len(regs); anyone = [0] * len(regs)
    t0 = time.time()
    for k in range(n):
        for j, (_, _, a) in enumerate(regs):
            v = rd(a); ones[j] &= v; anyone[j] |= v
        time.sleep(0.0007 + (k % 5) * 0.0002)
    print(f'### сигналы PCOUNTER: {time.strftime("%F %T")}, чтений {n} за {time.time() - t0:.1f} с, доменов {len(doms)}; '
          f'занятость блока 0x400700={rd(0x400700):08x}, движок GR в FIFO 0x002640={rd(0x002640):08x}')
    for j, (name, i, a) in enumerate(regs):
        tog = anyone[j] & ~ones[j]
        if ones[j] or tog:
            print(f'{name:9} {i:2} {ones[j]:08x} {tog:08x}')


def load(fn):
    d = {}
    for line in open(fn):
        p = line.split()
        if len(p) == 4 and not line.startswith('#'):
            try: d[(p[0], int(p[1]))] = (int(p[2], 16), int(p[3], 16))
            except ValueError: pass
    return d


def bits(m): return ' '.join(str(b) for b in range(32) if m >> b & 1)


def diff(idle, loadf, hung):
    I, L, H = load(idle), load(loadf), load(hung)
    print('Сигнал: домен, регистр, бит. «Менялся» — за время снимка был и 0, и 1.')
    print('\n1) Под нагрузкой МЕНЯЛИСЬ, при зависании СТОЯТ (место, где работа прекратилась):')
    for k in sorted(set(L) | set(H)):
        lt = L.get(k, (0, 0))[1]; h1, ht = H.get(k, (0, 0))
        stuck = lt & ~ht
        if stuck:
            print(f'  {k[0]:9} рег. {k[1]:2}: стоят в 1 — биты [{bits(stuck & h1)}]; стоят в 0 — биты [{bits(stuck & ~h1)}]')
    print('\n2) При зависании стоят в 1, а в покое стояли в 0 (кто-то держит запрос или занятость):')
    for k in sorted(H):
        h1 = H[k][0]; i1, it = I.get(k, (0, 0))
        m = h1 & ~i1 & ~it
        if m: print(f'  {k[0]:9} рег. {k[1]:2}: биты [{bits(m)}]')
    print('\n3) При зависании МЕНЯЮТСЯ (что ещё живо):')
    for k in sorted(H):
        if H[k][1]: print(f'  {k[0]:9} рег. {k[1]:2}: биты [{bits(H[k][1])}]')


def main():
    a = sys.argv[1:]
    if not a or a[0] not in ('probe', 'snap', 'diff'): sys.exit('probe | snap [N] | diff ПОКОЙ НАГРУЗКА ЗАВИСАНИЕ')
    if a[0] == 'diff': return diff(*a[1:4])
    rd = open_bar()
    if a[0] == 'probe': return probe(rd)
    snap(rd, int(a[1]) if len(a) > 1 else 400)


if __name__ == '__main__':
    main()
