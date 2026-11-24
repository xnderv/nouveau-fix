#!/bin/bash
# ОПЫТ 120 (23.11, ночь), модуль 1123c (ключ lab_mem_only), наша GF114. Три части, стоп на первой ошибке:
#   А — «только память»: ядро и напряжение на 0f, память 07 <-> 0f (324 <-> 2004), N раз под glxgears;
#   Б — «только память»: 03 <-> 0f (135 <-> 2004), N/2 раз;
#   В — контроль: обычный подъём ядро + память 03 -> 0f со спуском через 07 (hangtest FAST), 300 раз.
# Запуск по SSH внутри screen (переживает разрыв связи):  screen -S night120 bash ~/Home/nouveau-fix/lab/night120.sh [N=600]
# Пароль sudo — один раз в начале; потом Ctrl-a d (отцепиться). Итог — results/test120-*.txt (+ .sum).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; N="${1:-600}"
export DISPLAY="${DISPLAY:-:0}"; [ -n "${XAUTHORITY:-}" ] || export XAUTHORITY="$(ls /run/user/$(id -u)/.mutter-Xwaylandauth.* 2>/dev/null | head -n 1)"
OUT=~/Home/nouveau-fix/results/test120-$(date +%Y%m%d-%H%M%S).txt
say() { echo "$(date +%T) $*" | tee -a "$OUT"; sync; }
sudo -v || exit 1
( while sleep 50; do sudo -n -v 2>/dev/null || exit; done ) & KEEP=$!
trap 'kill $KEEP 2>/dev/null' EXIT
say "опыт 120: $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), загрузка $(uptime -s); N=$N; DISPLAY=$DISPLAY"
glxinfo -B >/dev/null 2>&1 && say "дисплей доступен (glxgears пойдёт)" || say "ВНИМАНИЕ: дисплей недоступен — части пойдут без нагрузки"

say "--- А: только память, 07 <-> 0f, $N раз"
RESULTS=~/Home/nouveau-fix/results bash "$HERE/memonly-test.sh" "$N" 3 > /dev/null 2>&1
f="$(ls -t ~/Home/nouveau-fix/results/memonly-*.txt | head -n 1)"; say "    $(grep -E '=== итог' "$f" | sed -E 's/^.{8} //') ($(basename "$f"))"
grep -q 'ошибок нет' <(grep '=== итог' "$f") || { say "    стоп"; exit 1; }

say "--- Б: только память, 03 <-> 0f, $((N / 2)) раз"
LOWER=03 RESULTS=~/Home/nouveau-fix/results bash "$HERE/memonly-test.sh" "$((N / 2))" 3 > /dev/null 2>&1
f="$(ls -t ~/Home/nouveau-fix/results/memonly-*.txt | head -n 1)"; say "    $(grep -E '=== итог' "$f" | sed -E 's/^.{8} //') ($(basename "$f"))"
grep -q 'ошибок нет' <(grep '=== итог' "$f") || { say "    стоп"; exit 1; }

say "--- В: контроль — ядро + память вместе (hangtest FAST, 300)"
T="$(date "+%F %T")"
FAST=1 LOW=03 HIGH=0f MID=07 bash "$HERE/hangtest.sh" 300 > /dev/null 2>&1; rc=$?
e="$(sudo journalctl -k -b 0 --no-pager --since "$T" | grep -cE 'Xid|FAULT|DATA_ERROR|ТАЙМ-АУТ|ОСТАЛСЯ НА PLL')"
h="$(ls -t ~/Home/nouveau-fix/results/hangtest-*.txt | head -n 1)"
say "    код $rc, ошибок в журнале $e; $(grep -E '^=== ' "$h" | tail -n 1 | sed -E 's/^.{0,8} ?//') ($(basename "$h"))"
say "=== конец опыта 120"
grep -E "опыт 120|^.{8} ---|итог|код |стоп|=== конец" "$OUT" > "$OUT.sum"
