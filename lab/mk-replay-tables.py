#!/usr/bin/env python3
# Таблицы повтора памяти для lab ramgf100.c из записи NVIDIA (23.11): скрипты PMU (lab/trace-memscr.py) и прямые записи хоста
# вокруг них (lab/trace-memhost.py) -> массивы C lab_<префикс>_scr<шаг>[], _pre<шаг>[], _post<шаг>[]. Шаг задаётся номером
# скрипта в записи; повторы того же скрипта сверяются побайтно (разные — стоп). Только чтение записи.
#   python3 -I lab/mk-replay-tables.py memscr.json memhost.json ПРЕФИКС ШАГ=номер[,повторы][:post_из_номера] ...
import sys, json
S = json.load(open(sys.argv[1])); H = {h['i']: h for h in json.load(open(sys.argv[2]))}; pfx = sys.argv[3]
def arr(name, words, note):
    out = [f'static const u32 {name}[] = {{ /* {note} */']
    for i in range(0, len(words), 6):
        out.append('\t' + ' '.join(f'0x{w:08x},' for w in words[i:i + 6]))
    out.append('};'); return '\n'.join(out)
for spec in sys.argv[4:]:
    step, rest = spec.split('='); post_from = None
    if ':' in rest: rest, post_from = rest.split(':'); post_from = int(post_from)
    ids = [int(x) for x in rest.split(',')]; i0 = ids[0]
    for j in ids[1:]:
        if S[j]['words'] != S[i0]['words']: sys.exit(f'шаг {step}: скрипты {i0} и {j} различаются')
        if H[j]['pre'] != H[i0]['pre']: sys.exit(f'шаг {step}: записи до скрипта {i0} и {j} различаются')
    pre = [x for p in H[i0]['pre'] for x in p]; post = [x for p in H[post_from if post_from is not None else i0]['post'] for x in p]
    print(arr(f'lab_{pfx}_scr{step}', S[i0]['words'], f"{len(S[i0]['words'])} слов; t={S[i0]['t']:.1f}"))
    print(arr(f'lab_{pfx}_pre{step}', pre, f'{len(pre) // 2} пар'))
    print(arr(f'lab_{pfx}_post{step}', post, f'{len(post) // 2} пар'))
