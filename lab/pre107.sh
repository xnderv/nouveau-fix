#!/bin/bash
# ТЕСТ 107 (20.11), модуль build-1120e. Повтор теста 99 БЕЗ смены памяти (как тест 100: lab_mem=0, память 324 весь тест).
# Вопрос: нужна ли ступень 405 перед PLL GPC при подъёме с 03 (NVIDIA делает её только на GF110/GF114). Тест 99 смешал её со
# сменой памяти и поймал редкое зависание GR (≈1 на 4150, docs/2026-11-19/hang-99.md); тест 100 (только ядро, со ступенью) —
# 10000 подъёмов чисто. Здесь только ядро, прогоны чередуются: со ступенью / без, по N подъёмов 03 -> 0f со спуском через 07
# под нагрузкой (FAST). Если «без ступени» тоже чисто — правило «без ступени» одно на все чипы, таблица по чипам не нужна.
# Регулятор на время теста выключен. Стоп на зависании графики или вечном застревании.
#   bash ~/Home/nouveau-fix/lab/pre107.sh [N=2200] [R=4]   — в терминале рабочего стола; 2200×8 ≈ 11 часов (≈26 подъёмов в минуту)
set -uo pipefail
PRM=/sys/module/nouveau/parameters; HERE="$(cd "$(dirname "$0")" && pwd)"
N="${1:-2200}"; R="${2:-4}"   # R — число пар «со ступенью / без»
[ -e "$PRM/lab_nv_up07" ] || { echo "Нет lab_nv_up07 — нужен модуль build-1120e"; exit 1; }
pgrep -f "hangtest|core9|night93|disp91|gov94|e9gov95|up96|nvx97|uf98|cntr[78]|fsrm8|pmubr|big83|pre99|core100|auto101|alt106" >/dev/null && { echo "Идёт другой тест — дождитесь конца"; exit 1; }
[ "$(cat $PRM/lab_nv_up07)" = 1 ] && [ "$(cat $PRM/lab_gpc_pre405)" = 1 ] || { echo "Ключи не по умолчанию (lab_nv_up07, lab_gpc_pre405) — перезагрузите модуль"; exit 1; }
OUT=~/Home/nouveau-fix/results/test107-$(date +%Y%m%d-%H%M%S).txt
say() { echo "$(date +%T) $*" | tee -a "$OUT"; }
w() { sudo sh -c "echo $2 > $PRM/$1"; }
sudo -v || exit 1
( while sleep 50; do sudo -n -v 2>/dev/null || exit; done ) & KEEP=$!
G0=$(cat $PRM/lab_gov); P0=$(cat $PRM/lab_gpc_pre405); M0=$(cat $PRM/lab_mem)
restore() { w lab_gpc_pre405 "$P0"; w lab_mem "$M0"; w lab_gov "$G0"; kill $KEEP 2>/dev/null; }
trap 'say "прервано — ключи возвращаю"; restore; exit 1' INT TERM
cnt() { journalctl -k -b 0 --no-pager | grep -c "$1"; }
gerr() { journalctl -k -b 0 --no-pager | grep -cE "DATA_ERROR|FAULT at|Xid|killed|g84_bar_flush"; }
STOP=0
run() {   # $1 — 0/1 ступень
  local T0 U0 D0 S0 E0 RC
  w lab_gpc_pre405 "$1"
  T0=$(date "+%F %T"); U0=$(cnt "ТАЙМ-АУТ делитель -> PLL"); D0=$(cnt "ТАЙМ-АУТ PLL -> делитель"); S0=$(cnt "ОСТАЛСЯ НА PLL"); E0=$(gerr)
  FAST=1 LOW=03 HIGH=0f MID=07 bash "$HERE/hangtest.sh" "$N" >> "$OUT" 2>&1; RC=$?
  say "=== итог: ступень 405 = $1 — код $RC, застреваний подъёма $(( $(cnt "ТАЙМ-АУТ делитель -> PLL") - U0 )), спуска $(( $(cnt "ТАЙМ-АУТ PLL -> делитель") - D0 )), вечных $(( $(cnt "ОСТАЛСЯ НА PLL") - S0 )), ошибок GPU $(( $(gerr) - E0 )); записей ступени $(journalctl -k -b 0 --no-pager --since "$T0" | grep -c 'gpc_pre405: делительный путь')"
  [ "$RC" = 2 ] && { say "--- зависание графики — стоп"; STOP=1; }
  [ "$(cnt "ОСТАЛСЯ НА PLL")" -gt "$S0" ] && { say "--- вечное застревание — стоп"; STOP=1; }
  return 0
}
PS="$(sudo sh -c 'ls /sys/kernel/debug/dri/*/pstate | head -n 1')"
say "тест 107: N=$N, пар $R, только ядро; $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), загрузка $(uptime -s)"
w lab_gov 0; sudo sh -c "echo 07 > $PS"; sleep 2; w lab_mem 0; sudo sh -c "echo 03 > $PS"; sleep 2
say "подготовка: $(sudo grep '^AC' "$PS"); lab_mem=$(cat $PRM/lab_mem)"
for p in $(for i in $(seq 1 "$R"); do echo 1 0; done); do
  [ $STOP = 0 ] || break
  say "--- прогон: ступень 405 = $p"; run "$p"
done
restore
say "=== конец; ключи возвращены"
grep -E "тест 107|подготовка|=== итог|^.{8} ---" "$OUT" > "$OUT.sum"
echo "СВОДКА:"; cat "$OUT.sum"
echo "Результат: $OUT"
