#!/bin/bash
# ТЕСТ 96 (18.11), модуль build-1117j. Подъём GPC на PLL как в записях NVIDIA (аудит 18.11, docs/2026-11-18/core-audit.md):
# ступень 405 только с 03, с 07 — сразу на PLL; делитель GPC после подъёма не переписывается (lab_nv_up07=1).
# Набор — тот, что ставит служба (целевой + такт дисплея по VBIOS); одно отличие — lab_nv_up07=1. Регулятор на время теста
# выключен; N подъёмов 07 <-> 0f под нагрузкой (FAST). Стоп на зависании графики или вечном застревании.
# Заодно: строка загрузки «выход скобки по состоянию VBIOS» (новое правило выхода из скобки, должно совпасть с прежними числами).
#   bash ~/Home/nouveau-fix/lab/up96.sh [N=1000]     — в терминале рабочего стола; около 35 минут
set -uo pipefail
PRM=/sys/module/nouveau/parameters; HERE="$(cd "$(dirname "$0")" && pwd)"
N="${1:-1000}"
[ -e "$PRM/lab_nv_up07" ] || { echo "Нет lab_nv_up07 — нужен модуль build-1117j"; exit 1; }
pgrep -f "hangtest|core9|night93|disp91|gov94|e9gov95|cntr[78]|fsrm8|pmubr|big83" >/dev/null && { echo "Идёт другой тест — дождитесь конца"; exit 1; }
[ "$(cat $PRM/lab_order)" = 1 ] && [ "$(cat $PRM/lab_e9e0)" = 2 ] || { echo "Служба не на целевом наборе с lab_e9e0=2 — сначала autoclock.sh install"; exit 1; }
OUT=~/Home/nouveau-fix/results/test96-$(date +%Y%m%d-%H%M%S).txt
say() { echo "$(date +%T) $*" | tee -a "$OUT"; }
w() { sudo sh -c "echo $2 > $PRM/$1"; }
sudo -v || exit 1
( while sleep 50; do sudo -n -v 2>/dev/null || exit; done ) & KEEP=$!
G0=$(cat $PRM/lab_gov); U0=$(cat $PRM/lab_nv_up07)
restore() { w lab_nv_up07 "$U0"; w lab_gov "$G0"; kill $KEEP 2>/dev/null; }
trap 'say "прервано — ключи возвращаю"; restore; exit 1' INT TERM
cnt() { journalctl -k -b 0 --no-pager | grep -c "$1"; }
gerr() { journalctl -k -b 0 --no-pager | grep -cE "DATA_ERROR|FAULT at|Xid|killed|g84_bar_flush"; }
PS="$(sudo sh -c 'ls /sys/kernel/debug/dri/*/pstate | head -n 1')"
say "тест 96: N=$N; $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), загрузка $(uptime -s)"
say "загрузка: $(journalctl -k -b 0 --no-pager | grep -m1 'выход скобки по состоянию VBIOS' | sed -E 's/^.*clk: LAB //')"
say "CTRL_1 маска: $(cat $PRM/lab_therm_ctrl1_clr)"
w lab_gov 0; sudo sh -c "echo 07 > $PS"; sleep 2
w lab_nv_up07 1
say "подготовка: $(sudo grep '^AC' "$PS")"
T0=$(date "+%F %T")
D0=$(cnt "ТАЙМ-АУТ PLL -> делитель"); UP0=$(cnt "ТАЙМ-АУТ делитель -> PLL"); S0=$(cnt "ОСТАЛСЯ НА PLL"); E0=$(gerr)
FAST=1 bash "$HERE/hangtest.sh" "$N" >> "$OUT" 2>&1; RC=$?
say "=== итог: lab_nv_up07=1 — код $RC, застреваний подъёма $(( $(cnt "ТАЙМ-АУТ делитель -> PLL") - UP0 )), спуска $(( $(cnt "ТАЙМ-АУТ PLL -> делитель") - D0 )), осталось на PLL $(( $(cnt "ОСТАЛСЯ НА PLL") - S0 )), ошибок GPU $(( $(gerr) - E0 ))"
say "подъёмов без ступени (с 07): $(journalctl -k -b 0 --no-pager --since "$T0" | grep -c 'nv_up07: делительный путь'), со ступенью (с 03): $(journalctl -k -b 0 --no-pager --since "$T0" | grep -c 'gpc_pre405: делительный путь')"
[ "$RC" = 2 ] && say "--- зависание графики"
restore
say "=== конец; ключи возвращены"
grep -E "тест 96|загрузка:|CTRL_1|подготовка|=== итог|подъёмов без|---" "$OUT" > "$OUT.sum"
echo "Результат: $OUT"
