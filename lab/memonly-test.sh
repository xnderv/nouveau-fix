#!/bin/bash
# ОПЫТ «ТОЛЬКО ПАМЯТЬ» (23.11): ядро и напряжение стоят на ВЕРХНЕМ уровне, переключается только память — средний <-> верхний
# уровень, N раз, под лёгкой нагрузкой (glxgears, если есть). Отделяет смену памяти от смены ядра: если зависает и так —
# дело в повторе памяти; если нет — во взаимодействии с ядром. Нужен модуль с ключом lab_mem_only (сборка 1123c и новее).
#   bash lab/memonly-test.sh [N=100] [HOLD=3]      — в терминале рабочего стола, один монитор
#   LOWER=03 bash lab/memonly-test.sh ...            — гонять нижний уровень <-> верхний вместо среднего
#       ВНИМАНИЕ (24.11): на GF114 под нагрузкой этот режим вешает графический блок за минуту (память 135 МГц при ядре на
#       верхнем уровне, docs/2026-11-24/hang-121.md) — это опыт на зависание, а не проверка сборки.
# Регулятор выключается (lab_gov=0); на плате, где повтор памяти ещё не проверен вживую, включается lab_mem_new=1 (запуск
# сценария = согласие на опыт с памятью). Стоп — на первой ошибке в журнале ядра или если уровень не встал. В конце ключи
# возвращаются как были. Если экран замрёт — кнопка Reset; после загрузки:  journalctl -k -b -1 > memonly-crash.txt
set -uo pipefail
PRM=/sys/module/nouveau/parameters
[ -e $PRM/lab_mem_only ] || { echo "В модуле нет lab_mem_only — нужна сборка 1123c или новее (git pull, пересобрать)"; exit 1; }
N="${1:-100}"; HOLD="${2:-3}"
D="${RESULTS:-$HOME/nouveau-memonly}"; mkdir -p "$D"; OUT="$D/memonly-$(date +%Y%m%d-%H%M%S).txt"
say() { echo "$(date +%T) $*" | tee -a "$OUT"; sync; }
w() { sudo sh -c "echo $2 > $PRM/$1"; }
sudo -v || exit 1
( while sleep 50; do sudo -n -v 2>/dev/null || exit; done ) & KEEP=$!
PS="$(sudo sh -c 'ls /sys/kernel/debug/dri/*/pstate 2>/dev/null | head -n 1')"
[ -n "$PS" ] || { echo "Нет debugfs pstate (sudo mount -t debugfs none /sys/kernel/debug)"; kill $KEEP; exit 1; }
LEVELS=($(sudo cat "$PS" | grep -oE '^[0-9a-f]{2}:' | tr -d ':')); TOP="${LEVELS[-1]}"; MID="${LOWER:-${LEVELS[-2]}}"   # LOWER=03 — нижний уровень вместо среднего
K0="lab_gov=$(cat $PRM/lab_gov) lab_mem_new=$(cat $PRM/lab_mem_new) lab_mem_only=$(cat $PRM/lab_mem_only)"
GP=""
restore() {
  [ -n "$GP" ] && kill "$GP" 2>/dev/null
  w lab_mem_only 0; sudo sh -c "echo $TOP > $PS"; sleep 1
  for kv in $K0; do [ "${kv%%=*}" = lab_mem_only ] || w "${kv%%=*}" "${kv#*=}"; done
  kill $KEEP 2>/dev/null
}
trap 'say "прервано — ключи возвращены"; restore; exit 1' INT TERM
say "опыт «только память»: $(uname -r), модуль $(cat /sys/module/nouveau/srcversion); $(sudo journalctl -k -b 0 --no-pager | grep -m1 -oE 'LAB build: .*'); уровни ${LEVELS[*]}, верх $TOP, средний $MID; N=$N, держать $HOLD с; ключи было: $K0"
w lab_gov 0; w lab_mem_new 1
sudo sh -c "echo $TOP > $PS"; sleep 2
T0="$(date "+%F %T")"
w lab_mem_only 1
command -v glxgears >/dev/null && { glxgears >/dev/null 2>&1 & GP=$!; say "нагрузка: glxgears"; } || say "нагрузки нет (glxgears не найден)"
fail=0
for i in $(seq 1 "$N"); do
  for L in "$MID" "$TOP"; do
    sudo sh -c "echo $L > $PS" 2>>"$OUT"; sleep "$HOLD"
    ac="$(sudo cat "$PS" | grep -m1 '^AC:' | sed 's/^AC: *//')"
    e="$(sudo journalctl -k -b 0 --no-pager --since "$T0" | grep -E 'Xid|FAULT|TRAP|DATA_ERROR|ТАЙМ-АУТ|не переключилась|отклонён|failed to idle|SCHED_ERROR' | head -n 3)"
    if [ -n "$e" ]; then say "переход $i -> $L: ОШИБКА в журнале:"; echo "$e" | tee -a "$OUT"; fail=1; break 2; fi
  done
  [ $((i % 10)) -eq 0 ] && say "  $i переходов памяти туда-обратно, ошибок нет; сейчас: $ac"
done
mem="$(sudo journalctl -k -b 0 --no-pager --since "$T0" | grep -c 'LAB mem_only: память уровня')"
say "=== итог: переключений памяти $mem, $( [ $fail = 0 ] && echo 'ошибок нет' || echo 'ОСТАНОВЛЕНО НА ОШИБКЕ')"
sudo journalctl -k -b 0 --no-pager --since "$T0" | grep -E 'LAB (mem_only|replay|pstate .*done)' | tail -n 12 >> "$OUT"
restore; trap - INT TERM
say "ключи возвращены: $K0. Файл: $OUT"
