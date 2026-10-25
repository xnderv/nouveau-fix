#!/usr/bin/env python3
# GPU-AUTOCLOCK для GTX 560 Ti (GF114) на лабораторном nouveau: режимы 03 / 07 / 0f по загрузке, как у NVIDIA.
# Загрузка — АППАРАТНЫЕ СЧЁТЧИКИ контроллера PMU, настроенные так же, как их настраивает драйвер NVIDIA 390
# на этой карте (запись 20.10): счётчик 3 — графика + копирование, счётчик 1 — видео, счётчик 7 — все такты.
# Раз в секунду читаются три счётчика; загрузка = больше из (графика, видео) / все такты. nouveau эти счётчики не использует.
# Переключение — запись режима в /sys/kernel/debug/dri/*/pstate; память меняется повтором скриптов NVIDIA.
# Правила (секунды — подряд идущие секунды):
#   вверх в 0f:  загрузка >= UP_MAX % два раза подряд (из 03 или 07)
#   03 -> 07:    загрузка >= UP_MID % два раза подряд
#   0f -> 07:    загрузка <  DOWN_MAX % в течение HOLD_MAX с
#   07 -> 03:    загрузка <  DOWN_MID % в течение HOLD_MID с
#   после любого переключения — не меньше MIN_DWELL с в новом режиме.
# Посекундная запись загрузки (только для опытов): пока существует файл /run/gpu-autoclock.debug.
# После сна (S3) настройки счётчиков сбрасываются — служба замечает это и ставит их заново (21.10).
# Если после переключения память не на ожидаемой частоте — служба перестаёт переключать и пишет об этом в журнал.
# 21.10, ступень 2в: если в драйвере есть регулятор (lab_gov, патч 0004), РЕШАЕТ ДРАЙВЕР, как у NVIDIA:
# прошивка PMU считает загрузку, драйвер раз в секунду спрашивает итог и переключает по тем же правилам.
# Служба тогда только выставляет параметры, ставит стартовый 07, включает регулятор (с 22.10 — с температурным
# тормозом: >= 90 °C не выше 07, >= 95 °C — 03) и спит; при остановке
# службы регулятор выключается (режим остаётся как есть). Вернуть решение службе: создать файл
# /etc/gpu-autoclock.legacy и перезапустить службу.
import glob, mmap, os, struct, sys, time

UP_MAX, UP_MID = 50, 15
DOWN_MAX, HOLD_MAX = 15, 15
DOWN_MID, HOLD_MID = 5, 30
MIN_DWELL = 5
MEM = {'03': 135, '07': 324, '0f': 2004}
CFG = [(0x10a514, 0x00000070), (0x10a51c, 2), (0x10a534, 0x00180001), (0x10a53c, 2),
       (0x10a544, 0x00000080), (0x10a54c, 2), (0x10a554, 0x20000000), (0x10a55c, 2), (0x10a57c, 3)]
PARAMS = {  # всё, что нашли 20.10: PLL как у NVIDIA, память скриптами NVIDIA, узлы по таблице, PCIe не трогаем
    'lab_core': '1', 'lab_volt_first': '1', 'lab_volt_min_uv': '0', 'lab_eng_mask': '65535',
    'lab_gpc_khz': '0', 'lab_rop_khz': '0', 'lab_hub07_khz': '0', 'lab_hub06_khz': '0', 'lab_hub01_khz': '0',
    'lab_gpc_fix': '0', 'lab_gpc_coef': '0', 'lab_gpc_ref_khz': '0', 'lab_gpc_seq': '13',
    'lab_mem_replay': '15', 'lab_mem_order': '1', 'lab_mem': '1',
    'lab_mem_op13': '1',   # 21.10: операция 0x13 скрипта E — 1 мкс, а не 1 мс (иначе недобор дисплея на 07 -> 03, опыт flicker)
    'lab_mem_op34': '1',   # 22.10: после паузы вывода ждать его остановки (0x611200 & 3 == 0), как gt215; опыт op34test 12/12 чисто
    'lab_pcie': '1',       # 22.10: шина как у NVIDIA (5 GT/s на 0f). Подозрение 15:40 (обрыв шины по дампу) снято опытами
                           # 16:11–16:37: 80 переключений под потоком по шине, с загрузкой CPU и снимками — ошибок 0,
                           # флаг CorrErr на 5 GT/s не взводится (pcistress.sh, pciehold.sh). 2 — один раз 5 GT/s, 3 — последовательность NVIDIA.
    # 24.10: боевая конфигурация по тестам 13–24 (docs/2026-10-23/hang-20261023-1802.md, docs/2026-10-24/nvidia-vs-lab-map.md)
    'lab_therm': '1',        # скобка замедлителя PTHERM вокруг смены такта GPC и hubk06, как NVIDIA (07↔0f без неё висло 7/7)
    'lab_therm_wait': '1',   # выход из скобки по аппаратному признаку FSRM_STATUS, без выдержки по времени
    'lab_therm_wait_us': '0',
    'lab_therm_real': '0',   # скобка на каждом вызове стадий 1/3 (пустые скобки есть и у NVIDIA)
    'lab_therm_div': '1',    # скобка и вокруг пост-делителей GPC/hubk06 (у NVIDIA 104,511)
    'lab_clk_mmu_lock': '0', # блокировка MMU на время стадий не нужна: все тесты 22–24 шли без неё
    'lab_gpc_div': '1',      # GPC на 03 на делителе (101,25 МГц), а не на PLL, как NVIDIA: 03↔07 180/180 (тесты 22, 23)
    'lab_pmu_div': '1',      # PMU 202,5 МГц, как BIOS/NVIDIA, а не 216: тесты 23, 24 по 60/60
    'lab_nv_div_late': '1',  # 25.10: делитель ядра меняется внутри скобки прямо перед переключателем, как NVIDIA: в плохой
                             # сессии тайм-аутов переключателя нет (тесты 55, 56: 0 на 2400+; без этого ~1–2 %)
    'lab_mux_guard': '1',    # 25.10: если переключатель всё-таки застрял — повторы, PLL и напряжение не трогать (страховка)
}
# 25.10 (тест 54, гипотеза «линии»): поле B делителей ядра, ROP и hubk07 с самой загрузки не затирать — держать значение,
# которое ставит VBIOS при включении (1e у ядра, 0a у ROP/hubk07), как NVIDIA и как nouveau для Kepler с 2014. Ставится
# до первого переключения. Включается файлом /etc/gpu-autoclock.divb, выключается его удалением; со следующей загрузки.
DIVB_FLAG = '/etc/gpu-autoclock.divb'
if os.path.exists(DIVB_FLAG):
    PARAMS['lab_nv_divb'] = '1'

def log(msg):
    print(msg, flush=True)

DRY = os.environ.get('GPU_AUTOCLOCK_DRY') == '1'   # проверка сторожа без уведомлений: печатать вместо отправки

def say(title, body, urgency='normal'):
    """Уведомление на рабочий стол всем вошедшим пользователям (без ожидания сеанса); всегда — строка в журнал службы.
    False — некому показать (никто не вошёл или сеанс моложе 30 с): сторож отложит уведомление."""
    import subprocess, pwd
    log(f'уведомление: {title} — {body}')
    if DRY:
        return True
    shown = False
    for b in glob.glob('/run/user/*/bus'):
        st = os.stat(b)
        if st.st_uid < 1000 or time.time() - st.st_mtime < 30:
            continue
        pw = pwd.getpwuid(st.st_uid)
        n = os.path.join(pw.pw_dir, 'Home/nouveau-fix/daily/notify-gpu.sh')
        if os.access(n, os.X_OK):
            subprocess.run(['sudo', '-u', pw.pw_name, 'env', f'DBUS_SESSION_BUS_ADDRESS=unix:path={b}',
                            f'XDG_RUNTIME_DIR=/run/user/{st.st_uid}', 'setsid', '-f', n, title, body, urgency],
                           stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            shown = True
    return shown

# 25.10: сторож. Новые строки nouveau уровня «предупреждение» и выше в журнале ядра — уведомление (так видно и то, чего мы
# заранее не знаем); рост счётчика тайм-аутов переключателя ядра — отдельное уведомление; сводка через 15 мин после старта
# и потом раз в сутки. Одинаковые строки (без чисел) — не чаще раза в 10 мин, всего не больше 6 уведомлений в час.
# Уведомлением не показываются, но считаются в сводке как известные:
#   строки, которые были при каждой из 13 загрузок 22–25.10 (нет прошивок видеодекодера и копировщика; ловушка графики
#   RT_HEIGHT_OVERRUN от пробы gst-plugin-scan при входе в сеанс — известна с 21.10, к частотам отношения не имеет);
#   строки стека после WARNING;
#   строки защиты переключателя (LAB mux, mux_guard) и WARNING ожидания переключателя — за таким WARNING в пределах 0,5 с
#   идёт строка LAB mux / mux_guard; об этих событиях говорит уведомление по счётчику.
WATCH_BOOT = ('loading out-of-tree module taints kernel', 'msvld:', 'nvce_fuc084', 'failed to create ce channel',
              'module verification failed')
WATCH_GST = 'gst-plugin-scan'
WATCH_MUX = ('LAB mux', 'mux_guard')
WATCH_TRACE = r'\s|(Workqueue|Call Trace|RIP|Modules linked in|CPU|Hardware name|Code|Tainted|R[0-9A-Z]{1,2}):|</?TASK>'
WATCH_STEP, WATCH_SAME, WATCH_HOUR, WATCH_FIRST, WATCH_DAY, WATCH_LAG = 10, 600, 6, 900, 86400, 2

def watch_lines(since, until):
    """Строки nouveau уровня warning и выше в журнале ядра этой загрузки, since < время <= until (unix-время).
    Возвращает (новые [(время, текст)], сколько известных пропущено, строки защиты переключателя [(время, текст)])."""
    import subprocess, re
    args = ['journalctl', '-k', '-b', '0', '-p', 'warning', '-o', 'short-unix', '--no-pager']
    if since:
        args += ['--since', f'@{since:.6f}']
    lines = []
    for l in subprocess.run(args, capture_output=True, text=True).stdout.splitlines():
        m = re.match(r'(\d+\.\d+) \S+ kernel: (.*)', l)
        if m and float(m.group(1)) > since:
            lines.append((float(m.group(1)), m.group(2)))
    new, known, mux, gst = [], 0, [], -1e9
    for i, (t, text) in enumerate(lines):
        if t > until:
            break   # ещё рано: строки защиты после WARNING могут не успеть попасть в журнал
        if 'nouveau' not in text or re.match(WATCH_TRACE, text):
            continue
        if WATCH_GST in text:
            gst = t
        if any(s in text for s in WATCH_MUX):
            mux.append((t, text))
        elif (any(s in text for s in WATCH_BOOT) or WATCH_GST in text or (t - gst < 1 and 'trap:' in text)
              or text.endswith(': timeout')   # первая строка WARNING ожидания; место — в следующей строке WARNING
              or (text.startswith('WARNING:') and any(any(s in x for s in WATCH_MUX)
                                                      for t2, x in lines[i + 1:i + 200] if t2 - t <= 0.5))):
            known += 1
        else:
            new.append((t, text))
    return new, known, mux

def watch(prm, once=False):
    import re, subprocess
    seen_t = 0.0; last_key = {}; sent = []; held = 0; shown = 0; known = 0; mux_l = []; pend = []; mux_t = -1e9
    rd = lambda p: open(f'{prm}/{p}').read().strip() if os.path.exists(f'{prm}/{p}') else ''
    mux = mux_prev = int(rd('lab_mux_timeouts') or -1)
    next_sum = time.time() + WATCH_FIRST
    log(f'сторож включён: предупреждения nouveau в журнале ядра, тайм-ауты переключателя (сейчас {mux}), сводка раз в сутки')

    def tell(*a):
        if pend or not say(*a):
            pend.append(a)
            log(f'  никто не вошёл в сеанс — отложено (в очереди {len(pend)})')

    while True:
        now = time.time()
        if pend and say(*pend[0]):
            for a in pend[1:10]:
                say(*a)
            if len(pend) > 10:
                say('GTX 560 Ti: ещё сообщения nouveau', f'ещё {len(pend) - 10} отложенных не показано — '
                    'полный список: journalctl -k -b -p warning | grep nouveau')
            pend.clear()
        sent = [t for t in sent if now - t < 3600]
        mux_now = int(rd('lab_mux_timeouts') or -1)
        first = not seen_t
        new, k, ml = watch_lines(seen_t, now if once else now - WATCH_LAG)
        seen_t = now if once else now - WATCH_LAG; known += k
        mux_l = (mux_l + ml)[-50:] if not first else []   # первый проход: старые события уже в счётчике
        for t, text in new:
            shown += 1
            key = re.sub(r'[0-9a-fA-F]{4,}|\d+', '#', text)
            if now - last_key.get(key, -1e9) < WATCH_SAME or len(sent) >= WATCH_HOUR:
                held += 1; continue
            last_key[key] = now; sent.append(now)
            tell('GTX 560 Ti: сообщение драйвера nouveau', time.strftime('%H:%M:%S ', time.localtime(t)) + text[:300])
        if held and len(sent) < WATCH_HOUR:
            sent.append(now)
            tell('GTX 560 Ti: ещё сообщения nouveau', f'{held} похожих или сверх 6 в час не показано — '
                 'полный список: journalctl -k -b -p warning | grep nouveau')
            held = 0
        # счётчик, прочитанный на прошлом проходе: строки защиты к этому моменту уже в журнале и прочитаны
        grown = (mux_now if once else mux_prev) - mux
        if mux >= 0 and grown > 0 and now - mux_t >= WATCH_SAME:   # не чаще раза в 10 мин, рост копится
            txt = ' '.join(x for _, x in mux_l)
            how = ('Повторы не помогли: ядро оставлено на PLL, напряжение не снижено — до следующего перехода.'
                   if 'ОСТАЛСЯ НА PLL' in txt else 'Повтор помог: ядро перешло на делитель.' if 'ушёл на делитель' in txt
                   else 'Защита выключена (lab_mux_guard=0).' if rd('lab_mux_guard') == '0' else '')
            tell('GTX 560 Ti: тайм-аут переключателя ядра', f'{time.strftime("%H:%M:%S")}: +{grown}, всего с загрузки '
                 f'{mux + grown}. {how} Подробно: journalctl -k -b | grep "LAB mux"')
            mux += grown; mux_l.clear(); mux_t = now
        mux_prev = mux_now
        if now >= next_sum or once:
            sw = len(re.findall(r'LAB pstate \d: flags', subprocess.run(
                ['journalctl', '-k', '-b', '0', '-o', 'cat', '--no-pager'], capture_output=True, text=True).stdout))
            tell('GTX 560 Ti: сводка драйвера', f'С загрузки: переключений уровней {sw}, тайм-аутов переключателя ядра '
                 f'{mux_now if mux_now >= 0 else "нет счётчика"}; сообщений nouveau (предупреждения и ошибки): новых '
                 f'{shown}, известных {known} (известные не показываются).', 'low')
            next_sum = now + WATCH_DAY
        if once:
            return
        time.sleep(WATCH_STEP)

def notify(mode, tries=60):
    """Уведомление с кнопкой «Подготовить драйвер» всем вошедшим пользователям; ждёт сеанс до tries×10 с."""
    import subprocess, pwd
    for _ in range(tries):
        sent = False
        for b in glob.glob('/run/user/*/bus'):
            st = os.stat(b)
            if st.st_uid < 1000:
                continue
            pw = pwd.getpwuid(st.st_uid)
            n = os.path.join(pw.pw_dir, 'Home/nouveau-fix/daily/notify-newkernel.sh')
            if not os.access(n, os.X_OK):
                continue
            r = subprocess.run(['sudo', '-u', pw.pw_name, 'env', f'DBUS_SESSION_BUS_ADDRESS=unix:path={b}',
                                f'XDG_RUNTIME_DIR=/run/user/{st.st_uid}', 'setsid', '-f', n, mode, os.uname().release],
                               stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            sent = sent or r.returncode == 0
        if sent:
            return True
        time.sleep(10)
    return False

def main():
    prm = '/sys/module/nouveau/parameters'
    if not os.path.exists(prm + '/lab_mem_replay'):
        m = (f'Загружен не наш драйвер nouveau (ядро {os.uname().release}): частоты не управляются, карта на стартовых. '
             'Если это новое ядро: ~/Home/nouveau-fix/newkernel.sh и перезагрузка.')
        log('Нет лабораторного драйвера с lab_mem_replay — ничего не трогаю. ' + m)
        notify('notloaded')
        return 1
    for k, v in PARAMS.items():
        if not os.path.exists(f'{prm}/{k}'):
            log(f'нет параметра {k} в драйвере — пропускаю'); continue
        with open(f'{prm}/{k}', 'w') as f:
            f.write(v)
    if 'lab_nv_divb' in PARAMS:
        log(f'есть {DIVB_FLAG}: lab_nv_divb=1 до первого переключения — поле B делителей остаётся как при включении')
    ps = sorted(glob.glob('/sys/kernel/debug/dri/*/pstate'))
    if not ps:
        log('Нет /sys/kernel/debug/dri/*/pstate — выхожу'); return 1
    ps = ps[0]
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

    def wr(a, v):
        struct.pack_into('<I', bar, a, v)
    for a, v in CFG:
        wr(a, v)
    log('счётчики PMU настроены как у NVIDIA: ' + ' '.join(f'{a:06x}={rd(a):08x}' for a, _ in CFG))
    cnt = lambda i: rd(0x10a508 + i * 0x10) & 0x7fffffff

    def ac():
        for l in open(ps):
            if l.startswith('AC'):
                return l.strip()
        return ''

    def setp(p, why):
        t0 = time.monotonic()
        with open(ps, 'w') as f:
            f.write(p)
        a = ac()
        ok = f'memory {MEM[p]} MHz' in a
        log(f'-> {p} ({why}): {a} за {int((time.monotonic() - t0) * 1000)} мс' + ('' if ok else '  !!! память не та'))
        return ok

    cur = '07'
    if not setp(cur, 'старт'):
        log('СТОП: стартовое переключение не удалось, дальше не переключаю'); return 2

    legacy = os.path.exists('/etc/gpu-autoclock.legacy')
    if os.path.exists(prm + '/lab_gov') and not legacy:
        import signal

        def drv(vals):
            for k, v in vals:
                with open(f'{prm}/{k}', 'w') as f:
                    f.write(v)

        def stop(sig, frm):
            drv([('lab_gov', '0'), ('lab_perf_ms', '0')])
            log('служба остановлена — регулятор в драйвере выключен, режим остаётся как есть')
            sys.exit(0)
        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)
        for k, v in (('lab_gov_hot', '90'), ('lab_gov_crit', '95'), ('lab_gov_hyst', '5')):   # 22.10: температурный тормоз
            if os.path.exists(f'{prm}/{k}'):
                drv([(k, v)])
        drv([('lab_perf_ticks', '20300000'), ('lab_perf_ms', '1000'), ('lab_perf_log', '0'), ('lab_gov', '2')])
        log('решает ДРАЙВЕР, как у NVIDIA: прошивка PMU считает загрузку, драйвер раз в секунду решает и переключает '
            '(lab_gov=2). Служба только выставила параметры и спит. '
            'Вернуть решение службе: sudo touch /etc/gpu-autoclock.legacy && sudo systemctl restart gpu-autoclock')
        watch(prm)
    if os.path.exists(prm + '/lab_gov'):
        with open(prm + '/lab_gov', 'w') as f:
            f.write('0')
    log('решает служба (старый способ)' + (': есть /etc/gpu-autoclock.legacy' if legacy else ': в драйвере нет регулятора lab_gov'))
    last = time.monotonic(); hi = mid = 0; low_s = 0
    prev = [cnt(1), cnt(3), cnt(7)]
    while True:
        time.sleep(1.0)
        if rd(0x10a57c) != 3:
            # 21.10: после сна (S3) карта обесточивается и настройки счётчиков PMU сбрасываются в 0 —
            # без этого служба видела бы загрузку 0 % и никогда не поднимала режим. Ставим заново, замер пропускаем.
            for a, v in CFG:
                wr(a, v)
            log('счётчики PMU сброшены (было пробуждение после сна?) — настроены заново')
            prev = [cnt(1), cnt(3), cnt(7)]
            continue
        now = [cnt(1), cnt(3), cnt(7)]
        d = [(now[i] - prev[i]) & 0x7fffffff for i in range(3)]
        prev = now
        if d[2] == 0:
            continue
        load = 100 * max(d[0], d[1]) // max(d[2], 1)
        hi = hi + 1 if load >= UP_MAX else 0
        mid = mid + 1 if load >= UP_MID else 0
        if cur == '0f':
            low_s = low_s + 1 if load < DOWN_MAX else 0
        else:
            low_s = low_s + 1 if load < DOWN_MID else 0
        if os.path.exists('/run/gpu-autoclock.debug'):   # 21.10: посекундная запись для сверки с регулятором драйвера
            log(f'загрузка {1000 * max(d[0], d[1]) // max(d[2], 1)}‰ (графика {1000 * d[1] // max(d[2], 1)}‰, видео {1000 * d[0] // max(d[2], 1)}‰) режим {cur} hi {hi} mid {mid} low {low_s}')
        if time.monotonic() - last < MIN_DWELL:
            continue
        nxt = None
        if cur != '0f' and hi >= 2:
            nxt, why = '0f', f'загрузка {load}%'
        elif cur == '03' and mid >= 2:
            nxt, why = '07', f'загрузка {load}%'
        elif cur == '0f' and low_s >= HOLD_MAX:
            nxt, why = '07', f'загрузка < {DOWN_MAX}% {HOLD_MAX} с'
        elif cur == '07' and low_s >= HOLD_MID:
            nxt, why = '03', f'загрузка < {DOWN_MID}% {HOLD_MID} с'
        if nxt:
            if not setp(nxt, why):
                log('СТОП: переключение не удалось, дальше не переключаю (режим оставлен как есть)')
                while True:
                    time.sleep(3600)
            cur = nxt; last = time.monotonic(); hi = mid = low_s = 0

if __name__ == '__main__':
    if sys.argv[1:] == ['--watch-test']:   # один проход сторожа по журналу этой загрузки, без уведомлений и без настройки карты
        DRY = True
        sys.exit(watch('/sys/module/nouveau/parameters', once=True))
    sys.exit(main())
