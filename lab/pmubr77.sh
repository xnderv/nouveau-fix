#!/bin/bash
# ТЕСТ 77 (16.11), уточнение порога этапа Б (тест 76: 4000 — 0 застреваний, 2000 — 167 из 200, 1000 — 200 из 200): скобка GPC с переключателем на карте (PMU, ключ lab_pmu_bracket_ns, модуль build-1116e).
# Пауза W между запросом замедления и переключателем задаётся по часам карты, без PCIe и процессора, и без нижнего предела.
# Ступени сверху вниз; на каждой — быстрый hangtest N подъёмов 07 -> 0f -> 07 под нагрузкой браузера. Пакет ядра — как
# в тесте 70, глубина GPC /6, хаб — с процессора, 4000 нс. Застревание — данные, тест идёт дальше; зависание графики — стоп.
# W = 0: запрос замедления и сразу переключатель (как тест 63а 29.10 — тогда чисто).
#   bash ~/Home/nouveau-fix/lab/pmubr77.sh [N=100]     — в терминале рабочего стола, не по ssh; ~20 минут
set -uo pipefail
PRM=/sys/module/nouveau/parameters; HERE="$(cd "$(dirname "$0")" && pwd)"
N="${1:-100}"
[ -e "$PRM/lab_pmu_bracket_ns" ] || { echo "Нет lab_pmu_bracket_ns — нужен модуль build-1116e"; exit 1; }
pgrep -f "ladder70|seq68|xfer71|cntr7[23]|srcclk7|bootprobe|pmubr76|domains.sh|hangtest" >/dev/null && { echo "Идёт другой тест — дождитесь конца"; exit 1; }
WAITS=(4000 3500 3000 2500 2250)
BASE="lab_mem=0 lab_vbios_src=1 lab_nv_div_late=1 lab_mux_guard=1 lab_therm_code_nv=1 lab_therm_wait_nv=2 lab_therm_wait_nv_margin_ns=0 lab_order=1 lab_gpc_pre405=1 lab_nv_hubpost=1 lab_pll_keep=1 lab_xbar=1 lab_volt_wait_us=195 lab_e9e0=1"
STEP="lab_pmu_bracket_ns lab_therm_fixed_hub_ns lab_therm_fixed_floor_ns lab_therm_gpc_factor"
OUT=~/Home/nouveau-fix/results/test77-$(date +%Y%m%d-%H%M%S).txt
say() { echo "$(date +%T) $*" | tee -a "$OUT"; }
w() { sudo sh -c "echo $2 > $PRM/$1"; }
sudo -v || exit 1
( while sleep 50; do sudo -n -v 2>/dev/null || exit; done ) & KEEP=$!
declare -A ORIG
for kv in $BASE; do ORIG[${kv%%=*}]="$(cat $PRM/${kv%%=*})"; done
for k in $STEP; do ORIG[$k]="$(cat $PRM/$k)"; done
restore() { for k in "${!ORIG[@]}"; do w "$k" "${ORIG[$k]}"; done; kill $KEEP 2>/dev/null; }
trap 'say "прервано — ключи возвращаю"; restore; exit 1' INT TERM
say "тест 77: N=$N, ступени ${WAITS[*]} нс; $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), загрузка $(uptime -s)"
for kv in $BASE; do w "${kv%%=*}" "${kv#*=}"; done
w lab_therm_fixed_floor_ns 1000; w lab_therm_fixed_hub_ns 4000; w lab_therm_gpc_factor 0xa
for W in "${WAITS[@]}"; do
  if [ "$W" = 0 ]; then w lab_pmu_bracket_ns 1; else w lab_pmu_bracket_ns "$W"; fi
  say "=== ступень: пауза $W нс на карте (GPC /6)"
  M0=$(journalctl -k -b 0 --no-pager | grep -c "LAB mux ТАЙМ-АУТ"); E0=$(journalctl -k -b 0 --no-pager | grep -cE "DATA_ERROR|FAULT at|Xid|killed|g84_bar_flush")
  T0=$(date "+%F %T")
  FAST=1 bash "$HERE/hangtest.sh" "$N" >> "$OUT" 2>&1; RC=$?
  M1=$(journalctl -k -b 0 --no-pager | grep -c "LAB mux ТАЙМ-АУТ"); E1=$(journalctl -k -b 0 --no-pager | grep -cE "DATA_ERROR|FAULT at|Xid|killed|g84_bar_flush")
  NP=$(journalctl -k -b 0 --no-pager --since "$T0" | grep -c "LAB PMU-скобка GPC")
  NX=$(journalctl -k -b 0 --no-pager --since "$T0" | grep -c "memx недоступен")
  say "=== итог ступени $W нс: код $RC, застреваний $((M1 - M0)), ошибок GPU $((E1 - E0)), PMU-скобок $NP, отказов memx $NX"
  [ "$RC" = 2 ] && { say "зависание графики — останавливаюсь"; break; }
done
restore
say "=== конец; ключи возвращены"
echo "СВОДКА:" | tee -a "$OUT"; grep -E "итог ступени|зависание" "$OUT" > "$OUT.sum"; tee -a "$OUT" < "$OUT.sum"
echo "Результат: $OUT"
