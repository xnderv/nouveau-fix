#!/bin/bash
# ТЕСТ 97 (18.11), модуль build-1117j, служба на наборе 18.11 (lab_e9e0=2, lab_nv_up07=1). Записи NVIDIA при смене уровня,
# которых у нас нет (аудит 18.11, docs/2026-11-18/core-audit.md, п. 5) — те, для которых ключ уже есть в модуле, по одному:
#   0 — контроль: набор службы как есть (путь 03 -> 0f -> 07 -> 03 с этим модулем ещё не гонялся);
#   А — lab_nv_22680=1: 0x022680 = 0x80000000 | байт 0x0c записи уровня VBIOS (на подъёме в начале, на спуске в конце);
#   Б — lab_nv_disphold=1: бит 0 в 0x610300 (дисплей) на всё время перехода.
# Каждый прогон: регулятор выключен, N подъёмов 03 -> 0f со спуском через 07 под нагрузкой (FAST). Стоп на зависании графики
# или вечном застревании. Ключи после каждого прогона возвращаются.
#   bash ~/Home/nouveau-fix/lab/nvx97.sh [N=600]     — в терминале рабочего стола; около 90 минут
set -uo pipefail
PRM=/sys/module/nouveau/parameters; HERE="$(cd "$(dirname "$0")" && pwd)"
N="${1:-600}"
for k in lab_nv_up07 lab_nv_22680 lab_nv_disphold; do [ -e "$PRM/$k" ] || { echo "Нет $k — нужен модуль build-1117j"; exit 1; }; done
pgrep -f "hangtest|core9|night93|disp91|gov94|e9gov95|up96|cntr[78]|fsrm8|pmubr|big83" >/dev/null && { echo "Идёт другой тест — дождитесь конца"; exit 1; }
[ "$(cat $PRM/lab_nv_up07)" = 1 ] && [ "$(cat $PRM/lab_e9e0)" = 2 ] || { echo "Служба не на наборе 18.11 — сначала autoclock.sh install"; exit 1; }
OUT=~/Home/nouveau-fix/results/test97-$(date +%Y%m%d-%H%M%S).txt
say() { echo "$(date +%T) $*" | tee -a "$OUT"; }
w() { sudo sh -c "echo $2 > $PRM/$1"; }
sudo -v || exit 1
( while sleep 50; do sudo -n -v 2>/dev/null || exit; done ) & KEEP=$!
G0=$(cat $PRM/lab_gov); A0=$(cat $PRM/lab_nv_22680); B0=$(cat $PRM/lab_nv_disphold)
restore() { w lab_nv_22680 "$A0"; w lab_nv_disphold "$B0"; w lab_gov "$G0"; kill $KEEP 2>/dev/null; }
trap 'say "прервано — ключи возвращаю"; restore; exit 1' INT TERM
cnt() { journalctl -k -b 0 --no-pager | grep -c "$1"; }
gerr() { journalctl -k -b 0 --no-pager | grep -cE "DATA_ERROR|FAULT at|Xid|killed|g84_bar_flush"; }
STOP=0
run() {
  local D0 U0 S0 E0 RC T0
  T0=$(date "+%F %T")
  D0=$(cnt "ТАЙМ-АУТ PLL -> делитель"); U0=$(cnt "ТАЙМ-АУТ делитель -> PLL"); S0=$(cnt "ОСТАЛСЯ НА PLL"); E0=$(gerr)
  FAST=1 LOW=03 HIGH=0f MID=07 bash "$HERE/hangtest.sh" "$N" >> "$OUT" 2>&1; RC=$?
  say "=== итог: $1 — код $RC, застреваний подъёма $(( $(cnt "ТАЙМ-АУТ делитель -> PLL") - U0 )), спуска $(( $(cnt "ТАЙМ-АУТ PLL -> делитель") - D0 )), осталось на PLL $(( $(cnt "ОСТАЛСЯ НА PLL") - S0 )), ошибок GPU $(( $(gerr) - E0 ))"
  say "    записей 0x022680: $(journalctl -k -b 0 --no-pager --since "$T0" | grep -c 'LAB nv_22680: уровень'), пример: $(journalctl -k -b 0 --no-pager --since "$T0" | grep -m2 'LAB nv_22680: уровень' | sed -E 's/^.*clk: LAB //' | tr '\n' ';')"
  say "    удержаний 0x610300: $(journalctl -k -b 0 --no-pager --since "$T0" | grep -c 'nv_disphold: 0x610300 .* на время')"
  [ "$RC" = 1 ] && { say "--- hangtest не отработал (код 1) — стоп"; STOP=1; }
  [ "$RC" = 2 ] && { say "--- зависание графики — стоп"; STOP=1; }
  [ "$(cnt "ОСТАЛСЯ НА PLL")" -gt "$S0" ] && { say "--- вечное застревание — стоп"; STOP=1; }
  return 0
}
PS="$(sudo sh -c 'ls /sys/kernel/debug/dri/*/pstate | head -n 1')"
say "тест 97: N=$N; $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), загрузка $(uptime -s)"
w lab_gov 0; w lab_nv_22680 0; w lab_nv_disphold 0; sudo sh -c "echo 03 > $PS"; sleep 2
say "подготовка: $(sudo grep '^AC' "$PS")"
say "--- 0. контроль: набор службы"; run "контроль"
if [ $STOP = 0 ]; then say "--- А. lab_nv_22680=1"; w lab_nv_22680 1; run "0x022680 из VBIOS"; w lab_nv_22680 0; fi
if [ $STOP = 0 ]; then say "--- Б. lab_nv_disphold=1"; w lab_nv_disphold 1; run "0x610300 бит 0"; w lab_nv_disphold 0; fi
restore
say "=== конец; ключи возвращены"
echo "СВОДКА:" | tee -a "$OUT"; grep -E "=== итог|записей 0x|удержаний|^.{8} ---|подготовка|тест 97" "$OUT" > "$OUT.sum"; tee -a "$OUT" < "$OUT.sum"
echo "Результат: $OUT"
