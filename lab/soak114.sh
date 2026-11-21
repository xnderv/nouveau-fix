#!/bin/bash
# ОПЫТ 114 (21.11), модуль build-1121h (ключ lab_gov_two). Долгий прогон сборки тестировщиков под регулятором, три части по
# одному отличию, каждая — gov94.sh (циклы «нагрузка браузером L с / покой I с», регулятор драйвера переключает сам, с памятью):
#   А — как есть (1121g = сборка тестировщиков; часами в связке ещё не работала);
#   Б — lab_gov_two=1: регулятор без нижнего уровня, как у GF119 (07 ↔ 0f, скачки сразу с памятью 324 ↔ 2004);
#   В — lab_gov_nv=1: темп регулятора как у NVIDIA (вверх по первому замеру ≥ 50 %, вниз через 8 с).
# Ключи меняются на ходу, между частями; в конце — как были. Стоп всего опыта, если часть закончилась ошибкой.
#   bash ~/Home/nouveau-fix/lab/soak114.sh [C=40] [L=45] [I=45]   — в терминале рабочего стола; 40 циклов ≈ 1 ч на часть, 3 ч
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; PRM=/sys/module/nouveau/parameters
[ -e "$PRM/lab_gov_two" ] || { echo "Нет lab_gov_two — нужен модуль build-1121h"; exit 1; }
C="${1:-40}"; L="${2:-45}"; I="${3:-45}"
OUT=~/Home/nouveau-fix/results/test114-$(date +%Y%m%d-%H%M%S).txt
say() { echo "$(date +%T) $*" | tee -a "$OUT"; sync; }
w() { sudo sh -c "echo $2 > $PRM/$1"; }
sudo -v || exit 1
( while sleep 50; do sudo -n -v 2>/dev/null || exit; done ) & KEEP=$!
T0="$(cat $PRM/lab_gov_two)"; N0="$(cat $PRM/lab_gov_nv)"
restore() { w lab_gov_two "$T0"; w lab_gov_nv "$N0"; kill $KEEP 2>/dev/null; }
trap 'say "прервано — ключи возвращены"; restore; exit 1' INT TERM
PS="$(sudo sh -c 'ls /sys/kernel/debug/dri/*/pstate | head -n 1')"
say "опыт 114: $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), загрузка $(uptime -s); C=$C L=$L I=$I"
part() {   # $1 имя, затем ключи «имя=значение»
  local name="$1" rc f t; shift; t="$(date "+%F %T")"
  for kv in "$@"; do w "${kv%%=*}" "${kv#*=}"; done
  say "--- часть $name: lab_gov_two=$(cat $PRM/lab_gov_two) lab_gov_nv=$(cat $PRM/lab_gov_nv); сейчас $(sudo grep '^AC' "$PS")"
  bash "$HERE/gov94.sh" "$C" "$L" "$I" > /dev/null 2>&1; rc=$?
  f="$(ls -t ~/Home/nouveau-fix/results/test94-*.txt | head -n 1)"
  say "    файл $(basename "$f"): $(grep -E '=== итог' "$f" | sed -E 's/^.{8} //')"
  say "    переходы по уровням: $(sudo journalctl -k -b 0 --no-pager --since "$t" | grep -oE 'LAB gov: -> [0-9a-f]{2}' | sort | uniq -c | tr '\n' ' ')"
  grep -qE '=== итог: .*ошибок GPU 0' "$f" && grep -qE 'вечных 0' "$f" && return 0
  say "    часть $name закончилась с ошибкой или застреванием (код $rc) — стоп"; return 1
}
part "А — как есть" lab_gov_two=0 lab_gov_nv=0 &&
part "Б — два уровня, как GF119" lab_gov_two=1 lab_gov_nv=0 &&
part "В — темп NVIDIA" lab_gov_two=0 lab_gov_nv=1
restore; trap - INT TERM
say "=== конец; ключи возвращены (lab_gov_two=$(cat $PRM/lab_gov_two) lab_gov_nv=$(cat $PRM/lab_gov_nv))"
grep -E "опыт 114|--- часть|файл|переходы|стоп|=== конец" "$OUT" > "$OUT.sum"
echo "Результат: $OUT"
