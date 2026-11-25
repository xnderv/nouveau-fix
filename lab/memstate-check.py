#!/usr/bin/env python3
# Проверка «всухую» определения частоты памяти по регистрам (lab_cur_mhz, правка 24.11) на записанных скриптах DDR3:
# по таблицам драйвера (прямые записи до, скрипт, прямые записи после) и по JSON скриптов из lab/trace-memscr.py
# прослеживаются значения 0x137360, 0x132004, 0x137330, 0x137320, 0x137310, 0x1373f0 и считается, что прочитает новая
# функция и что читала старая (только бит 1 регистра 0x1373f0). Только чтение файлов.
#   python3 -I lab/memstate-check.py ПУТЬ/nvkm/subdev/fb/ramgf100.c [СКРИПТЫ.json lo,mid,hi]
import re, json, sys
s = open(sys.argv[1]).read()
arr = {m[1]: [int(x, 16) for x in re.findall(r'0x[0-9a-fA-F]+', m[2])] for m in re.finditer(r'static const u32 (\w+)\[\] = \{(.*?)\};', s, re.S)}


def run_script(words, st):
    i = 0
    while i < len(words):
        h = words[i]; n = h >> 16; op = h & 0xffff; a = words[i + 1:i + n]
        if n == 0 or op == 0x16: break
        if op == 0x21:
            for k in range(0, len(a) - 1, 2): st[a[k]] = a[k + 1]
        i += n


def run_list(l, st):
    for k in range(0, len(l) - 1, 2): st[l[k]] = l[k + 1]


def cur_mhz(st, lv):
    if (st.get(0x137360, 0) & 3) == 2:                       # DDR3: память на PLL
        c = st.get(0x132004, 0); r = st.get(0x137330, 0)
        P, N, M = (c >> 16) & 0x3f, (c >> 8) & 0xff, c & 0xff; ref = 1620000
        if r & 0x80000000:
            if st.get(0x137320, 0) & 0x100: r >>= 8
            ref = 3240000 // ((r & 0x3f) + 2)
        mhz = ref * N // M // P // 1000 if M and P else 0
        for L in lv:
            if abs(mhz - L) * 50 <= L: return L, f'PLL {mhz}'
        return mhz, f'PLL {mhz}'
    if st.get(0x1373f0, 0) & 2: return lv[2], 'бит 1 регистра 0x1373f0'
    return 3240 // (((st.get(0x137310, 0) >> 8) & 0x3f) + 2), 'делитель'


def old_mhz(st, lv):
    if st.get(0x1373f0, 0) & 2: return lv[2]
    return 3240 // (((st.get(0x137310, 0) >> 8) & 0x3f) + 2)


POST = {0x137300: 0x103, 0x137310: 0x81200808, 0x137320: 0x103, 0x137330: 0x81200606, 0x137360: 3, 0x132004: 0, 0x1373f0: 1}
boards = {'ASUS GT 630': ((135, 324, 900), 'lab_gf108_', [('A', 900), ('B', 324), ('D', 135), ('E', 900), ('F', 324), ('C', 900)]),
          'Quadro 600': ((135, 324, 800), 'lab_q600_', [('A', 800), ('B', 324), ('C', 800)])}
good = bad = oldgood = 0
for name, (lv, pfx, seq) in boards.items():
    st = dict(POST); print(f'== {name}: после POST {cur_mhz(st, lv)[0]} МГц')
    for k, want in seq:
        run_list(arr.get(pfx + 'pre' + k, []), st); run_script(arr[pfx + 'scr' + k], st); run_list(arr.get(pfx + 'post' + k, []), st)
        new, how = cur_mhz(st, lv); old = old_mhz(st, lv); good += new == want; bad += new != want; oldgood += old == want
        print(f'   шаг {k}: должно стать {want}; новая функция {new} ({how}) {"✓" if new == want else "✗"}; старая {old} {"✓" if old == want else "✗"}')
if len(sys.argv) > 3:
    lv = tuple(int(x) for x in sys.argv[3].split(',')); st = dict(POST)
    print('== скрипты из JSON по порядку запуска (без прямых записей хоста):')
    for sc in json.load(open(sys.argv[2])):
        run_script(sc['words'], st); new, how = cur_mhz(st, lv)
        print(f'   {sc["t"]:9.1f} с, {sc["nwords"]} слов: новая функция {new} ({how}); старая {old_mhz(st, lv)}')
print(f'по таблицам драйвера: новая функция верна в {good} шагах из {good + bad}, старая — в {oldgood}')
