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
# Если после переключения память не на ожидаемой частоте — служба перестаёт переключать и пишет об этом в журнал.
import glob, mmap, os, struct, sys, time

UP_MAX, UP_MID = 50, 15
DOWN_MAX, HOLD_MAX = 15, 15
DOWN_MID, HOLD_MID = 5, 30
MIN_DWELL = 5
MEM = {'03': 135, '07': 324, '0f': 2004}
CFG = [(0x10a514, 0x00000070), (0x10a51c, 2), (0x10a534, 0x00180001), (0x10a53c, 2),
       (0x10a544, 0x00000080), (0x10a54c, 2), (0x10a554, 0x20000000), (0x10a55c, 2), (0x10a57c, 3)]
PARAMS = {  # всё, что нашли 20.10: PLL как у NVIDIA, память скриптами NVIDIA, узлы по таблице, PCIe не трогаем
    'lab_pcie': '0', 'lab_core': '1', 'lab_volt_first': '1', 'lab_volt_min_uv': '0', 'lab_eng_mask': '65535',
    'lab_gpc_khz': '0', 'lab_rop_khz': '0', 'lab_hub07_khz': '0', 'lab_hub06_khz': '0', 'lab_hub01_khz': '0',
    'lab_gpc_fix': '0', 'lab_gpc_coef': '0', 'lab_gpc_ref_khz': '0', 'lab_gpc_seq': '13',
    'lab_mem_replay': '15', 'lab_mem_order': '1', 'lab_mem': '1',
    'lab_mem_op13': '1',   # 21.10: операция 0x13 скрипта E — 1 мкс, а не 1 мс (иначе недобор дисплея на 07 -> 03, опыт flicker)
}

def log(msg):
    print(msg, flush=True)

def main():
    prm = '/sys/module/nouveau/parameters'
    if not os.path.exists(prm + '/lab_mem_replay'):
        log('Нет лабораторного драйвера с lab_mem_replay — выхожу, ничего не трогаю'); return 1
    for k, v in PARAMS.items():
        if not os.path.exists(f'{prm}/{k}'):
            log(f'нет параметра {k} в драйвере — пропускаю'); continue
        with open(f'{prm}/{k}', 'w') as f:
            f.write(v)
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
    last = time.monotonic(); hi = mid = 0; low_s = 0
    prev = [cnt(1), cnt(3), cnt(7)]
    while True:
        time.sleep(1.0)
        now = [cnt(1), cnt(3), cnt(7)]
        d = [(now[i] - prev[i]) & 0x7fffffff for i in range(3)]
        prev = now
        load = 100 * max(d[0], d[1]) // max(d[2], 1)
        hi = hi + 1 if load >= UP_MAX else 0
        mid = mid + 1 if load >= UP_MID else 0
        if cur == '0f':
            low_s = low_s + 1 if load < DOWN_MAX else 0
        else:
            low_s = low_s + 1 if load < DOWN_MID else 0
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
    sys.exit(main())
