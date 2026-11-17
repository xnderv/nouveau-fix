#!/bin/bash
# ТЕСТ 90 (17.11), любой модуль от build-1117 (ключи ниже есть с 14.11). Нужны ли кросс-бар (lab_xbar) и делитель 0x00e9e0
# (lab_e9e0) полному набору ядра «как NVIDIA». Набор — тот, что прошёл ночь 14.11 (3000 подъёмов чисто), но ТОЛЬКО ЯДРО
# (lab_mem=0): база теста 68 (генератор по VBIOS, коды замедления по чипам, ожидание по модели NVIDIA, делитель в скобке,
# страховка переключателя) + порядок узлов, ступень 405, пост-делитель хабов, PLL не трогать, пауза 195 мкс после напряжения.
# Прогоны по N подъёмов 07 <-> 0f под нагрузкой (FAST), каждый отличается от полного набора ОДНИМ:
#   А — без кросс-бара (lab_xbar=0);  Б — без 0x00e9e0 (lab_e9e0=0).
# Стоп на зависании графики или на вечном застревании. Регулятор выключается до ключей, карта проводится 03 -> 07.
# Служба gpu-autoclock ставит СТАРЫЙ набор (без порядка, 405, PLL, паузы, кросс-бара, e9e0) — на время теста ключи наши,
# в конце возвращаются прежние.
#   bash ~/Home/nouveau-fix/lab/core90.sh [N=1000]     — в терминале рабочего стола; около 35 минут на прогон
set -uo pipefail
PRM=/sys/module/nouveau/parameters; HERE="$(cd "$(dirname "$0")" && pwd)"
N="${1:-1000}"
pgrep -f "ladder70|seq68|xfer71|cntr[78]|srcclk7|bootprobe|pmubr|big83|fsrm8|domains.sh|hangtest" >/dev/null && { echo "Идёт другой тест — дождитесь конца"; exit 1; }
FULL="lab_mem=0 lab_vbios_src=1 lab_nv_div_late=1 lab_mux_guard=1 lab_therm_code_nv=1 lab_therm_wait_nv=2 lab_therm_wait_nv_margin_ns=0 lab_order=1 lab_gpc_pre405=1 lab_nv_hubpost=1 lab_pll_keep=1 lab_xbar=1 lab_volt_wait_us=195 lab_e9e0=1 lab_pmu_bracket_ns=0"
for kv in $FULL lab_gov=0; do [ -e "$PRM/${kv%%=*}" ] || { echo "Нет ключа ${kv%%=*} — не тот модуль"; exit 1; }; done
OUT=~/Home/nouveau-fix/results/test90-$(date +%Y%m%d-%H%M%S).txt
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
  FAST=1 bash "$HERE/hangtest.sh" "$N" >> "$OUT" 2>&1; RC=$?
  say "=== итог: $1 — код $RC, застреваний подъёма $(( $(cnt "ТАЙМ-АУТ делитель -> PLL") - U0 )), спуска $(( $(cnt "ТАЙМ-АУТ PLL -> делитель") - D0 )), осталось на PLL $(( $(cnt "ОСТАЛСЯ НА PLL") - S0 )), ошибок GPU $(( $(gerr) - E0 ))"
  [ "$RC" = 2 ] && { say "--- зависание графики — стоп"; STOP=1; }
  [ "$(cnt "ОСТАЛСЯ НА PLL")" -gt "$S0" ] && { say "--- вечное застревание — стоп"; STOP=1; }
  return 0
}
PS="$(sudo sh -c 'ls /sys/kernel/debug/dri/*/pstate | head -n 1')"
say "тест 90: N=$N; $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), загрузка $(uptime -s)"
w lab_gov 0; sudo sh -c "echo 03 > $PS"; sleep 2
for kv in $FULL; do w "${kv%%=*}" "${kv#*=}"; done
sudo sh -c "echo 07 > $PS"; sleep 2
say "подготовка: $(sudo grep '^AC' "$PS")"
say "--- А. полный набор без кросс-бара (lab_xbar=0)"; w lab_xbar 0; w lab_e9e0 1; run "без кросс-бара"
if [ $STOP = 0 ]; then say "--- Б. полный набор без 0x00e9e0 (lab_e9e0=0)"; w lab_xbar 1; w lab_e9e0 0; run "без 0x00e9e0"; fi
restore
say "=== конец; ключи возвращены"
echo "СВОДКА:" | tee -a "$OUT"; grep -E "=== итог|^.{8} ---|подготовка" "$OUT" > "$OUT.sum"; tee -a "$OUT" < "$OUT.sum"
echo "Результат: $OUT"
