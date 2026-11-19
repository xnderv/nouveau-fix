#!/bin/bash
# ТЕСТ 100 (19.11), модуль от build-1117j. Зависание GR в тесте 99 (18.11 21:05, docs/2026-11-19/hang-99.md) — на подъёме 03 -> 0f
# вместе со сменой памяти, ≈ 1 на 4150 подъёмов. Что виновато — ядро или память? Здесь ТОЛЬКО ЯДРО: набор службы как есть,
# одно отличие — lab_mem=0 (память стоит на 324 МГц весь тест, как у тестировщиков в пакете «только ядро»).
# N подъёмов 03 -> 0f со спуском через 07 под нагрузкой (FAST). Регулятор на время теста выключен. Стоп на зависании или
# вечном застревании. Предсказание: если виновата память — зависаний нет (при прежней частоте за 10000 подъёмов было бы ≈ 2).
#   bash ~/Home/nouveau-fix/lab/core100.sh [N=10000]     — в терминале рабочего стола; около 5 часов
set -uo pipefail
PRM=/sys/module/nouveau/parameters; HERE="$(cd "$(dirname "$0")" && pwd)"
N="${1:-10000}"
[ -e "$PRM/lab_nv_up07" ] || { echo "Нет lab_nv_up07 — нужен модуль от build-1117j"; exit 1; }
pgrep -f "hangtest|core9|night93|disp91|gov94|e9gov95|up96|nvx97|uf98|pre99|cntr[78]|fsrm8|pmubr|big83" >/dev/null && { echo "Идёт другой тест — дождитесь конца"; exit 1; }
[ "$(cat $PRM/lab_nv_up07)" = 1 ] && [ "$(cat $PRM/lab_e9e0)" = 2 ] || { echo "Служба не на наборе 18.11 — сначала autoclock.sh install"; exit 1; }
OUT=~/Home/nouveau-fix/results/test100-$(date +%Y%m%d-%H%M%S).txt
say() { echo "$(date +%T) $*" | tee -a "$OUT"; }
w() { sudo sh -c "echo $2 > $PRM/$1"; }
sudo -v || exit 1
( while sleep 50; do sudo -n -v 2>/dev/null || exit; done ) & KEEP=$!
G0=$(cat $PRM/lab_gov); M0=$(cat $PRM/lab_mem)
restore() { w lab_mem "$M0"; w lab_gov "$G0"; kill $KEEP 2>/dev/null; }
trap 'say "прервано — ключи возвращаю"; restore; exit 1' INT TERM
cnt() { journalctl -k -b 0 --no-pager | grep -c "$1"; }
gerr() { journalctl -k -b 0 --no-pager | grep -cE "DATA_ERROR|FAULT at|Xid|killed|g84_bar_flush"; }
PS="$(sudo sh -c 'ls /sys/kernel/debug/dri/*/pstate | head -n 1')"
say "тест 100: N=$N, только ядро; $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), загрузка $(uptime -s)"
w lab_gov 0; sudo sh -c "echo 07 > $PS"; sleep 2; w lab_mem 0
say "подготовка: $(sudo grep '^AC' "$PS"); lab_mem=$(cat $PRM/lab_mem) lab_gpc_pre405=$(cat $PRM/lab_gpc_pre405)"
U0=$(cnt "ТАЙМ-АУТ делитель -> PLL"); D0=$(cnt "ТАЙМ-АУТ PLL -> делитель"); S0=$(cnt "ОСТАЛСЯ НА PLL"); E0=$(gerr)
FAST=1 LOW=03 HIGH=0f MID=07 bash "$HERE/hangtest.sh" "$N" >> "$OUT" 2>&1; RC=$?
say "=== итог: только ядро — код $RC, подъёмов $(grep -c '^.\{8\} подъём ' "$OUT"), застреваний подъёма $(( $(cnt "ТАЙМ-АУТ делитель -> PLL") - U0 )), спуска $(( $(cnt "ТАЙМ-АУТ PLL -> делитель") - D0 )), вечных $(( $(cnt "ОСТАЛСЯ НА PLL") - S0 )), ошибок GPU $(( $(gerr) - E0 ))"
[ "$RC" = 2 ] && say "--- зависание графики"
restore
say "=== конец; ключи возвращены"
grep -E "тест 100|подготовка|=== итог|---" "$OUT" > "$OUT.sum"
echo "Результат: $OUT"
