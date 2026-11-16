#!/bin/bash
# ТЕСТ 79 (16.11 вечер), модуль build-1116g. Скобка GPC в PMU «как у NVIDIA»: 8000 нс от запроса до переключателя в обе
# стороны. Меняется ОДНО — порядок тепловых битов CTRL_1: 0 — после запроса (как скобка с процессора и NVIDIA), 1 — до
# запроса (ошибка сборки 1116e). Порядок A-B-A, по N подъёмов в быстром режиме. Вопрос автора: не порядок ли тепловых битов
# сделал застревание вечным.
#   bash ~/Home/nouveau-fix/lab/pmubr79.sh [N=150]     — в терминале рабочего стола, не по ssh; ~15 минут
set -uo pipefail
PRM=/sys/module/nouveau/parameters; HERE="$(cd "$(dirname "$0")" && pwd)"
N="${1:-150}"
for k in lab_pmu_up_ns lab_pmu_dn_ns lab_pmu_ctrl1_first; do [ -e "$PRM/$k" ] || { echo "Нет $k — нужен модуль build-1116g"; exit 1; }; done
pgrep -f "ladder70|seq68|xfer71|cntr7[23]|srcclk7|bootprobe|pmubr7[678]|domains.sh|hangtest" >/dev/null && { echo "Идёт другой тест — дождитесь конца"; exit 1; }
BASE="lab_mem=0 lab_vbios_src=1 lab_nv_div_late=1 lab_mux_guard=1 lab_therm_code_nv=1 lab_therm_wait_nv=2 lab_therm_wait_nv_margin_ns=0 lab_order=1 lab_gpc_pre405=1 lab_nv_hubpost=1 lab_pll_keep=1 lab_xbar=1 lab_volt_wait_us=195 lab_e9e0=1"
STEP="lab_pmu_ctrl1_first lab_pmu_bracket_ns lab_pmu_up_ns lab_pmu_dn_ns lab_pmu_dn_flag lab_mux_recover lab_therm_fixed_hub_ns lab_therm_fixed_floor_ns lab_therm_gpc_factor"
OUT=~/Home/nouveau-fix/results/test79-$(date +%Y%m%d-%H%M%S).txt
say() { echo "$(date +%T) $*" | tee -a "$OUT"; }
w() { sudo sh -c "echo $2 > $PRM/$1"; }
sudo -v || exit 1
( while sleep 50; do sudo -n -v 2>/dev/null || exit; done ) & KEEP=$!
declare -A ORIG
for kv in $BASE; do ORIG[${kv%%=*}]="$(cat $PRM/${kv%%=*})"; done
for k in $STEP; do ORIG[$k]="$(cat $PRM/$k)"; done
restore() { for k in "${!ORIG[@]}"; do w "$k" "${ORIG[$k]}"; done; kill $KEEP 2>/dev/null; }
trap 'say "прервано — ключи возвращаю"; restore; exit 1' INT TERM
cnt() { journalctl -k -b 0 --no-pager | grep -c "$1"; }
say "тест 79: N=$N, A-B-A по порядку CTRL_1, 8000 нс в обе стороны; $(uname -r), модуль $(cat /sys/module/nouveau/srcversion), загрузка $(uptime -s)"
for kv in $BASE; do w "${kv%%=*}" "${kv#*=}"; done
w lab_therm_fixed_floor_ns 1000; w lab_therm_fixed_hub_ns 4000; w lab_therm_gpc_factor 0xa
w lab_pmu_bracket_ns 8000; w lab_pmu_up_ns 8000; w lab_pmu_dn_ns 8000; w lab_pmu_dn_flag 0; w lab_mux_recover 0
for c in 0 1 0; do
  w lab_pmu_ctrl1_first "$c"
  M0=$(cnt "ТАЙМ-АУТ PLL -> делитель"); S0=$(cnt "ОСТАЛСЯ НА PLL"); G0=$(cnt "ушёл на делитель"); E0=$(journalctl -k -b 0 --no-pager | grep -cE "DATA_ERROR|FAULT at|Xid|killed|g84_bar_flush")
  say "=== порядок CTRL_1: $([ $c = 1 ] && echo 'ДО запроса (как 1116e)' || echo 'после запроса (как NVIDIA)')"
  FAST=1 bash "$HERE/hangtest.sh" "$N" >> "$OUT" 2>&1; RC=$?
  say "=== итог CTRL_1 $([ $c = 1 ] && echo 'до' || echo 'после'): код $RC, тайм-аутов $(( $(cnt "ТАЙМ-АУТ PLL -> делитель") - M0 )), вытащено повтором $(( $(cnt "ушёл на делитель") - G0 )), осталось на PLL $(( $(cnt "ОСТАЛСЯ НА PLL") - S0 )), ошибок GPU $(( $(journalctl -k -b 0 --no-pager | grep -cE "DATA_ERROR|FAULT at|Xid|killed|g84_bar_flush") - E0 ))"
  [ "$RC" = 2 ] && { say "зависание графики — останавливаюсь"; break; }
  [ "$(cnt "ОСТАЛСЯ НА PLL")" -gt "$S0" ] && { say "--- переключатель остался на PLL — дальше не иду (нужна перезагрузка)"; break; }
done
restore
say "=== конец; ключи возвращены"
echo "СВОДКА:" | tee -a "$OUT"; grep -E "=== итог|остался|зависание" "$OUT" > "$OUT.sum"; tee -a "$OUT" < "$OUT.sum"
echo "Результат: $OUT"
