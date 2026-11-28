#!/usr/bin/env python3
# ГДЕ СТОИТ ПРОШИВКА ГРАФИЧЕСКОГО БЛОКА (28.11.2026). Только чтение.
# При зависании «быстрая шина XBAR над памятью 135 МГц» графический блок (GR) каждый раз застывает на сохранении
# контекста канала; снимок чёрного ящика показывает, что он стоит, но не показывает, на каком шаге. Прошивка nouveau
# для GR (engine/gr/fuc/hub.fuc, com.fuc, gpc.fuc) сама ведёт отметки: в рабочем регистре 7 — биты «что сейчас делаю»,
# в рабочем регистре 6 — номер сигнала готовности, которого она ждёт. Сохранение контекста (ctx_xfer) — шесть ожиданий
# подряд, ни одно без ограничения по времени:
#   1) пока блок не освободится (0x409c00, бит 13);
#   2) подтверждение паузы от блока (0x404160: бит 0 — запрос, бит 4 — подтверждение);
#   3) передача контекста частями блока GPC (сигнал готовности 8 в 0x409400);
#   4) передача списка регистров (сигнал 5);
#   5) передача цепочек состояния («strand», сигнал 2);
#   6) сигнал 12, затем команда записи в память (0x409a10 становится нулём, когда выполнена).
# Утилита читает эти регистры у главной прошивки (FECS/HUB) и у прошивки каждой части GPC, несколько раз подряд, и
# говорит, на каком шаге стоит дело и меняется ли что-нибудь между чтениями.
#   sudo python3 -I lab/grstuck.py [ЧТЕНИЙ=5] [ПАУЗА_С=0.5]
# На работающей карте печатает то же — обычно «ожиданий нет». Адреса — те, с которыми работает сама прошивка nouveau.
import glob, mmap, os, struct, sys, time

FLAGS = ['WAIT (ждёт сигнала готовности)', 'MMCTX (передаёт список регистров)', 'STRWAIT (ждёт цепочки состояния)',
         'STRINIT', 'AUTO (автоматическая смена контекста)', 'CHAN (смена канала)', 'LOAD (загрузка контекста)',
         'SAVE (сохранение контекста)', 'LCHAN', 'LCTXH', 'STRTPC']
SIGNALS = {2: 'цепочки состояния (strand)', 5: 'список регистров (mmctx)', 8: 'части GPC закончили передачу', 12: 'сигнал 12 перед записью в память'}


def card():
    for d in glob.glob('/sys/bus/pci/devices/*'):
        try:
            if open(d + '/vendor').read().strip() == '0x10de' and open(d + '/class').read().startswith('0x03'):
                return d
        except OSError:
            pass


def flags(v):
    return ', '.join(FLAGS[b] for b in range(len(FLAGS)) if v >> b & 1) or 'нет'


def read_all(rd, ngpc):
    s = dict(c00=rd(0x409c00), sig=rd(0x409400), s6=rd(0x409818), s7=rd(0x40981c), memcmd=rd(0x409a10),
             h4160=rd(0x404160), h4170=rd(0x404170), gr700=rd(0x400700), eng0=rd(0x002640), chan=rd(0x409b00),
             next=rd(0x409b04), chsw=rd(0x409b0c), intr=rd(0x409008), err=rd(0x409814), mmctl=rd(0x409714),
             strand=rd(0x409928), red=rd(0x409614), scr=[rd(0x409800 + 4 * i) for i in range(8)], gpc=[],
             vst=[rd(a) for a in (0x400380, 0x400384, 0x400388, 0x400390)], gpcbusy=rd(0x400604), ropbusy=rd(0x400608),
             febusy=rd(0x40060c), fifo=rd(0x400504), taddr=rd(0x400704), tdata=rd(0x400708),
             sched=[rd(a) for a in (0x002100, 0x002140, 0x00254c, 0x002a04, 0x002a08, 0x002a0c, 0x002a18, 0x002a28)])
    for g in range(ngpc):
        b = 0x502000 + g * 0x8000
        s['gpc'].append(dict(sig=rd(b + 0x400), s6=rd(b + 0x818), s7=rd(b + 0x81c), intr=rd(b + 0x008), red=rd(b + 0x614),
                             strand=rd(b + 0x928), tpc=rd(b + 0xcfc), scr=[rd(b + 0x800 + 4 * i) for i in range(8)]))
    return s


def verdict(s):
    out = []
    if s['s7'] & 0x80: out.append('главная прошивка сохраняет контекст')
    elif s['s7'] & 0x40: out.append('главная прошивка загружает контекст')
    if not s['c00'] & 1 and not s['s7'] and s['eng0'] & 0x00100000:
        out.append('планировщик (FIFO) ждёт сохранения контекста, а главная прошивка запроса на смену канала НЕ ВИДИТ '
                   '(0x409c00 бит 0 = 0) и ничего не делает: до прошивки дело не дошло')
    if s['febusy'] & 1 and s['gr700'] & 1:
        out.append(f'сам блок занят и не освобождается: последняя команда — метод 0x{s["taddr"] & 0x3ffc:04x}')
    if s['c00'] & 0x2000:
        out.append('ШАГ 1: ждёт, пока блок освободится (0x409c00 бит 13 стоит)')
    elif s['h4160'] & 1 and not s['h4160'] & 0x10:
        out.append('ШАГ 2: запросила паузу блока (0x404160 бит 0), подтверждения (бит 4) нет')
    elif s['s7'] & 1:
        n = s['s6']; have = s['sig'] >> n & 1 if n < 32 else '?'
        step = {8: 'ШАГ 3', 5: 'ШАГ 4', 2: 'ШАГ 5', 12: 'ШАГ 6'}.get(n, 'ШАГ ?')
        out.append(f'{step}: ждёт сигнала готовности {n} — {SIGNALS.get(n, "неизвестный сигнал")}; сейчас этот бит в 0x409400 равен {have}')
    elif s['memcmd']:
        out.append(f'ШАГ 6: ждёт выполнения команды записи в память (0x409a10 = {s["memcmd"]:#x}, не обнулился)')
    elif s['h4170'] & 0x10:
        out.append('после передачи: ждёт снятия бита 4 в 0x404170')
    else:
        out.append('ожиданий главной прошивки не видно')
    for g, x in enumerate(s['gpc']):
        if x['s7'] & 1:
            out.append(f'часть GPC{g}: своя прошивка ждёт сигнала {x["s6"]} (её отметки: {flags(x["s7"])})')
        elif x['s7']:
            out.append(f'часть GPC{g}: отметки {flags(x["s7"])}, ожидания нет')
    return out


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 5
    gap = float(sys.argv[2]) if len(sys.argv) > 2 else 0.5
    dev = card()
    if not dev: sys.exit('Карта NVIDIA не найдена.')
    try:
        fd = os.open(dev + '/resource0', os.O_RDONLY | os.O_SYNC)
        bar = mmap.mmap(fd, 16 << 20, mmap.MAP_SHARED, mmap.PROT_READ)
    except OSError as e:
        sys.exit(f'Не могу открыть регистры карты ({e}). Нужен sudo.')
    rd = lambda a: struct.unpack_from('<I', bar, a)[0]
    chip = (rd(0) >> 20) & 0x1ff
    ngpc = rd(0x409604) & 0x1f                              # число частей GPC — как его читает nouveau (gf100_gr_oneinit)
    print(f'### где стоит прошивка GR: {time.strftime("%F %T")}, чип NV{chip:02X}, частей GPC {ngpc}, чтений {n} через {gap} с')
    if not 0xc0 <= chip < 0xe0: sys.exit('Утилита написана по прошивке nouveau для Fermi.')
    if not 1 <= ngpc <= 8: sys.exit(f'Странное число частей GPC ({ngpc}) — дальше не читаю.')
    snaps = []
    for i in range(n):
        snaps.append(read_all(rd, ngpc))
        if i + 1 < n: time.sleep(gap)
    s = snaps[-1]
    print(f'GR глазами планировщика: 0x400700={s["gr700"]:08x} (занятость блока), 0x002640={s["eng0"]:08x} (движок GR в FIFO)')
    # 28.11, после первого снимка: прошивка оказалась свободна, занят сам блок — читаем, какие его части заняты
    # (имена и раскладка — база регистров envytools, rnndb pgraph.xml: STATUS, VSTATUS_0..3, GPC/ROP/FE_STATUS, FIFO.STATUS)
    names = {0: 'весь блок', 3: 'часть 3', 5: 'часть 5', 6: 'M2MF (копирование)', 7: 'CTXCTL (прошивка)', 8: 'часть 8', 9: 'часть 9', 11: 'часть 11',
             12: 'часть 12', 13: 'часть 13', 14: 'часть 14', 15: 'счётчики (главный)', 16: 'счётчики', 17: 'часть 17', 24: 'GPC', 25: 'ROP'}
    print('  занято по 0x400700: ' + (', '.join(names.get(b, f'бит {b}') for b in range(32) if s['gr700'] >> b & 1) or 'ничего'))
    print(f'  занятые GPC (маска) 0x400604={s["gpcbusy"]:08x}; занятые ROP 0x400608={s["ropbusy"]:08x}; вход блока занят 0x40060c={s["febusy"]:08x}')
    f = s['fifo']
    print(f'  очередь команд блока 0x400504={f:08x}: {"пуста" if f & 1 else "не пуста"}{", полна" if f & 2 else ""}, занято мест {(f >> 4) & 0xfff}, '
          f'взято {(f >> 16) & 0xff}, положено {f >> 24}')
    print(f'  последняя команда 0x400704={s["taddr"]:08x}: метод 0x{s["taddr"] & 0x3ffc:04x}, подканал {(s["taddr"] >> 16) & 7}; данные 0x400708={s["tdata"]:08x}')
    vn = [['HUB0', 'HUB1', 'HUB2', 'HUB3', 'HUB4', 'HUB5'], ['счётчики-гл', 'счётчики', 'HUB8', 'HUB9', 'HUB10'],
          ['ROP0', 'ROP1', 'ROP2', 'HUB11', 'HUB12', 'HUB13'], ['GPC', 'HUB14', 'HUB15', 'HUB16']]
    for i, v in enumerate(s['vst']):
        print(f'  состояния частей, регистр {i} = {v:08x}: ' + ' '.join(f'{n}={(v >> (3 * k)) & 7}' for k, n in enumerate(vn[i])))
    # сторож планировщика: срабатывал ли и как настроен (имена — envytools gf100_pfifo.xml; ни nouveau, ни NVIDIA сроки
    # смены контекста 0x002a18 и движка 0x002a0c не пишут — стоят значения после включения)
    q = s['sched']
    print(f'планировщик: прерывания 0x002100={q[0]:08x} (разрешены 0x002140={q[1]:08x}), ошибка планировщика 0x00254c={q[2]:08x}; '
          f'сроки: память 0x002a04={q[3]:08x} буфер 0x002a08={q[4]:08x} движок 0x002a0c={q[5]:08x} смена канала 0x002a18={q[6]:08x} 0x002a28={q[7]:08x}')
    print(f'главная прошивка: отметки (рабочий регистр 7) = {s["s7"]:08x}: {flags(s["s7"])}')
    print(f'  ждёт сигнала (рабочий регистр 6) = {s["s6"]}; сигналы готовности 0x409400 = {s["sig"]:08x}')
    print(f'  0x409c00={s["c00"]:08x} 0x404160={s["h4160"]:08x} 0x404170={s["h4170"]:08x} команда памяти 0x409a10={s["memcmd"]:08x}')
    print(f'  канал 0x409b00={s["chan"]:08x} следующий 0x409b04={s["next"]:08x} смена 0x409b0c={s["chsw"]:08x} прерывания 0x409008={s["intr"]:08x} '
          f'ошибка 0x409814={s["err"]:08x}')
    print(f'  передача регистров 0x409714={s["mmctl"]:08x} цепочки 0x409928={s["strand"]:08x} питание 0x409614={s["red"]:08x}')
    print('  рабочие регистры 0..7: ' + ' '.join(f'{v:08x}' for v in s['scr']))
    for g, x in enumerate(s['gpc']):
        print(f'часть GPC{g}: отметки = {x["s7"]:08x}: {flags(x["s7"])}; ждёт сигнала {x["s6"]}; сигналы {x["sig"]:08x}; прерывания {x["intr"]:08x}; '
              f'цепочки {x["strand"]:08x}; питание {x["red"]:08x}; состояние TPC {x["tpc"]:08x}')
        print('  рабочие регистры 0..7: ' + ' '.join(f'{v:08x}' for v in x['scr']))
    print('ВЫВОД:')
    for line in verdict(s): print('  ' + line)
    same = all(a == snaps[0] for a in snaps)
    if same:
        print(f'  между {n} чтениями не изменилось ничего: прошивка стоит на месте' if n > 1 else '  чтение одно')
    else:
        ch = sorted({k for a in snaps for k in a if k not in ('gpc', 'scr') and a[k] != snaps[0][k]})
        print(f'  между чтениями МЕНЯЛОСЬ: {", ".join(ch) or "только регистры частей GPC или рабочие регистры"} — прошивка работает')
        seen = []
        for a in snaps:
            v = '; '.join(verdict(a))
            if v not in seen: seen.append(v)
        for v in seen[:6]: print('    виденное состояние: ' + v)


if __name__ == '__main__':
    main()
