#!/usr/bin/env python3
# ОПЫТ «МИГАНИЕ ПРИ ПЕРЕХОДАХ»: объективная проверка аппаратным флагом недобора блока вывода изображения.
# У каждой головы дисплея есть REPORT_UNDERFLOW (0x616308 / 0x616b08): бит 0 — отслеживать, бит 4 — «был недобор»
# (залипает, сбрасывается записью 1), бит 8 — режим (0 = повтор точек, 1 = красная заливка; НЕ трогаем, остаётся как было).
# Рядом VERT (0x616340 / 0x616b40): номер строки развёртки и счётчик кадров.
# Ход: служба автопереключения на время опыта останавливается;
#   фаза 0 — 10 с без переходов (фон: бывает ли недобор вообще);
#   фаза 1 — 07 <-> 03 (подозреваемый) N раз;  фаза 2 — 07 <-> 0f N раз (сравнение);
#   в конце — 07, исходные значения регистров отслеживания, служба снова запускается.
# Перед каждым переходом флаг сбрасывается, после — ждём 0,3 с (~18 кадров) и читаем.
# Запуск: sudo python3 ~/Home/nouveau-fix/lab/flicker.py [N=5] [пауза_с=3]
import glob, mmap, os, struct, subprocess, sys, time

N = int(sys.argv[1]) if len(sys.argv) > 1 else 5
GAP = float(sys.argv[2]) if len(sys.argv) > 2 else 3.0
PRM = '/sys/module/nouveau/parameters'
PARAMS = {'lab_pcie': '0', 'lab_core': '1', 'lab_volt_first': '1', 'lab_volt_min_uv': '0', 'lab_eng_mask': '65535',
          'lab_gpc_khz': '0', 'lab_rop_khz': '0', 'lab_hub07_khz': '0', 'lab_hub06_khz': '0', 'lab_hub01_khz': '0',
          'lab_gpc_fix': '0', 'lab_gpc_coef': '0', 'lab_gpc_ref_khz': '0', 'lab_gpc_seq': '13',
          'lab_mem_replay': '15', 'lab_mem_order': '1', 'lab_mem': '1'}
MEM = {'03': 135, '07': 324, '0f': 2004}
UF = [0x616308, 0x616b08]
VERT = [0x616340, 0x616b40]

os.makedirs(os.path.expanduser('~alex/Home/nouveau-fix/results'), exist_ok=True)
LOGF = os.path.expanduser('~alex/Home/nouveau-fix/results/flicker-' + time.strftime('%Y%m%d-%H%M%S') + '.txt')
logf = open(LOGF, 'w')
def ts(): t = time.time(); return time.strftime('%H:%M:%S', time.localtime(t)) + f'.{int(t * 1000) % 1000:03d}'
def say(m):
    line = f'{ts()} {m}'
    print(line, flush=True); logf.write(line + '\n'); logf.flush()

if not os.path.exists(PRM + '/lab_mem_replay'):
    sys.exit('Нет лабораторного драйвера с lab_mem_replay')
ps = sorted(glob.glob('/sys/kernel/debug/dri/*/pstate'))[0]
dev = None
for d in glob.glob('/sys/bus/pci/devices/*'):
    try:
        if open(d + '/vendor').read().strip() == '0x10de' and open(d + '/class').read().startswith('0x03'):
            dev = d; break
    except OSError:
        pass
fd = os.open(dev + '/resource0', os.O_RDWR | os.O_SYNC)
bar = mmap.mmap(fd, 16 << 20, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)
rd = lambda a: struct.unpack_from('<I', bar, a)[0]
def wr(a, v): struct.pack_into('<I', bar, a, v)

def ac():
    for l in open(ps):
        if l.startswith('AC'): return l.strip()
    return ''

heads = rd(0x610050)
active = [h for h in (0, 1) if heads & (2 << (h << 3))]
orig = [rd(a) for a in UF]
say(f'Опыт «мигание». Файл: {LOGF}')
say(f'Активные головы дисплея: {active} (0x610050={heads:08x}); REPORT_UNDERFLOW было: голова0 {orig[0]:08x}, голова1 {orig[1]:08x}'
    f'; режим при недоборе: {["повтор" if not (v & 0x100) else "КРАСНЫЙ" for v in orig]}')

was_active = subprocess.run(['systemctl', 'is-active', '--quiet', 'gpu-autoclock.service']).returncode == 0
if was_active:
    subprocess.run(['systemctl', 'stop', 'gpu-autoclock.service'], check=False)
    say('Служба автопереключения остановлена на время опыта')
for k, v in PARAMS.items():
    with open(f'{PRM}/{k}', 'w') as f: f.write(v)
# SET="имя=значение имя=значение" — переменная опыта (например lab_mem_op13=1); в конце возвращается как было
SETS = [x.split('=', 1) for x in os.environ.get('SET', '').split() if '=' in x]
SAVED = {}
for k, v in SETS:
    if not os.path.exists(f'{PRM}/{k}'):
        sys.exit(f'Нет параметра {k} в драйвере (нужен lab.sh install новой версии)')
    SAVED[k] = open(f'{PRM}/{k}').read().strip()
    with open(f'{PRM}/{k}', 'w') as f: f.write(v)
    say(f'ПЕРЕМЕННАЯ ОПЫТА: {k} = {open(f"{PRM}/{k}").read().strip()} (было {SAVED[k]})')
if os.path.exists(f'{PRM}/lab_mem_op13'):
    say(f'lab_mem_op13 = {open(f"{PRM}/lab_mem_op13").read().strip()}')
PHASES = os.environ.get('PHASES', '12')

def uf_set(enable):
    # бит 0 — отслеживать, бит 4 — сбросить флаг (запись 1), режим (бит 8) как был
    for i, a in enumerate(UF):
        wr(a, (orig[i] & 0x100) | 0x10 | (0x1 if enable else 0))
def watch(sec, fresh=True):
    """Отслеживание включено на sec секунд; флаг читается каждые 20 мс и СРАЗУ сбрасывается
    (иначе блок вывода держит испорченную картинку до сброса). Возвращает число срабатываний по головам."""
    hits = [0, 0]
    if fresh:
        uf_set(True)        # включить и сбросить флаг; при fresh=False флаг НЕ сбрасываем — читаем то, что успело взвестись
    end = time.monotonic() + sec
    while True:
        for i, a in enumerate(UF):
            if (rd(a) >> 4) & 1:
                hits[i] += 1
                wr(a, (orig[i] & 0x100) | 0x11)
        if time.monotonic() >= end:
            break
        time.sleep(0.02)
    uf_set(False)
    return hits
def frames():
    return [rd(a) >> 16 for a in VERT]

def setp(p):
    t0 = time.monotonic()
    with open(ps, 'w') as f: f.write(p)
    dt = (time.monotonic() - t0) * 1000
    a = ac()
    return dt, (f'memory {MEM[p]} MHz' in a), a

def step(frm, to, k, tot):
    pre = watch(0.3)                     # фон за 0,3 с ДО перехода
    print(f'\n>>>>>>>>>>  СЕЙЧАС: {frm} → {to}   ({k}/{tot})  <<<<<<<<<<', flush=True)
    f0 = frames()
    uf_set(True)
    TRANS.append((time.time(), f'{frm} → {to} №{k}'))
    dt, ok, a = setp(to)
    post = watch(0.3, fresh=False)     # отслеживание включено ДО перехода; флаг, взведённый во время перехода, не стираем
    f1 = frames()
    mark = ' '.join(f'голова{h}: {"НЕДОБОР ×" + str(post[h]) if post[h] else "чисто"}' for h in active)
    bg = ' (фон до перехода: ' + ('НЕДОБОР' if any(pre[h] for h in active) else 'чисто') + ')'
    say(f'{frm} → {to} №{k}: {mark}{bg} | {dt:.0f} мс | кадров за 0,3 с: {[(f1[i] - f0[i]) & 0xffff for i in active]} | {a.replace("AC: ", "")}{"" if ok else "  !!! ПАМЯТЬ НЕ ТА"}')
    return ok, any(post[h] for h in active)

res = {}
TRANS = []   # (unix-время перехода, название)
T_START = time.time()
MARKS = os.path.expanduser('~alex/Home/nouveau-fix/results/flicker-marks.txt')
try:
    ok, _, a = setp('07')
    say(f'Старт в 07: {a}')
    print('\nСмотри на экран. Заметишь мигание — сразу Ctrl+Alt+M. Через 5 секунд начинаю. Сначала 10 секунд БЕЗ переходов.', flush=True)
    time.sleep(5)
    bg = watch(10)
    say('Фаза 0, 10 с без переходов: ' + ' '.join(f'голова{h}: {"НЕДОБОР" if bg[h] else "чисто"}' for h in active))
    for num, phase, (lo, hi) in (('1', 'Фаза 1: 07 ↔ 03 (подозреваемый)', ('07', '03')), ('2', 'Фаза 2: 07 ↔ 0f (сравнение)', ('07', '0f'))):
        if num not in PHASES:
            continue
        print(f'\n========== {phase}: {N} раз туда и обратно, пауза {GAP:.0f} с ==========', flush=True)
        say(phase)
        for k in range(1, N + 1):
            for frm, to in ((lo, hi), (hi, lo)):
                ok, u = step(frm, to, k, N)
                res.setdefault(f'{frm} → {to}', []).append(u)
                if not ok:
                    raise SystemExit('СТОП: частота памяти не та после перехода')
                time.sleep(GAP)
finally:
    try:
        setp('07')
    except Exception:
        pass
    for i, a in enumerate(UF):
        wr(a, orig[i] & ~0x10)          # вернуть как было (флаг не трогаем)
    try:
        j = subprocess.run(['journalctl', '-k', '--no-pager', '-o', 'short-precise', '--since', time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(T_START))],
                           capture_output=True, text=True).stdout.splitlines()
        jl = [l for l in j if 'выполнен за' in l]
        say(f'Длительность смен памяти по журналу драйвера ({len(jl)} шт.):')
        for l in jl:
            p_ = l.split('LAB replay ')[-1].split('; 0x137310')[0]
            say('  ' + l.split()[2] + ' ' + p_)
    except Exception as e:
        say(f'журнал не прочитан: {e}')
    say('Итог (сколько переходов дали недобор):')
    for k, v in res.items():
        pass
    try:
        marks = []
        for l in open(MARKS):
            p = l.split()
            if len(p) >= 3 and float(p[2]) >= T_START:
                marks.append(float(p[2]))
    except OSError:
        marks = []
    say(f'Отметок «мигнуло» за время опыта: {len(marks)}')
    for m in marks:
        prev = [t for t in TRANS if t[0] <= m]
        tm = time.strftime('%H:%M:%S', time.localtime(m)) + f'.{int(m * 1000) % 1000:03d}'
        if prev:
            t, nm = prev[-1]
            say(f'  отметка {tm}: через {m - t:.1f} с после перехода {nm}')
        else:
            say(f'  отметка {tm}: до первого перехода (фаза без переходов)')
    for k, v in res.items():
        say(f'  {k}: {sum(v)} из {len(v)}')
    for k, v in SAVED.items():
        with open(f'{PRM}/{k}', 'w') as f: f.write(v)
        say(f'{k} возвращён: {v}')
    say(f'Отслеживание недобора возвращено как было: {rd(UF[0]):08x} {rd(UF[1]):08x}')
    if was_active:
        subprocess.run(['systemctl', 'start', 'gpu-autoclock.service'], check=False)
        say('Служба автопереключения снова запущена')
    logf.close()
    try:
        st = os.stat(os.path.dirname(LOGF)); os.chown(LOGF, st.st_uid, st.st_gid)
    except OSError:
        pass
