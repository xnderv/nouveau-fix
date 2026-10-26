#!/usr/bin/env python3
# ПОКРЫТИЕ МОДЕЛИ (26.10). Вселенная — всё, что драйвер NVIDIA 390 пишет в карту при смене уровня на нашей GTX 560 Ti:
#   - записи хоста в окнах переходов записи try7 (10 переходов под нагрузкой), минус фон: регистры, которые пишутся и в
#     таких же по длине «тихих» окнах через 2 с после каждого перехода;
#   - регистры внутри скриптов памяти PMU и списков записей рядом с ними (массивы lab_nv_* в lab/0002).
# Для каждого регистра в docs/model/registers.tsv руками записано:
#   что   — повт (повторяем по умолчанию) | ключ (только лабораторным ключом) | свой (та же функция своим способом) |
#           нет (не повторяем) | вне (служебное, к модели не относится);
#   почему — опыт (включали и выключали, разница есть) | вывод (из нескольких фактов или открытого кода) |
#            гипотеза | нет (не знаем);
#   источник — А наша запись NVIDIA, Б наш опыт, В VBIOS, Г открытые источники, Д чужие наблюдения (проверенные нами).
#   python3 -I lab/coverage.py extract ЗАПИСЬ.txt.xz   — окна переходов → docs/model/try7-transitions.json (без сырых данных)
#   python3 -I lab/coverage.py report                  — итоги и таблица → docs/model/coverage.md
import collections, json, lzma, os, re, sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
TJSON = os.path.join(ROOT, 'docs/model/try7-transitions.json')
TSV = os.path.join(ROOT, 'docs/model/registers.tsv')
OUT = os.path.join(ROOT, 'docs/model/coverage.md')
PATCH = os.path.join(ROOT, 'lab/0002-LAB-fermi-reclock-instrumented.patch')
BAR0 = 0xf4000000
# переходы в записи try7, с (nvidia-vs-lab-map.md, раздел 17); первый (233,06 — загрузка драйвера) не берём
TRANS = [277.02, 285.05, 296.05, 329.02, 337.05, 351.52, 363.02, 371.05, 386.99, 438.18]
WIN = (-0.03, 0.08)   # окно вокруг начала перехода, с: скрипт памяти до ~27 мс и hubk07 после него
CTRL = 2.0            # контрольное окно той же длины через 2 с

def extract(path):
    win = [(t + WIN[0], t + WIN[1], t) for t in TRANS]
    ctl = [(t + CTRL + WIN[0], t + CTRL + WIN[1], t) for t in TRANS]
    w, c, vals, seen = collections.Counter(), collections.Counter(), collections.defaultdict(set), collections.defaultdict(set)
    with lzma.open(path, 'rt', errors='replace') as f:
        for l in f:
            if not l.startswith('W ') and not l.startswith('R '):
                continue
            p = l.split()
            if len(p) < 6:
                continue
            t, a = float(p[2]), int(p[4], 16)
            if not BAR0 <= a < BAR0 + 0x1000000:
                continue
            off = a - BAR0
            if 0x700000 <= off < 0x800000:   # окно в видеопамять, не регистры
                continue
            for lo, hi, t0 in win:
                if lo <= t <= hi:
                    if p[0] == 'W':
                        w[off] += 1
                        seen[off].add(t0)
                        if len(vals[off]) < 8:
                            vals[off].add(p[5])
                    break
            else:
                if p[0] == 'W' and any(lo <= t <= hi for lo, hi, _ in ctl):
                    c[off] += 1
    regs = {f'{a:#08x}': {'writes': w[a], 'background': c[a], 'transitions': len(seen[a]), 'values': sorted(vals[a])}
            for a in sorted(w)}
    json.dump({'trace': 'try7 (24.10.2026), запись драйвера NVIDIA 390 на GV-N560OC-1GI', 'transitions_s': TRANS,
               'window_s': WIN, 'control_shift_s': CTRL, 'registers': regs}, open(TJSON, 'w'), ensure_ascii=False, indent=1)
    print(f'регистров с записями в окнах: {len(regs)}, из них фоновых: {sum(1 for r in regs.values() if r["background"])}')

def script_regs():
    """Регистры, которые пишут скрипты памяти NVIDIA и списки рядом с ними (массивы lab_nv_* в lab/0002)."""
    src = '\n'.join(l[1:] if l.startswith('+') else l for l in open(PATCH, errors='replace').read().splitlines())
    where = collections.defaultdict(set)
    for m in re.finditer(r'static const u32 (lab_nv_\w+)\[\] = \{(.*?)\};', src, re.S):
        name, w = m.group(1)[7:], [int(x, 16) for x in re.findall(r'0x[0-9a-fA-F]+', m.group(2))]
        if name.startswith('scr'):
            i = 0
            while i < len(w):
                ln, op = w[i] >> 16, w[i] & 0xffff
                if op == 0x21:
                    for k in range(i + 1, i + ln, 2):
                        where[w[k]].add(name)
                if op == 0x16 or ln == 0:
                    break
                i += ln
        else:
            for k in range(0, len(w) - 1, 2):
                where[w[k]].add(name)
    return where

def block(a):
    for lo, hi, n in ((0x137000, 0x137400, 'такты'), (0x132000, 0x133000, 'такты памяти'), (0x020000, 0x021000, 'PTHERM'),
                      (0x00e000, 0x00f000, 'GPIO и хост-домен'), (0x022000, 0x023000, 'PCIe'), (0x088000, 0x089000, 'PCIe (конфигурация)'),
                      (0x10f000, 0x110000, 'контроллер памяти'), (0x110000, 0x114000, 'контроллер памяти'), (0x100000, 0x101000, 'FB'),
                      (0x13d000, 0x13e000, 'прочее'), (0x13b000, 0x13f000, 'кросс-бар PXBAR'), (0x10a000, 0x10b000, 'PMU'),
                      (0x610000, 0x612000, 'дисплей')):
        if lo <= a < hi:
            return n
    return 'прочее'

def report():
    tr = json.load(open(TJSON))['registers']
    host = {int(k, 16) for k, r in tr.items() if not r['background']}
    scr = script_regs()
    rows = {}
    for l in open(TSV):
        if l.startswith('#') or not l.strip():
            continue
        f = (l.rstrip('\n').split('\t') + [''] * 7)[:7]
        rows[int(f[0], 16)] = dict(zip(('addr', 'name', 'what', 'why', 'src', 'note'), [f[0]] + f[1:6]))
    univ = sorted(host | set(scr))
    miss = [a for a in univ if a not in rows]
    extra = [a for a in rows if a not in univ]
    tot = collections.Counter()
    byb = collections.defaultdict(collections.Counter)
    for a in univ:
        r = rows.get(a, {'what': '?', 'why': '?'})
        b = block(a)
        byb[b]['всего'] += 1
        byb[b]['что:' + r['what']] += 1
        byb[b]['почему:' + r['why']] += 1
        tot['всего'] += 1
        tot['что:' + r['what']] += 1
        tot['почему:' + r['why']] += 1
    def pct(cn):
        model = cn['всего'] - cn['что:вне']
        done = cn['что:повт'] + cn['что:ключ'] + cn['что:свой']
        why = cn['почему:опыт'] + cn['почему:вывод']
        return model, done, why, cn['почему:опыт']
    m, d, y, e = pct(tot)
    out = ['# Покрытие модели: что NVIDIA пишет при смене уровня и что из этого мы повторяем и понимаем', '',
           'Файл собирает `lab/coverage.py report` из `registers.tsv` (статусы, руками) и `try7-transitions.json` (выборка из записи',
           'NVIDIA). Не править руками. Как читать — в начале `lab/coverage.py`.', '',
           f'**Регистров в модели: {m}** (всего {tot["всего"]}, служебных {tot["что:вне"]}): записи хоста при переходах — {len(host)}, '
           f'внутри скриптов памяти и списков — {len(scr)}, в обоих — {len(host & set(scr))}.', '',
           '| Мера | Регистров | Доля |', '|---|---|---|',
           f'| Что делает NVIDIA — повторяем (по умолчанию, ключом или своим способом) | {d} | {100 * d / m:.0f} % |',
           f'| Почему — понимаем (опыт или вывод) | {y} | {100 * y / m:.0f} % |',
           f'| Почему — проверено опытом | {e} | {100 * e / m:.0f} % |', '',
           '## По блокам', '', '| Блок | В модели | Повторяем | Понимаем | Опытом |', '|---|---|---|---|---|']
    for b in sorted(byb, key=lambda x: -byb[x]['всего']):
        m2, d2, y2, e2 = pct(byb[b])
        if m2:
            out.append(f'| {b} | {m2} | {d2} | {y2} | {e2} |')
        else:
            out.append(f'| {b} | 0 (служебные: {byb[b]["всего"]}) | — | — | — |')
    out += ['', '## Все регистры', '', '| Адрес | Блок | Где | Что | Почему | Источник | Имя и заметка |', '|---|---|---|---|---|---|---|']
    for a in univ:
        r = rows.get(a, {'name': '', 'what': '?', 'why': '?', 'src': '', 'note': ''})
        where = []
        if a in host:
            where.append(f'хост ×{tr[f"{a:#08x}"]["writes"]}')
        if a in scr:
            where.append(','.join(sorted(scr[a]))[:30])
        note = (r['name'] + (' — ' if r['name'] and r['note'] else '') + r['note']).replace('|', '/')
        out.append(f'| `{a:#08x}` | {block(a)} | {"; ".join(where)} | {r["what"]} | {r["why"]} | {r["src"]} | {note} |')
    if miss or extra:
        out += ['', f'**Не размечены в registers.tsv:** {", ".join(f"{a:#08x}" for a in miss) or "—"}. '
                f'**Лишние строки:** {", ".join(f"{a:#08x}" for a in extra) or "—"}.']
    open(OUT, 'w').write('\n'.join(out) + '\n')
    print(f'в модели {m}: повторяем {d} ({100 * d / m:.0f} %), понимаем {y} ({100 * y / m:.0f} %), опытом {e} ({100 * e / m:.0f} %); '
          f'не размечено {len(miss)}, лишних {len(extra)} → {os.path.relpath(OUT, ROOT)}')

if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == 'extract':
        extract(sys.argv[2])
    elif sys.argv[1:] == ['report']:
        report()
    else:
        sys.exit(__doc__ or 'lab/coverage.py extract ЗАПИСЬ.txt.xz | report')
