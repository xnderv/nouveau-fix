#!/bin/bash
# Снимки регистров при загрузке (лабораторный драйвер с 25.10: строки «LAB boot snap #1 …» в журнале ядра — тактирование,
# PTHERM, датчик, GPIO/ШИМ; только чтение, до выбора первого уровня). Журнал ядра хранится на диске, так что снимок есть
# у каждой загрузки с этим драйвером.
#   bash ~/Home/nouveau-fix/lab/bootsnap.sh           — снимок текущей загрузки
#   bash ~/Home/nouveau-fix/lab/bootsnap.sh -3        — снимок загрузки -3 (номера: journalctl --list-boots)
#   bash ~/Home/nouveau-fix/lab/bootsnap.sh -3 0      — разница двух загрузок: регистр, значение в первой, во второй
#   N=2 bash … — второй снимок загрузки (после выхода из сна), по умолчанию первый
set -u
snap() {   # $1 = номер загрузки → строки «регистр значение»
    journalctl -k -b "$1" -o cat --no-pager 2>/dev/null | grep -E "LAB boot snap #${N:-1} " \
        | sed -E 's/.*LAB boot snap #[0-9]+ [^:]+://' | tr ' ' '\n' | grep '=' | tr '=' ' '
}
if [ $# -lt 2 ]; then
    b="${1:-0}"; s="$(snap "$b")"
    [ -n "$s" ] || { echo "В загрузке $b снимка нет (драйвер старше 25.10 или lab_boot_snap=0)"; exit 1; }
    journalctl -k -b "$b" -o cat --no-pager | grep -E "LAB boot snap #${N:-1} " | sed -E 's/^nouveau [^ ]+ clk: //'
else
    a="$(snap "$1")"; b="$(snap "$2")"
    [ -n "$a" ] && [ -n "$b" ] || { echo "Нет снимка в одной из загрузок ($1, $2)"; exit 1; }
    join <(echo "$a" | sort) <(echo "$b" | sort) | awk -v A="$1" -v B="$2" '
        $2 != $3 { printf "%s  загр %s: %s  загр %s: %s\n", $1, A, $2, B, $3; n++ }
        END { printf "%d регистров различаются\n", n+0 }'
fi
