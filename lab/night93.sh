#!/bin/bash
# ТЕСТ 93 (17.11, на ночь), любой модуль от build-1117. Целевой набор ядра (тест 93: без кросс-бара и 0x00e9e0, 2000 чисто)
# ВМЕСТЕ СО СМЕНОЙ ПАМЯТИ — как ночь 14.11 (тест 69: набор ядра теста 68 + память + hubk07 рядом с памятью + PCIe в конце
# спуска; 3000 подъёмов чисто, но с кросс-баром и 0x00e9e0). Отличие от ночи 14.11 — сняты кросс-бар и 0x00e9e0 (оба сразу,
# как в тесте 92). Обычный режим hangtest (удержание 0f 6 с), как 14.11. Если чисто — этот набор идёт в службу gpu-autoclock.
#   bash ~/Home/nouveau-fix/lab/night93.sh [N=3000]     — в терминале рабочего стола; около 10 часов
set -uo pipefail
PRM=/sys/module/nouveau/parameters; HERE="$(cd "$(dirname "$0")" && pwd)"
N="${1:-3000}"
pgrep -f "ladder70|seq68|xfer71|cntr[78]|srcclk7|bootprobe|pmubr|big83|fsrm8|core9|disp91|domains.sh|hangtest" >/dev/null && { echo "Идёт другой тест — дождитесь конца"; exit 1; }
FULL="lab_mem=1 lab_nv_hub07mem=1 lab_nv_pcie_late=1 lab_vbios_src=1 lab_nv_div_late=1 lab_mux_guard=1 lab_therm_code_nv=1 lab_therm_wait_nv=2 lab_therm_wait_nv_margin_ns=0 lab_order=1 lab_gpc_pre405=1 lab_nv_hubpost=1 lab_pll_keep=1 lab_xbar=1 lab_volt_wait_us=195 lab_e9e0=1 lab_pmu_bracket_ns=0"
for kv in $FULL lab_gov=0; do [ -e "$PRM/${kv%%=*}" ] || { echo "Нет ключа ${kv%%=*} — не тот модуль"; exit 1; }; done
OUT=~/Home/nouveau-fix/results/test93-$(date +%Y%m%d-%H%M%S).txt
say() { echo "$(date +%T) $*" | tee -a "$OUT"; }
w() { sudo sh -c "echo $2 > $PRM/$1"; }
sudo -v || exit 1
( while sleep 50; do sudo -n -v 2>/dev/null || exit; done ) & KEEP=$!
declare -A ORIG
for kv in $FULL lab_gov=0; do ORIG[${kv%%=*}]="$(cat $PRM/${kv%%=*})"; done
restore() { for k in "${!ORIG[@]}"; do w "$k" "${ORIG[$k]}"; done; kill $KEEP 2>/dev/null; }
trap 'say "прервано — ключи возвращаю"; restore; exit 1' INT TERM
cnt() { journalctl -k -b 0 --no-pager | grep -c "$1"; }
gerr() { journalctl -k -b 0 --no-pager | grep -cE "DATA_ERROR|FAULT at|Xid|killed|g84_bar_flush"; }
STOP=0
run() {
  local D0 U0 S0 E0 RC
  D0=$(cnt "ТАЙМ-АУТ PLL -> делитель"); U0=$(cnt "ТАЙМ-АУТ делитель -> PLL"); S0=$(cnt "ОСТАЛСЯ НА PLL"); E0=$(gerr)
  bash "$HERE/hangtest.sh" "$N" >> "$OUT" 2>&1; RC=$?
  say "=== итог: $1 — код $RC, застреваний подъёма $(( $(cnt "ТАЙМ-АУТ делитель -> PLL") - U0 )), спуска $(( $(cnt "ТАЙМ-АУТ PLL -> делитель") - D0 )), осталось на PLL $(( $(cnt "ОСТАЛСЯ НА PLL") - S0 )), ошибок GPU $(( $(gerr) - E0 ))"
  [ "$RC" = 1 ] && { say "--- hangtest не отработал (код 1, причина — выше в журнале) — стоп"; STOP=1; }
  [ "$RC" = 2 ] && { say "--- зависание графики — стоп"; STOP=1; }
  [ "$(cnt "ОСТАЛСЯ НА PLL")" -gt "$S0" ] && { say "--- вечное застревание — стоп"; STOP=1; }
  return 0
}
PS="$(sudo sh -c 'ls /sys/kernel/debug/dri/*/pstate | head -n 1')"
say "тест 93: N=$N; $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), загрузка $(uptime -s)"
w lab_gov 0; sudo sh -c "echo 03 > $PS"; sleep 2; sudo sh -c "echo 07 > $PS"; sleep 2   # память — на уровне 07 (324), как в тестах 68, 83
for kv in $FULL; do w "${kv%%=*}" "${kv#*=}"; done
say "подготовка: $(sudo grep '^AC' "$PS")"
say "--- целевой набор + память: без кросс-бара и без 0x00e9e0"; w lab_xbar 0; w lab_e9e0 0; run "целевой набор + память"
restore
say "=== конец; ключи возвращены"
echo "СВОДКА:" | tee -a "$OUT"; grep -E "=== итог|^.{8} ---|подготовка" "$OUT" > "$OUT.sum"; tee -a "$OUT" < "$OUT.sum"
echo "Результат: $OUT"
