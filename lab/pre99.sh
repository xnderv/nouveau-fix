#!/bin/bash
# ТЕСТ 99 (18.11), модуль от build-1117j. Универсальное правило вместо таблицы по чипам: нужна ли ступень 405 перед PLL GPC
# при подъёме с 03 (NVIDIA делает её только на GF110/GF114; GF104/106/108/116/117/119 — нет). Если без неё на нашей GF114 чисто,
# правило «без ступени» — одно на все чипы, и таблица не нужна.
# Набор службы (с lab_nv_up07=1: с 07 ступени уже нет); одно отличие — lab_gpc_pre405=0. Прогоны чередуются: со ступенью,
# без, со ступенью, без — по N подъёмов 03 -> 0f со спуском через 07 под нагрузкой (FAST). Регулятор на время теста выключен.
# Стоп на зависании графики или вечном застревании.
#   bash ~/Home/nouveau-fix/lab/pre99.sh [N=300]     — в терминале рабочего стола; около 50 минут
set -uo pipefail
PRM=/sys/module/nouveau/parameters; HERE="$(cd "$(dirname "$0")" && pwd)"
N="${1:-300}"
[ -e "$PRM/lab_nv_up07" ] || { echo "Нет lab_nv_up07 — нужен модуль от build-1117j"; exit 1; }
pgrep -f "hangtest|core9|night93|disp91|gov94|e9gov95|up96|nvx97|uf98|cntr[78]|fsrm8|pmubr|big83" >/dev/null && { echo "Идёт другой тест — дождитесь конца"; exit 1; }
[ "$(cat $PRM/lab_nv_up07)" = 1 ] && [ "$(cat $PRM/lab_gpc_pre405)" = 1 ] || { echo "Служба не на наборе 18.11 — сначала autoclock.sh install"; exit 1; }
OUT=~/Home/nouveau-fix/results/test99-$(date +%Y%m%d-%H%M%S).txt
say() { echo "$(date +%T) $*" | tee -a "$OUT"; }
w() { sudo sh -c "echo $2 > $PRM/$1"; }
sudo -v || exit 1
( while sleep 50; do sudo -n -v 2>/dev/null || exit; done ) & KEEP=$!
G0=$(cat $PRM/lab_gov); P0=$(cat $PRM/lab_gpc_pre405)
restore() { w lab_gpc_pre405 "$P0"; w lab_gov "$G0"; kill $KEEP 2>/dev/null; }
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
say "тест 99: N=$N по 4 прогона; $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), загрузка $(uptime -s)"
w lab_gov 0; sudo sh -c "echo 03 > $PS"; sleep 2
say "подготовка: $(sudo grep '^AC' "$PS")"
for p in 1 0 1 0; do
  [ $STOP = 0 ] || break
  say "--- прогон: ступень 405 = $p"; run "$p"
done
restore
say "=== конец; ключи возвращены"
grep -E "тест 99|подготовка|=== итог|^.{8} ---" "$OUT" > "$OUT.sum"
echo "СВОДКА:"; cat "$OUT.sum"
echo "Результат: $OUT"
